-- GesCo Bar · v3.2 : permissions hiérarchiques, paiement marchand (QR + demande par numéro), abonnements

-- 1. Permissions : serveuses et caisse → directeur (ou PDG) ; directeur → PDG uniquement ; personne ne valide sa propre demande
create or replace function public.gb_leave_decide(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare c record; l public.leave_requests; d date; n text; r text;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into l from public.leave_requests where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if l.status <> 'en_attente' then raise exception 'Cette demande a déjà été traitée.'; end if;
  if l.staff_id = c.sid then raise exception 'Vous ne pouvez pas valider votre propre demande.'; end if;
  select name, role into n, r from public.staff where id = l.staff_id;
  if r in ('directeur', 'pdg') and c.srole <> 'pdg' then raise exception 'La demande du directeur est traitée par le PDG.'; end if;
  update public.leave_requests set status = case when p_accept then 'acceptee' else 'refusee' end, decided_by = c.sid, decided_at = now() where id = p_id;
  if p_accept then
    for d in select generate_series(l.day_from, l.day_to, interval '1 day')::date loop
      insert into public.attendance(bar_id, staff_id, day, status, note, recorded_by) values (c.bid, l.staff_id, d, 'permission', l.reason, c.sid)
      on conflict (staff_id, day) do update set status = 'permission', note = excluded.note, recorded_by = excluded.recorded_by, updated_at = now();
    end loop;
  end if;
  perform gb_private.log(c.bid, c.sid, case when p_accept then 'permission_acceptee' else 'permission_refusee' end, jsonb_build_object('membre', n, 'du', l.day_from, 'au', l.day_to));
end $$;

-- 2. Paiement marchand configuré par le PDG
alter table public.bars
  add column if not exists om_code text check (om_code is null or om_code ~ '^[0-9]{4,12}$'),
  add column if not exists mtn_code text check (mtn_code is null or mtn_code ~ '^[0-9]{4,12}$'),
  add column if not exists om_ussd text not null default '#150*47*{code}*{montant}#',
  add column if not exists mtn_ussd text not null default '*126*4*{code}*{montant}#',
  add column if not exists push_enabled boolean not null default false,
  add column if not exists plan_until date;

create table if not exists gb_private.pay_keys (
  bar_id uuid primary key references public.bars(id) on delete cascade,
  provider text not null default 'notchpay',
  public_key text not null,
  updated_at timestamptz not null default now()
);

create or replace function public.gb_pay_config(p_om_code text, p_mtn_code text, p_om_ussd text, p_mtn_ussd text, p_key text)
returns void language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pdg(c.srole);
  if coalesce(p_om_ussd, '') <> '' and (position('{code}' in p_om_ussd) = 0 or position('{montant}' in p_om_ussd) = 0) then raise exception 'Le modèle Orange doit contenir {code} et {montant}.'; end if;
  if coalesce(p_mtn_ussd, '') <> '' and (position('{code}' in p_mtn_ussd) = 0 or position('{montant}' in p_mtn_ussd) = 0) then raise exception 'Le modèle MTN doit contenir {code} et {montant}.'; end if;
  update public.bars set om_code = nullif(trim(p_om_code), ''), mtn_code = nullif(trim(p_mtn_code), ''),
    om_ussd = coalesce(nullif(trim(p_om_ussd), ''), om_ussd), mtn_ussd = coalesce(nullif(trim(p_mtn_ussd), ''), mtn_ussd)
  where id = c.bid;
  if p_key is not null then
    if trim(p_key) = '' then delete from gb_private.pay_keys where bar_id = c.bid; update public.bars set push_enabled = false where id = c.bid;
    else insert into gb_private.pay_keys(bar_id, public_key) values (c.bid, trim(p_key)) on conflict (bar_id) do update set public_key = excluded.public_key, updated_at = now();
      update public.bars set push_enabled = true where id = c.bid; end if;
  end if;
  perform gb_private.log(c.bid, c.sid, 'paiement_config', jsonb_build_object('orange', p_om_code, 'mtn', p_mtn_code, 'cle', case when p_key is null then 'inchangée' when trim(p_key) = '' then 'retirée' else 'enregistrée' end));
end $$;

-- 3. Demandes de paiement envoyées au téléphone du client
create table if not exists public.momo_requests (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  staff_id uuid not null references public.staff(id),
  phone text not null, operator text not null check (operator in ('orange', 'mtn')),
  amount integer not null, provider_ref text,
  status text not null default 'en_cours' check (status in ('en_cours', 'reussi', 'echoue')),
  message text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists momo_requests_ticket on public.momo_requests(ticket_id);
alter table public.momo_requests enable row level security;
create policy momo_read on public.momo_requests for select to authenticated
  using (bar_id = (select gb_private.bar()) and (staff_id = (select gb_private.me()) or (select gb_private.is_caisse())));
alter publication supabase_realtime add table public.momo_requests;

create or replace function public.gb_admin_momo_start(p_user uuid, p_ticket uuid, p_phone text, p_operator text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.staff; t public.tickets; k text; b public.bars; rid uuid; ph text;
begin
  select * into s from public.staff where user_id = p_user and active;
  if not found then raise exception 'Session invalide.'; end if;
  select * into t from public.tickets where id = p_ticket and bar_id = s.bar_id for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.waitress_id <> s.id then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status <> 'sent' then raise exception 'Envoyez d''abord la commande à la caisse.'; end if;
  if t.cancel_requested then raise exception 'Une annulation est en attente sur ce ticket.'; end if;
  if t.total <= 0 then raise exception 'Le ticket est vide.'; end if;
  if p_operator not in ('orange', 'mtn') then raise exception 'Opérateur inconnu.'; end if;
  ph := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'); if length(ph) = 12 and left(ph, 3) = '237' then ph := right(ph, 9); end if;
  if ph !~ '^6[0-9]{8}$' then raise exception 'Numéro camerounais invalide (9 chiffres commençant par 6).'; end if;
  select public_key into k from gb_private.pay_keys where bar_id = s.bar_id;
  if k is null then raise exception 'Le paiement par numéro n''est pas encore activé par le PDG.'; end if;
  if exists (select 1 from public.momo_requests where ticket_id = t.id and status = 'en_cours' and created_at > now() - interval '3 minutes') then
    raise exception 'Une demande est déjà en attente sur le téléphone du client.'; end if;
  insert into public.momo_requests(bar_id, ticket_id, staff_id, phone, operator, amount) values (s.bar_id, t.id, s.id, ph, p_operator, t.total) returning id into rid;
  select * into b from public.bars where id = s.bar_id;
  return jsonb_build_object('id', rid, 'amount', t.total, 'phone', '+237' || ph, 'key', k, 'label', b.name || ' · ticket N°' || coalesce(t.number::text, ''), 'client', t.client_label);
end $$;

create or replace function public.gb_admin_momo_get(p_user uuid, p_req uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.staff; r public.momo_requests; k text;
begin
  select * into s from public.staff where user_id = p_user and active; if not found then raise exception 'Session invalide.'; end if;
  select * into r from public.momo_requests where id = p_req and bar_id = s.bar_id; if not found then raise exception 'Demande introuvable.'; end if;
  select public_key into k from gb_private.pay_keys where bar_id = s.bar_id;
  return jsonb_build_object('status', r.status, 'ref', r.provider_ref, 'key', k, 'ticket', r.ticket_id, 'created', r.created_at);
end $$;

create or replace function public.gb_admin_momo_update(p_req uuid, p_status text, p_ref text, p_msg text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.momo_requests; t public.tickets;
begin
  select * into r from public.momo_requests where id = p_req for update; if not found then return; end if;
  if r.status <> 'en_cours' then return; end if;
  update public.momo_requests set status = p_status, provider_ref = coalesce(p_ref, provider_ref), message = p_msg, updated_at = now() where id = p_req;
  if p_status = 'reussi' then
    update public.tickets set status = 'paid', pay_method = 'momo', received = total, change_due = 0, change_status = 'none',
      cashed_at = coalesce(cashed_at, now()), paid_at = now(), updated_at = now()
    where id = r.ticket_id and status in ('sent', 'cashed') returning * into t;
    if t.id is not null then perform gb_private.log(r.bar_id, r.staff_id, 'momo_auto', jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total, 'operateur', r.operator)); end if;
  end if;
end $$;
revoke all on function public.gb_admin_momo_start(uuid, uuid, text, text), public.gb_admin_momo_get(uuid, uuid), public.gb_admin_momo_update(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.gb_admin_momo_start(uuid, uuid, text, text), public.gb_admin_momo_get(uuid, uuid), public.gb_admin_momo_update(uuid, text, text, text) to service_role;

-- 4. Abonnements (validés par BISMO Agency)
create table if not exists public.platform_config (id int primary key default 1 check (id = 1), om_code text, mtn_code text, phone text, whatsapp text);
insert into public.platform_config(id) values (1) on conflict do nothing;
alter table public.platform_config enable row level security;
create policy platform_read on public.platform_config for select to authenticated using (true);

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  plan text not null check (plan in ('simple', 'premium', 'gold', 'lounge')),
  months integer not null check (months in (1, 3, 6, 12)),
  amount integer not null, method text not null check (method in ('orange', 'mtn')),
  reference text not null, status text not null default 'en_attente' check (status in ('en_attente', 'validee', 'refusee')),
  requested_by uuid references public.staff(id), created_at timestamptz not null default now(), decided_at timestamptz
);
alter table public.subscriptions enable row level security;
create policy subs_read on public.subscriptions for select to authenticated using (bar_id = (select gb_private.bar()) and (select gb_private.is_manager()));

create or replace function public.gb_sub_request(p_plan text, p_months int, p_method text, p_reference text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare c record; price int; total int; v_id uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  price := case p_plan when 'simple' then 10000 when 'premium' then 15000 when 'gold' then 20000 when 'lounge' then 30000 end;
  if price is null then raise exception 'Formule inconnue.'; end if;
  if p_months not in (1, 3, 6, 12) then raise exception 'Durée invalide.'; end if;
  if p_method not in ('orange', 'mtn') then raise exception 'Mode de paiement inconnu.'; end if;
  if length(trim(coalesce(p_reference, ''))) < 4 then raise exception 'Indiquez la référence de la transaction reçue par SMS.'; end if;
  total := price * case when p_months = 12 then 10 else p_months end;
  insert into public.subscriptions(bar_id, plan, months, amount, method, reference, requested_by) values (c.bid, p_plan, p_months, total, p_method, trim(p_reference), c.sid) returning subscriptions.id into v_id;
  perform gb_private.log(c.bid, c.sid, 'abonnement_demande', jsonb_build_object('formule', p_plan, 'mois', p_months, 'montant', total));
  return v_id;
end $$;

-- Validation par l'éditeur (à exécuter par BISMO Agency) : active la formule et prolonge la date de fin
create or replace function public.gb_admin_sub_validate(p_id uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.subscriptions; b public.bars;
begin
  select * into s from public.subscriptions where id = p_id for update; if not found or s.status <> 'en_attente' then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  update public.subscriptions set status = case when p_ok then 'validee' else 'refusee' end, decided_at = now() where id = p_id;
  if p_ok then select * into b from public.bars where id = s.bar_id;
    update public.bars set plan = s.plan, plan_until = greatest(coalesce(b.plan_until, current_date), current_date) + make_interval(months => s.months) where id = s.bar_id; end if;
end $$;
revoke all on function public.gb_admin_sub_validate(uuid, boolean) from public, anon, authenticated;
grant execute on function public.gb_admin_sub_validate(uuid, boolean) to service_role;
