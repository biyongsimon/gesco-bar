-- 011 : formule « Essai gratuit » (durée limitée, toutes fonctions, blocage automatique à la fin)
--       + réglage éditeur : les nouveaux bars démarrent en essai de N jours (sinon : bêta illimitée)
alter table public.platform_config add column if not exists trial_days int check (trial_days is null or trial_days between 1 and 90);

create or replace function public.gb_pf_bar_set(p_bar uuid, p_plan text, p_until date, p_suspended boolean, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if p_plan not in ('beta', 'essai', 'simple', 'premium', 'gold', 'lounge') then raise exception 'Formule inconnue.'; end if;
  if p_plan <> 'beta' and p_until is null then raise exception 'Indiquez la date de fin.'; end if;
  update public.bars set plan = p_plan, plan_until = case when p_plan = 'beta' then null else p_until end, suspended = coalesce(p_suspended, suspended), admin_note = nullif(trim(p_note), '') where id = p_bar;
  if not found then raise exception 'Bar introuvable.'; end if;
  insert into public.platform_log(admin_id, action, bar_id, data) values (auth.uid(), 'bar_modifie', p_bar, jsonb_build_object('formule', p_plan, 'jusqu_au', p_until, 'suspendu', p_suspended, 'note', p_note));
end $$;

create or replace function public.gb_pf_trial_days(p_days int) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if p_days is not null and (p_days < 1 or p_days > 90) then raise exception 'Durée d''essai : entre 1 et 90 jours.'; end if;
  update public.platform_config set trial_days = p_days where id = 1;
  insert into public.platform_log(admin_id, action, data) values (auth.uid(), 'reglages', jsonb_build_object('essai_nouveaux_bars_jours', p_days));
end $$;
revoke all on function public.gb_pf_trial_days(int) from public, anon; grant execute on function public.gb_pf_trial_days(int) to authenticated;

create or replace function public.gb_admin_create_bar(p_user uuid, p_bar_name text, p_city text, p_owner_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b uuid; s uuid; k text; td int;
begin
  perform gb_private.check_pin_format(p_pin);
  if nullif(trim(p_bar_name), '') is null then raise exception 'Indiquez le nom du bar.'; end if;
  if nullif(trim(p_owner_name), '') is null then raise exception 'Indiquez votre nom.'; end if;
  loop
    k := gb_private.rand_code(6);
    exit when not exists (select 1 from public.bars where code = k);
  end loop;
  select trial_days into td from public.platform_config where id = 1;
  insert into public.bars(name, code, city, owner_user, plan, plan_until)
  values (trim(p_bar_name), k, nullif(trim(p_city), ''), p_user, case when td is null then 'beta' else 'essai' end, case when td is null then null else gb_private.biz_date() + td end) returning id into b;
  insert into public.staff(bar_id, user_id, name, role) values (b, p_user, trim(p_owner_name), 'pdg') returning id into s;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (s, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  perform gb_private.seed_products(b);
  perform gb_private.log(b, s, 'bar_cree', jsonb_build_object('nom', trim(p_bar_name), 'essai_jours', td));
  return jsonb_build_object('bar_id', b, 'code', k, 'staff_id', s);
end $$;

create or replace function public.gb_pf_overview() returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  perform gb_private.need_admin();
  select jsonb_build_object(
    'bars', (select count(*) from public.bars),
    'bars_actifs_7j', (select count(distinct bar_id) from public.tickets where created_at > now() - interval '7 days'),
    'employes', (select count(*) from public.staff where active),
    'payants', (select count(*) from public.bars where plan not in ('beta', 'essai') and plan_until >= current_date),
    'beta', (select count(*) from public.bars where plan = 'beta'),
    'essais', (select count(*) from public.bars where plan = 'essai' and plan_until >= current_date),
    'mrr', (select coalesce(sum(case plan when 'simple' then 10000 when 'premium' then 15000 when 'gold' then 20000 when 'lounge' then 30000 else 0 end), 0) from public.bars where plan not in ('beta', 'essai') and plan_until >= current_date),
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
