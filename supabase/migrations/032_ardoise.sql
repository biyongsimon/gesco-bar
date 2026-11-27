-- 032 : ardoise (crédit client) et options du bar.
-- Règles : seuls le PDG et le directeur ouvrent une ardoise (client, téléphone, plafond) ;
-- la serveuse DEMANDE l'ardoise pour un ticket, la caisse VALIDE (plafond dépassé : directeur ou PDG seulement) ;
-- les remboursements en espèces entrent dans le tiroir (comptés dans les espèces attendues).
create table if not exists public.credit_clients (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 60),
  phone text check (phone is null or length(phone) <= 30),
  credit_limit int not null default 20000 check (credit_limit between 0 and 10000000),
  active boolean not null default true, note text check (note is null or length(note) <= 200),
  created_by uuid references public.staff(id), created_at timestamptz not null default now());
create index if not exists credit_clients_bar on public.credit_clients(bar_id);
create table if not exists public.credit_moves (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  client_id uuid not null references public.credit_clients(id) on delete cascade,
  ticket_id uuid references public.tickets(id) on delete set null,
  kind text not null check (kind in ('dette', 'remboursement')),
  amount int not null check (amount > 0), method text check (method is null or method in ('cash', 'momo')),
  day_id uuid references public.service_days(id), created_by uuid references public.staff(id), created_at timestamptz not null default now(),
  note text check (note is null or length(note) <= 200));
create index if not exists credit_moves_client on public.credit_moves(client_id, created_at desc);
create index if not exists credit_moves_bar on public.credit_moves(bar_id, created_at desc);
alter table public.credit_clients enable row level security;
alter table public.credit_moves enable row level security;
drop policy if exists credit_clients_read on public.credit_clients;
create policy credit_clients_read on public.credit_clients for select to authenticated using (bar_id = (select gb_private.bar()));
drop policy if exists credit_moves_read on public.credit_moves;
create policy credit_moves_read on public.credit_moves for select to authenticated using (bar_id = (select gb_private.bar()) and (select gb_private.is_caisse()));
grant select on public.credit_clients, public.credit_moves to authenticated;

alter table public.tickets add column if not exists credit_client uuid references public.credit_clients(id);
alter table public.tickets drop constraint if exists tickets_pay_method_check;
alter table public.tickets add constraint tickets_pay_method_check check (pay_method in ('cash', 'momo', 'credit'));

create or replace function gb_private.credit_balance(p_client uuid) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(case when kind = 'dette' then amount else -amount end), 0)::int from public.credit_moves where client_id = p_client $$;
revoke all on function gb_private.credit_balance(uuid) from public, anon, authenticated;

create or replace function gb_private.need_opt(p_bar uuid, p_flag text, p_label text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin if not coalesce((select (opts->>p_flag)::boolean from public.bars where id = p_bar), false) then
  raise exception '% n''est pas activé (Réglages → Options du bar).', p_label; end if; end $$;
revoke all on function gb_private.need_opt(uuid, text, text) from public, anon, authenticated;

-- Options : délais de rappel, téléphone des documents, fonctions activables (f_…)
create or replace function public.gb_bar_opts(p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; k text; v jsonb; o jsonb;
begin
  select * into c from gb_private.ctx();
  if c.srole <> 'pdg' then raise exception 'Seul le PDG modifie ces réglages.'; end if;
  if jsonb_typeof(coalesce(p_patch, '{}')) <> 'object' then raise exception 'Réglages invalides.'; end if;
  select opts into o from public.bars where id = c.bid;
  for k, v in select * from jsonb_each(p_patch) loop
    if k in ('remit_r1', 'remit_r2', 'remit_r3') then
      if jsonb_typeof(v) <> 'number' or (v::text)::int < 0 or (v::text)::int > 600 then raise exception 'Délai invalide (0 à 600 minutes).'; end if;
    elsif k = 'phone' then
      if jsonb_typeof(v) <> 'string' or length(v #>> '{}') > 40 then raise exception 'Téléphone invalide.'; end if;
    elsif k in ('f_ardoise', 'f_vides', 'f_vip', 'f_porte', 'f_nuit', 'f_garde', 'f_print', 'f_mural', 'f_recettes') then
      if jsonb_typeof(v) <> 'boolean' then raise exception 'Option invalide.'; end if;
    else raise exception 'Réglage inconnu : %', k; end if;
    o := o || jsonb_build_object(k, v);
  end loop;
  if coalesce((o->>'remit_r1')::int, 20) > 0 and ((o->>'remit_r2')::int between 1 and coalesce((o->>'remit_r1')::int, 20)
     or (o->>'remit_r3')::int between 1 and coalesce((o->>'remit_r2')::int, 45)) then
    raise exception 'Les délais doivent aller croissant (1er rappel, puis caisse, puis directeur).'; end if;
  update public.bars set opts = o where id = c.bid;
  perform gb_private.log(c.bid, c.sid, 'reglages_modifies', p_patch);
  return o;
end $$;

-- Clients à l'ardoise (PDG, directeur)
create or replace function public.gb_credit_client_save(p_id uuid, p_name text, p_phone text, p_limit int, p_active boolean default true, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c record; nid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  perform gb_private.need_opt(c.bid, 'f_ardoise', 'L''ardoise');
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Indiquez le nom du client.'; end if;
  if p_limit is null or p_limit < 0 then raise exception 'Indiquez le plafond de l''ardoise.'; end if;
  if p_id is null then
    insert into public.credit_clients(bar_id, name, phone, credit_limit, active, note, created_by)
    values (c.bid, trim(p_name), nullif(trim(coalesce(p_phone, '')), ''), p_limit, coalesce(p_active, true), nullif(trim(coalesce(p_note, '')), ''), c.sid) returning id into nid;
  else
    update public.credit_clients set name = trim(p_name), phone = nullif(trim(coalesce(p_phone, '')), ''), credit_limit = p_limit, active = coalesce(p_active, true),
      note = nullif(trim(coalesce(p_note, '')), '') where id = p_id and bar_id = c.bid returning id into nid;
    if nid is null then raise exception 'Client introuvable.'; end if;
  end if;
  perform gb_private.log(c.bid, c.sid, 'ardoise_client', jsonb_build_object('client', trim(p_name), 'plafond', p_limit, 'actif', coalesce(p_active, true)));
  return nid;
end $$;

create or replace function public.gb_credit_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la caisse et à la direction.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'phone', k.phone, 'limit', k.credit_limit, 'active', k.active, 'note', k.note,
      'balance', gb_private.credit_balance(k.id), 'last', (select max(created_at) from public.credit_moves m where m.client_id = k.id),
      'last_debt', (select max(created_at) from public.credit_moves m where m.client_id = k.id and m.kind = 'dette'))
    order by gb_private.credit_balance(k.id) desc, k.name) from public.credit_clients k where k.bar_id = c.bid), '[]'::jsonb);
end $$;

create or replace function public.gb_credit_history(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la caisse et à la direction.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'amount', m.amount, 'method', m.method, 'at', m.created_at, 'note', m.note,
      'ticket', (select number from public.tickets where id = m.ticket_id), 'label', (select client_label from public.tickets where id = m.ticket_id),
      'by', (select name from public.staff where id = m.created_by)) order by m.created_at desc)
    from public.credit_moves m where m.client_id = p_client and m.bar_id = c.bid), '[]'::jsonb);
end $$;

-- La serveuse demande l'ardoise pour son ticket envoyé
create or replace function public.gb_ticket_credit(p_ticket uuid, p_client uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; k public.credit_clients;
begin
  select * into c from gb_private.ctx();
  perform gb_private.need_opt(c.bid, 'f_ardoise', 'L''ardoise');
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.waitress_id <> c.sid then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status <> 'sent' then raise exception 'Envoyez d''abord la commande à la caisse.'; end if;
  if t.cancel_requested then raise exception 'Une annulation est en attente sur ce ticket.'; end if;
  if t.total <= 0 then raise exception 'Ticket vide.'; end if;
  select * into k from public.credit_clients where id = p_client and bar_id = c.bid and active;
  if not found then raise exception 'Ce client n''a pas d''ardoise ouverte.'; end if;
  update public.tickets set status = 'cashed', pay_method = 'credit', credit_client = k.id, received = t.total, change_due = 0, change_status = 'none',
    cashed_at = now(), updated_at = now() where id = p_ticket;
end $$;

-- La caisse valide (ou refuse) ; plafond dépassé : seuls le directeur et le PDG valident
create or replace function public.gb_credit_validate(p_ticket uuid, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; k public.credit_clients; bal int; d uuid;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la caisse et à la direction.'; end if;
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found or t.status <> 'cashed' or t.pay_method <> 'credit' then raise exception 'Aucune ardoise en attente sur ce ticket.'; end if;
  select * into k from public.credit_clients where id = t.credit_client;
  if not coalesce(p_ok, false) then
    update public.tickets set status = 'sent', pay_method = null, credit_client = null, received = null, change_due = 0, cashed_at = null, updated_at = now() where id = p_ticket;
    perform gb_private.log(c.bid, c.sid, 'ardoise_refusee', jsonb_build_object('client', k.name, 'ticket', t.number, 'montant', t.total));
    return jsonb_build_object('ok', false);
  end if;
  bal := gb_private.credit_balance(k.id);
  if not k.active then raise exception 'L''ardoise de % est fermée.', k.name; end if;
  if bal + t.total > k.credit_limit and c.srole not in ('pdg', 'directeur') then
    raise exception 'Plafond dépassé : % doit déjà % pour un plafond de %. Seul le directeur ou le PDG peut valider.', k.name, gb_private.fcfa(bal), gb_private.fcfa(k.credit_limit); end if;
  d := gb_private.current_day(c.bid, c.sid);
  insert into public.credit_moves(bar_id, client_id, ticket_id, kind, amount, day_id, created_by) values (c.bid, k.id, t.id, 'dette', t.total, d, c.sid);
  update public.tickets set status = 'paid', paid_at = now(), updated_at = now() where id = p_ticket;
  perform gb_private.log(c.bid, c.sid, 'ardoise_validee', jsonb_build_object('client', k.name, 'ticket', t.number, 'montant', t.total, 'solde', bal + t.total));
  return jsonb_build_object('ok', true, 'balance', bal + t.total);
end $$;

-- Remboursement : espèces dans le tiroir (versement enregistré au nom de la caisse) ou Mobile Money
create or replace function public.gb_credit_repay(p_client uuid, p_amount int, p_method text default 'cash', p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; k public.credit_clients; bal int; d uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into k from public.credit_clients where id = p_client and bar_id = c.bid for update;
  if not found then raise exception 'Client introuvable.'; end if;
  if p_method not in ('cash', 'momo') then raise exception 'Mode de paiement inconnu.'; end if;
  bal := gb_private.credit_balance(k.id);
  if p_amount is null or p_amount <= 0 then raise exception 'Indiquez le montant remboursé.'; end if;
  if p_amount > bal then raise exception '% ne doit que %.', k.name, gb_private.fcfa(bal); end if;
  d := gb_private.current_day(c.bid, c.sid);
  insert into public.credit_moves(bar_id, client_id, kind, amount, method, day_id, created_by, note) values (c.bid, k.id, 'remboursement', p_amount, p_method, d, c.sid, nullif(trim(coalesce(p_note, '')), ''));
  if p_method = 'cash' then
    insert into public.remittances(bar_id, day_id, waitress_id, expected, received, ticket_count, created_by) values (c.bid, d, c.sid, p_amount, p_amount, 0, c.sid);
  end if;
  perform gb_private.log(c.bid, c.sid, 'ardoise_remboursee', jsonb_build_object('client', k.name, 'montant', p_amount, 'mode', p_method, 'reste', bal - p_amount));
  return jsonb_build_object('balance', bal - p_amount);
end $$;

revoke all on function public.gb_credit_client_save(uuid, text, text, int, boolean, text), public.gb_credit_list(), public.gb_credit_history(uuid),
  public.gb_ticket_credit(uuid, uuid), public.gb_credit_validate(uuid, boolean), public.gb_credit_repay(uuid, int, text, text) from public, anon;
grant execute on function public.gb_credit_client_save(uuid, text, text, int, boolean, text), public.gb_credit_list(), public.gb_credit_history(uuid),
  public.gb_ticket_credit(uuid, uuid), public.gb_credit_validate(uuid, boolean), public.gb_credit_repay(uuid, int, text, text) to authenticated;

-- Notifications : ardoise demandée (caisse), validée ou refusée (serveuse)
create or replace function gb_private.push_tickets() returns trigger
language plpgsql security definer set search_path = '' as $$
declare w public.staff; who text; cl text;
begin
  select * into w from public.staff where id = new.waitress_id; who := coalesce(w.name, '');
  if w.role = 'serveuse' then
    if new.status = 'sent' and old.status = 'draft' then
      perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Nouvelle commande', who || ' · ' || coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=direct', 't' || new.id);
    end if;
    if new.cancel_requested and not coalesce(old.cancel_requested, false) then
      perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Annulation demandée', who || ' · ' || coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=direct', 'c' || new.id);
    end if;
    if new.status = 'cashed' and old.status <> 'cashed' and new.pay_method = 'momo' then
      perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Mobile Money à vérifier', who || ' · ' || coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=direct', 'm' || new.id);
    end if;
    if new.status = 'cashed' and old.status <> 'cashed' and new.pay_method = 'credit' then
      select name into cl from public.credit_clients where id = new.credit_client;
      perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Ardoise demandée', who || ' · ' || coalesce(cl, '') || ' · ' || gb_private.fcfa(new.total), './?tab=direct', 'a' || new.id);
    end if;
    if new.status = 'sent' and old.status = 'cashed' and old.pay_method = 'credit' then
      perform gb_private.push(new.bar_id, array[new.waitress_id], 'Ardoise refusée par la caisse', coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total) || ' : faites payer le client.', './?tab=service', 'a' || new.id);
    end if;
    if new.status = 'paid' and old.status <> 'paid' then
      perform gb_private.push(new.bar_id, array[new.waitress_id], case when new.pay_method = 'momo' then 'Paiement Mobile Money reçu' when new.pay_method = 'credit' then 'Ardoise validée par la caisse' else 'Commande validée par la caisse' end,
        coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=service', 'p' || new.id);
    end if;
    if new.waitress_id <> old.waitress_id then
      perform gb_private.push(new.bar_id, array[new.waitress_id], 'Table confiée', coalesce(new.client_label, '') || ' · ticket N°' || coalesce(new.number::text, '') || ' est maintenant à vous.', './?tab=service', 'x' || new.id);
    end if;
  end if;
  return null;
end $$;

-- Rapport de clôture : ventes à l'ardoise et remboursements du jour
create or replace function public.gb_day_close(p_counted integer, p_force boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; d public.service_days; pending int; s jsonb; exp int; sales int; cash_in int; change_out int; momo int; vouch int; tir int; pl jsonb;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if p_counted is null or p_counted < 0 then raise exception 'Saisissez les espèces comptées dans la caisse.'; end if;
  select * into d from public.service_days where bar_id = c.bid and status = 'open' for update;
  if not found then raise exception 'Aucune journée de service ouverte.'; end if;
  select count(*) into pending from public.tickets where day_id = d.id and status in ('draft','sent','cashed');
  if pending > 0 and not coalesce(p_force, false) then
    raise exception 'Il reste % ticket(s) non soldé(s). Soldez-les ou forcez la clôture.', pending using errcode = 'P0002';
  end if;
  select coalesce(sum(total) filter (where status in ('cashed','paid')), 0),
         coalesce(sum(total) filter (where status = 'paid' and pay_method = 'momo'), 0),
         coalesce(sum(change_due) filter (where change_status = 'given'), 0),
         coalesce(sum(change_due) filter (where change_status = 'voucher'), 0)
    into sales, momo, change_out, vouch
  from public.tickets where day_id = d.id;
  select coalesce(sum(received), 0) into cash_in from public.remittances where day_id = d.id;
  tir := gb_private.tiroir_out(c.bid, d.opened_at);
  exp := cash_in - change_out - tir;
  -- Plats vendus (tickets payés de la journée), au prix enregistré sur le ticket
  select jsonb_build_object('montant', coalesce(sum(x.m), 0), 'qte', coalesce(sum(x.q), 0),
      'detail', coalesce(jsonb_agg(jsonb_build_object('plat', x.name, 'qte', x.q, 'prix', x.unit_price, 'montant', x.m) order by x.m desc), '[]'::jsonb))
    into pl
  from (select p.name, i.unit_price, sum(i.qty)::int q, sum(i.qty * i.unit_price)::int m
        from public.ticket_items i join public.tickets t on t.id = i.ticket_id join public.products p on p.id = i.product_id
        where t.day_id = d.id and t.status in ('cashed', 'paid') and (p.category = 'Cuisine' or p.unit in ('plat', 'portion'))
        group by p.name, i.unit_price) x;
  select jsonb_build_object(
    'ventes', sales, 'especes_versees', cash_in, 'monnaie_rendue', change_out, 'mobile_money', momo, 'bons_emis', vouch,
    'depenses_caisse', tir, 'plats', pl, 'boissons', sales - coalesce((pl->>'montant')::int, 0),
    'ardoise', coalesce((select sum(total) from public.tickets where day_id = d.id and status = 'paid' and pay_method = 'credit'), 0),
    'ardoise_remb', coalesce((select sum(amount) from public.credit_moves where bar_id = c.bid and kind = 'remboursement' and created_at >= d.opened_at), 0),
    'tickets', (select count(*) from public.tickets where day_id = d.id and status in ('cashed','paid')),
    'annules', (select count(*) from public.tickets where day_id = d.id and status = 'cancelled'),
    'non_soldes', pending,
    'services', coalesce((select jsonb_agg(jsonb_build_object('caisse', (select name from public.staff where id = h.from_staff),
        'relaye_par', (select name from public.staff where id = h.to_staff), 'heure', h.created_at, 'ventes', h.summary->'ventes',
        'compte', h.counted, 'ecart_service', h.summary->'ecart_service') order by h.created_at) from public.cash_handovers h where h.day_id = d.id), '[]'::jsonb),
    'cuisine_pertes', coalesce((select jsonb_agg(jsonb_build_object('plat', p.name, 'qte', k.qty, 'issue', k.status, 'valeur', k.qty * coalesce(p.cost, 0), 'note', k.note))
        from public.kitchen_orders k join public.products p on p.id = k.product_id where k.bar_id = c.bid and k.status in ('perte', 'personnel') and k.decided_at >= d.opened_at), '[]'::jsonb),
    'serveuses', coalesce((select jsonb_agg(jsonb_build_object(
        'nom', st.name,
        'ventes', coalesce((select sum(total) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id and t.status in ('cashed','paid')), 0),
        'tickets', (select count(*) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id and t.status in ('cashed','paid')),
        'corrections', coalesce((select sum(corrections) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id), 0),
        'annules', (select count(*) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id and t.status = 'cancelled'),
        'ecart_versements', coalesce((select sum(diff) from public.remittances r where r.day_id = d.id and r.waitress_id = st.id), 0),
        'bouteilles_en_main', coalesce((select sum(greatest(qty, 0)) from public.holdings h where h.waitress_id = st.id), 0)
      ) order by st.name) from public.staff st where st.bar_id = c.bid and st.role = 'serveuse'), '[]'::jsonb)
  ) into s;
  update public.service_days set status = 'closed', closed_at = now(), closed_by = c.sid, counted_cash = p_counted,
    expected_cash = exp, summary = s where id = d.id;
  perform gb_private.log(c.bid, c.sid, 'journee_cloturee', jsonb_build_object('date', d.business_date, 'ventes', sales, 'attendu', exp, 'compte', p_counted, 'ecart', p_counted - exp));
  return s || jsonb_build_object('attendu', exp, 'compte', p_counted, 'ecart', p_counted - exp, 'date', d.business_date);
end $$;
