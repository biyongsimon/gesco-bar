-- GesCo Bar · v4 : espace éditeur BISMO Agency, blocage à l'expiration, limites des formules

-- 1. Comptes éditeur (BISMO Agency) et code d'installation à usage unique
create table if not exists gb_private.platform_admins (user_id uuid primary key references auth.users(id) on delete cascade, email text, created_at timestamptz not null default now());
create table if not exists gb_private.platform_setup (id int primary key default 1 check (id = 1), code_hash text not null, used_at timestamptz);
create table if not exists public.platform_log (id bigserial primary key, admin_id uuid, action text not null, bar_id uuid, data jsonb, created_at timestamptz not null default now());
alter table public.platform_log enable row level security;

create or replace function gb_private.is_platform_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from gb_private.platform_admins where user_id = auth.uid()) $$;
create or replace function gb_private.need_admin() returns void language plpgsql stable security definer set search_path = '' as $$
begin if not gb_private.is_platform_admin() then raise exception 'Réservé à l''éditeur BISMO Agency.' using errcode = '42501'; end if; end $$;
create policy platform_log_read on public.platform_log for select to authenticated using ((select gb_private.is_platform_admin()));

-- Réclamation du compte éditeur (appelée par la fonction serveur avec la clé de service)
create or replace function public.gb_admin_claim_setup(p_code text, p_user uuid, p_email text) returns void language plpgsql security definer set search_path = '' as $$
declare s gb_private.platform_setup;
begin
  select * into s from gb_private.platform_setup where id = 1 for update;
  if not found or s.used_at is not null then raise exception 'Le code d''installation a déjà été utilisé.'; end if;
  if s.code_hash <> extensions.crypt(upper(trim(p_code)), s.code_hash) then raise exception 'Code d''installation incorrect.'; end if;
  insert into gb_private.platform_admins(user_id, email) values (p_user, lower(p_email)) on conflict do nothing;
  update gb_private.platform_setup set used_at = now() where id = 1;
end $$;
create or replace function public.gb_admin_setup_open() returns boolean language sql security definer set search_path = '' as $$
  select exists (select 1 from gb_private.platform_setup where id = 1 and used_at is null) $$;
revoke all on function public.gb_admin_claim_setup(text, uuid, text), public.gb_admin_setup_open() from public, anon, authenticated;
grant execute on function public.gb_admin_claim_setup(text, uuid, text), public.gb_admin_setup_open() to service_role;

-- 2. Suspension et blocage à l'expiration (3 jours de grâce ; activation provisoire de 72 h respectée)
alter table public.bars add column if not exists suspended boolean not null default false, add column if not exists admin_note text;

create or replace function gb_private.bar_block(p_bar uuid) returns text language sql stable security definer set search_path = '' as $$
  select case
    when b.suspended then 'ACCES_BLOQUE: Ce bar est suspendu par BISMO Agency. Contactez BISMO Agency.'
    when b.plan <> 'beta' and b.plan_until is not null and b.plan_until + 3 < gb_private.biz_date()
         and coalesce(b.plan_trial_until, '-infinity') < now() then 'ACCES_BLOQUE: L''abonnement du bar a expiré. Le PDG ou le directeur doit le renouveler (rubrique Abonnement).'
  end from public.bars b where b.id = p_bar $$;

create or replace function gb_private.ctx(out sid uuid, out bid uuid, out srole text, out sname text) returns record
language plpgsql stable security definer set search_path = '' as $$
declare blk text;
begin
  select s.id, s.bar_id, s.role, s.name into sid, bid, srole, sname from public.staff s where s.user_id = auth.uid() and s.active;
  if sid is null then raise exception 'Session invalide ou compte désactivé. Reconnectez-vous.' using errcode = '42501'; end if;
  if coalesce(current_setting('gb.allow_blocked', true), '') <> '1' then
    blk := gb_private.bar_block(bid);
    if blk is not null then raise exception '%', blk using errcode = 'P0001'; end if;
  end if;
end $$;

-- 3. Limites des formules (bêta et Lounge : illimité)
create or replace function gb_private.check_staff_limit(p_bar uuid, p_role text, p_except uuid default null) returns void
language plpgsql stable security definer set search_path = '' as $$
declare b public.bars; pl text; nserv int; ncaisse int; ntot int; label text;
begin
  select * into b from public.bars where id = p_bar;
  pl := case when b.plan_trial_until > now() and b.trial_plan is not null then b.trial_plan else b.plan end;
  if pl in ('beta', 'lounge') or pl is null then return; end if;
  label := case pl when 'simple' then 'Snack Simple' when 'premium' then 'Snack Premium' when 'gold' then 'Snack Gold' else pl end;
  select count(*) filter (where role = 'serveuse'), count(*) filter (where role = 'caisse'), count(*) filter (where role <> 'pdg')
    into nserv, ncaisse, ntot from public.staff where bar_id = p_bar and active and id is distinct from p_except;
  if p_role = 'directeur' and pl in ('simple', 'premium') then raise exception 'La formule % ne comprend pas de directeur : passez à Snack Gold.', label; end if;
  if pl = 'simple' and ((p_role = 'serveuse' and nserv >= 3) or (p_role = 'caisse' and ncaisse >= 1)) then
    raise exception 'La formule Snack Simple comprend 1 caisse et 3 serveuses : passez à Snack Premium pour en ajouter.'; end if;
  if pl = 'premium' and ((p_role = 'serveuse' and nserv >= 6) or (p_role = 'caisse' and ncaisse >= 2)) then
    raise exception 'La formule Snack Premium comprend 2 caisses et 6 serveuses : passez à Snack Gold pour en ajouter.'; end if;
  if pl = 'gold' and ntot >= 12 then raise exception 'La formule Snack Gold comprend 12 employés : passez à Lounge pour en ajouter.'; end if;
end $$;

create or replace function public.gb_admin_add_staff(p_caller uuid, p_user uuid, p_name text, p_role text, p_pin text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.staff; s uuid; blk text;
begin
  select * into c from public.staff where user_id = p_caller and active and role in ('pdg','directeur');
  if not found then raise exception 'Seuls le directeur et le PDG ajoutent des membres.'; end if;
  blk := gb_private.bar_block(c.bar_id); if blk is not null then raise exception '%', blk; end if;
  perform gb_private.check_pin_format(p_pin);
  if nullif(trim(p_name), '') is null then raise exception 'Indiquez un nom.'; end if;
  if p_role not in ('directeur','caisse','serveuse') then raise exception 'Rôle inconnu.'; end if;
  if p_role = 'directeur' and c.role <> 'pdg' then raise exception 'Seul le PDG peut ajouter un directeur.'; end if;
  perform gb_private.check_staff_limit(c.bar_id, p_role);
  insert into public.staff(bar_id, user_id, name, role) values (c.bar_id, p_user, trim(p_name), p_role) returning id into s;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (s, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  perform gb_private.log(c.bar_id, c.id, 'membre_ajoute', jsonb_build_object('membre', trim(p_name), 'role', p_role));
  return s;
exception when unique_violation then raise exception 'Ce nom est déjà utilisé dans l''équipe.';
end $$;

create or replace function public.gb_staff_update(p_staff uuid, p_name text, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; s public.staff; busy int; nr text;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into s from public.staff where id = p_staff and bar_id = c.bid for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  nr := coalesce(p_role, s.role);
  if p_staff = c.sid and (coalesce(p_active, true) = false or nr <> s.role) then raise exception 'Vous ne pouvez ni changer votre propre rôle ni vous désactiver.'; end if;
  if c.srole = 'directeur' and p_staff <> c.sid and (s.role in ('pdg','directeur') or nr in ('pdg','directeur')) then raise exception 'Seul le PDG peut gérer un directeur.'; end if;
  if s.role = 'pdg' and p_staff <> c.sid then raise exception 'Le compte du PDG ne peut être modifié que par lui-même.'; end if;
  if nr = 'pdg' and s.role <> 'pdg' then raise exception 'Il ne peut y avoir qu''un seul PDG.'; end if;
  if coalesce(p_active, s.active) and (not s.active or nr <> s.role) then perform gb_private.check_staff_limit(c.bid, nr, p_staff); end if;
  if coalesce(p_active, true) = false and s.active then
    select count(*) into busy from public.tickets where waitress_id = p_staff and status in ('draft','sent','cashed');
    if busy > 0 then raise exception '% a encore % ticket(s) non soldé(s).', s.name, busy; end if;
    if exists (select 1 from public.holdings where waitress_id = p_staff and qty <> 0) then raise exception 'Reprenez d''abord les bouteilles en main de %.', s.name; end if;
  end if;
  update public.staff set name = coalesce(nullif(trim(p_name), ''), name), role = nr, active = coalesce(p_active, active) where id = p_staff;
  perform gb_private.log(c.bid, c.sid, 'equipe_modifiee', jsonb_build_object('membre', s.name, 'nom', coalesce(nullif(trim(p_name), ''), s.name), 'role', nr, 'actif', coalesce(p_active, s.active)));
exception when unique_violation then raise exception 'Ce nom est déjà utilisé dans l''équipe.';
end $$;

-- Le paiement de l'abonnement reste possible quand le bar est bloqué pour expiration (pas en cas de suspension)
create or replace function public.gb_sub_request(p_plan text, p_months int, p_method text, p_reference text, p_proof text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; price int; total int; v_id uuid; b public.bars; trial timestamptz;
begin
  perform set_config('gb.allow_blocked', '1', true);
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  perform set_config('gb.allow_blocked', '', true);
  select * into b from public.bars where id = c.bid;
  if b.suspended then raise exception 'Ce bar est suspendu par BISMO Agency. Contactez BISMO Agency.'; end if;
  price := case p_plan when 'simple' then 10000 when 'premium' then 15000 when 'gold' then 20000 when 'lounge' then 30000 end;
  if price is null then raise exception 'Formule inconnue.'; end if;
  if p_months not in (1, 3, 6, 12) then raise exception 'Durée invalide.'; end if;
  if p_method not in ('orange', 'mtn') then raise exception 'Mode de paiement inconnu.'; end if;
  if length(trim(coalesce(p_reference, ''))) < 4 and p_proof is null then raise exception 'Collez la référence du SMS ou ajoutez la capture du SMS.'; end if;
  if exists (select 1 from public.subscriptions where bar_id = c.bid and status = 'en_attente') then raise exception 'Un paiement est déjà en cours de vérification.'; end if;
  if p_proof is not null and (storage.foldername(p_proof))[1] <> c.bid::text then raise exception 'Capture invalide.'; end if;
  total := price * case when p_months = 12 then 10 else p_months end;
  insert into public.subscriptions(bar_id, plan, months, amount, method, reference, proof_path, pay_ref, requested_by)
  values (c.bid, p_plan, p_months, total, p_method, coalesce(nullif(trim(p_reference), ''), '(capture jointe)'), p_proof, 'GB-' || b.code, c.sid) returning subscriptions.id into v_id;
  trial := now() + interval '72 hours';
  update public.bars set plan_trial_until = trial, trial_plan = p_plan where id = c.bid;
  perform gb_private.log(c.bid, c.sid, 'abonnement_demande', jsonb_build_object('formule', p_plan, 'mois', p_months, 'montant', total));
  return jsonb_build_object('id', v_id, 'amount', total, 'trial_until', trial);
end $$;
revoke all on function public.gb_sub_request(text, int, text, text, text) from public, anon;
grant execute on function public.gb_sub_request(text, int, text, text, text) to authenticated;

-- 4. Fonctions de l'espace éditeur
alter table public.subscriptions add column if not exists admin_note text, add column if not exists decided_by uuid;

create or replace function public.gb_pf_overview() returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  perform gb_private.need_admin();
  select jsonb_build_object(
    'bars', (select count(*) from public.bars),
    'bars_actifs_7j', (select count(distinct bar_id) from public.tickets where created_at > now() - interval '7 days'),
    'employes', (select count(*) from public.staff where active),
    'payants', (select count(*) from public.bars where plan <> 'beta' and plan_until >= current_date),
    'beta', (select count(*) from public.bars where plan = 'beta'),
    'mrr', (select coalesce(sum(case plan when 'simple' then 10000 when 'premium' then 15000 when 'gold' then 20000 when 'lounge' then 30000 else 0 end), 0) from public.bars where plan <> 'beta' and plan_until >= current_date),
    'encaisse_mois', (select coalesce(sum(amount), 0) from public.subscriptions where status = 'validee' and date_trunc('month', decided_at) = date_trunc('month', now())),
    'encaisse_total', (select coalesce(sum(amount), 0) from public.subscriptions where status = 'validee'),
    'a_valider', (select count(*) from public.subscriptions where status = 'en_attente'),
    'expirent_7j', (select count(*) from public.bars where plan <> 'beta' and plan_until between current_date and current_date + 7),
    'expires', (select count(*) from public.bars where plan <> 'beta' and plan_until < current_date),
    'suspendus', (select count(*) from public.bars where suspended),
    'tickets_30j', (select count(*) from public.tickets where created_at > now() - interval '30 days' and status in ('cashed','paid')),
    'ventes_30j', (select coalesce(sum(total), 0) from public.tickets where created_at > now() - interval '30 days' and status in ('cashed','paid')),
    'inscriptions', (select coalesce(jsonb_agg(x order by x->>'mois'), '[]') from (select jsonb_build_object('mois', to_char(m, 'YYYY-MM'), 'n', (select count(*) from public.bars where date_trunc('month', created_at) = m)) x
        from generate_series(date_trunc('month', now()) - interval '5 months', date_trunc('month', now()), interval '1 month') m) z)
  ) into r;
  return r;
end $$;

create or replace function public.gb_pf_bars() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  return (select coalesce(jsonb_agg(row_to_json(x) order by x.created_at desc), '[]') from (
    select b.id, b.name, b.code, b.city, b.created_at, b.plan, b.plan_until, b.plan_trial_until, b.trial_plan, b.suspended, b.admin_note,
      b.legal_name, b.niu, b.kyc_status, b.id_doc_path, b.om_code is not null or b.mtn_code is not null as qr_ok, b.push_enabled,
      (select s.name from public.staff s where s.bar_id = b.id and s.role = 'pdg' limit 1) as pdg,
      (select u.email from auth.users u where u.id = b.owner_user) as email,
      (select count(*) from public.staff s where s.bar_id = b.id and s.active) as employes,
      (select count(*) from public.staff s where s.bar_id = b.id and s.active and s.role = 'serveuse') as serveuses,
      (select max(t.created_at) from public.tickets t where t.bar_id = b.id) as derniere_activite,
      (select count(*) from public.tickets t where t.bar_id = b.id and t.created_at > now() - interval '30 days' and t.status in ('cashed','paid')) as tickets_30j,
      (select coalesce(sum(t.total), 0) from public.tickets t where t.bar_id = b.id and t.created_at > now() - interval '30 days' and t.status in ('cashed','paid')) as ventes_30j,
      (select count(*) from public.subscriptions x where x.bar_id = b.id and x.status = 'en_attente') as a_valider,
      gb_private.bar_block(b.id) as blocage
    from public.bars b) x);
end $$;

create or replace function public.gb_pf_subs() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  return (select coalesce(jsonb_agg(row_to_json(x) order by (x.status = 'en_attente') desc, x.created_at desc), '[]') from (
    select s.*, b.name as bar_name, b.code as bar_code, b.city, (select st.name from public.staff st where st.id = s.requested_by) as demandeur
    from public.subscriptions s join public.bars b on b.id = s.bar_id order by s.created_at desc limit 300) x);
end $$;

create or replace function public.gb_pf_sub_decide(p_id uuid, p_ok boolean, p_note text) returns void language plpgsql security definer set search_path = '' as $$
declare s public.subscriptions; b public.bars;
begin
  perform gb_private.need_admin();
  select * into s from public.subscriptions where id = p_id for update; if not found or s.status <> 'en_attente' then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  update public.subscriptions set status = case when p_ok then 'validee' else 'refusee' end, decided_at = now(), decided_by = auth.uid(), admin_note = nullif(trim(p_note), '') where id = p_id;
  select * into b from public.bars where id = s.bar_id;
  if p_ok then update public.bars set plan = s.plan, plan_trial_until = null, trial_plan = null,
      plan_until = (greatest(coalesce(b.plan_until, current_date), current_date) + make_interval(months => s.months))::date where id = s.bar_id;
  else update public.bars set plan_trial_until = null, trial_plan = null where id = s.bar_id; end if;
  insert into public.platform_log(admin_id, action, bar_id, data) values (auth.uid(), case when p_ok then 'paiement_valide' else 'paiement_refuse' end, s.bar_id, jsonb_build_object('montant', s.amount, 'formule', s.plan, 'mois', s.months, 'note', p_note));
end $$;

create or replace function public.gb_pf_bar_set(p_bar uuid, p_plan text, p_until date, p_suspended boolean, p_note text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if p_plan not in ('beta', 'simple', 'premium', 'gold', 'lounge') then raise exception 'Formule inconnue.'; end if;
  update public.bars set plan = p_plan, plan_until = case when p_plan = 'beta' then null else p_until end, suspended = coalesce(p_suspended, suspended), admin_note = nullif(trim(p_note), '') where id = p_bar;
  if not found then raise exception 'Bar introuvable.'; end if;
  insert into public.platform_log(admin_id, action, bar_id, data) values (auth.uid(), 'bar_modifie', p_bar, jsonb_build_object('formule', p_plan, 'jusqu_au', p_until, 'suspendu', p_suspended, 'note', p_note));
end $$;

create or replace function public.gb_pf_kyc(p_bar uuid, p_status text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if p_status not in ('non_renseigne', 'a_verifier', 'verifie', 'refuse') then raise exception 'Statut inconnu.'; end if;
  update public.bars set kyc_status = p_status where id = p_bar;
  insert into public.platform_log(admin_id, action, bar_id, data) values (auth.uid(), 'kyc', p_bar, jsonb_build_object('statut', p_status));
end $$;

create or replace function public.gb_pf_settings(p_holder text, p_om text, p_mtn text, p_om_tpl text, p_mtn_tpl text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if nullif(trim(p_om), '') is not null and trim(p_om) !~ '^6[0-9]{8}$' then raise exception 'Numéro Orange invalide (9 chiffres).'; end if;
  if nullif(trim(p_mtn), '') is not null and trim(p_mtn) !~ '^6[0-9]{8}$' then raise exception 'Numéro MTN invalide (9 chiffres).'; end if;
  update public.platform_config set holder_name = nullif(trim(p_holder), ''), om_number = nullif(trim(p_om), ''), mtn_number = nullif(trim(p_mtn), ''),
    om_tpl = nullif(trim(p_om_tpl), ''), mtn_tpl = nullif(trim(p_mtn_tpl), '') where id = 1;
  insert into public.platform_log(admin_id, action, data) values (auth.uid(), 'reglages', jsonb_build_object('orange', p_om, 'mtn', p_mtn));
end $$;

create or replace function public.gb_pf_whoami() returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('admin', gb_private.is_platform_admin(), 'email', (select email from gb_private.platform_admins where user_id = auth.uid())) $$;

revoke all on function public.gb_pf_overview(), public.gb_pf_bars(), public.gb_pf_subs(), public.gb_pf_sub_decide(uuid, boolean, text), public.gb_pf_bar_set(uuid, text, date, boolean, text),
  public.gb_pf_kyc(uuid, text), public.gb_pf_settings(text, text, text, text, text), public.gb_pf_whoami() from public, anon;
grant execute on function public.gb_pf_overview(), public.gb_pf_bars(), public.gb_pf_subs(), public.gb_pf_sub_decide(uuid, boolean, text), public.gb_pf_bar_set(uuid, text, date, boolean, text),
  public.gb_pf_kyc(uuid, text), public.gb_pf_settings(text, text, text, text, text), public.gb_pf_whoami() to authenticated;

-- L'éditeur lit les captures de paiement et les pièces d'identité, et peut supprimer les captures
create policy preuves_admin_read on storage.objects for select to authenticated using (bucket_id = 'preuves' and (select gb_private.is_platform_admin()));
create policy preuves_admin_delete on storage.objects for delete to authenticated using (bucket_id = 'preuves' and (select gb_private.is_platform_admin()));
create policy kyc_admin_read on storage.objects for select to authenticated using (bucket_id = 'kyc' and (select gb_private.is_platform_admin()));
