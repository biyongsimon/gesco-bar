-- 013 : paiement direct des abonnements par Mobile Money via le compte Notch Pay de l'éditeur
--       (demande envoyée au téléphone du PDG, validation automatique de la formule dès confirmation)
alter table public.subscriptions add column if not exists channel text not null default 'transfert';
alter table public.subscriptions drop constraint if exists subscriptions_channel_check;
alter table public.subscriptions add constraint subscriptions_channel_check check (channel in ('transfert', 'notchpay'));
alter table public.subscriptions add column if not exists provider_ref text;
alter table public.subscriptions add column if not exists payer_phone text;
alter table public.subscriptions drop constraint if exists subscriptions_status_check;
alter table public.subscriptions add constraint subscriptions_status_check check (status in ('en_attente', 'validee', 'refusee', 'echouee'));
alter table public.platform_config add column if not exists sub_push boolean not null default false;

create or replace function public.gb_pf_sub_push(p_on boolean) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  update public.platform_config set sub_push = coalesce(p_on, false) where id = 1;
  insert into public.platform_log(admin_id, action, data) values (auth.uid(), 'reglages', jsonb_build_object('paiement_direct_abonnements', p_on));
end $$;

-- Appelées uniquement par la fonction serveur (clé de service)
create or replace function public.gb_admin_sub_push_start(p_user uuid, p_plan text, p_months int, p_method text, p_phone text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff; b public.bars; price int; total int; ph text; v_id uuid;
begin
  select * into s from public.staff where user_id = p_user and active;
  if not found or s.role not in ('pdg', 'directeur') then raise exception 'Réservé au PDG et au directeur.'; end if;
  select * into b from public.bars where id = s.bar_id;
  if b.suspended then raise exception 'Ce bar est suspendu par BISMO Agency. Contactez BISMO Agency.'; end if;
  price := case p_plan when 'simple' then 10000 when 'premium' then 15000 when 'gold' then 20000 when 'lounge' then 30000 end;
  if price is null then raise exception 'Formule inconnue.'; end if;
  if p_months not in (1, 3, 6, 12) then raise exception 'Durée invalide.'; end if;
  if p_method not in ('orange', 'mtn') then raise exception 'Choisissez Orange Money ou MTN MoMo.'; end if;
  ph := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'); if length(ph) = 12 and left(ph, 3) = '237' then ph := right(ph, 9); end if;
  if ph !~ '^6[0-9]{8}$' then raise exception 'Numéro camerounais invalide (9 chiffres commençant par 6).'; end if;
  update public.subscriptions set status = 'echouee', decided_at = now(), admin_note = 'Délai dépassé sans confirmation'
    where bar_id = b.id and status = 'en_attente' and channel = 'notchpay' and created_at < now() - interval '15 minutes';
  if exists (select 1 from public.subscriptions where bar_id = b.id and status = 'en_attente') then raise exception 'Un paiement est déjà en cours : validez la demande sur le téléphone ou attendez quelques minutes.'; end if;
  total := price * case when p_months = 12 then 10 else p_months end;
  insert into public.subscriptions(bar_id, plan, months, amount, method, reference, pay_ref, requested_by, channel, payer_phone)
  values (b.id, p_plan, p_months, total, p_method, 'Mobile Money (en cours)', 'GB-' || b.code, s.id, 'notchpay', ph) returning id into v_id;
  perform gb_private.log(b.id, s.id, 'abonnement_paiement_direct', jsonb_build_object('formule', p_plan, 'mois', p_months, 'montant', total));
  return jsonb_build_object('id', v_id, 'amount', total, 'phone', '+237' || ph, 'bar', b.name, 'code', b.code,
    'label', 'Abonnement GesCo Bar ' || p_plan || ' ' || p_months || ' mois - ' || b.name || ' (' || b.code || ')');
end $$;

create or replace function public.gb_admin_sub_push_ref(p_id uuid, p_ref text) returns void language sql security definer set search_path = '' as $$
  update public.subscriptions set provider_ref = p_ref where id = p_id $$;

create or replace function public.gb_admin_sub_get(p_user uuid, p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare x public.subscriptions; ok boolean;
begin
  select * into x from public.subscriptions where id = p_id; if not found then raise exception 'Paiement introuvable.'; end if;
  ok := exists (select 1 from public.staff where user_id = p_user and active and bar_id = x.bar_id and role in ('pdg', 'directeur'))
     or exists (select 1 from gb_private.platform_admins where user_id = p_user);
  if not ok then raise exception 'Accès refusé.'; end if;
  return jsonb_build_object('id', x.id, 'status', x.status, 'channel', x.channel, 'ref', x.provider_ref, 'created', x.created_at, 'plan', x.plan, 'months', x.months, 'amount', x.amount);
end $$;

create or replace function public.gb_admin_sub_push_done(p_id uuid, p_ok boolean, p_ref text, p_msg text) returns text language plpgsql security definer set search_path = '' as $$
declare x public.subscriptions; b public.bars;
begin
  select * into x from public.subscriptions where id = p_id for update;
  if not found or x.status <> 'en_attente' or x.channel <> 'notchpay' then return coalesce(x.status, 'introuvable'); end if;
  if p_ok then
    update public.subscriptions set status = 'validee', decided_at = now(), reference = coalesce(nullif(p_ref, ''), reference),
      admin_note = 'Payé par Mobile Money (Notch Pay), validé automatiquement' where id = p_id;
    select * into b from public.bars where id = x.bar_id for update;
    update public.bars set plan = x.plan, plan_trial_until = null, trial_plan = null,
      plan_until = (greatest(coalesce(b.plan_until, current_date), current_date) + make_interval(months => x.months))::date where id = x.bar_id;
    insert into public.platform_log(admin_id, action, bar_id, data) values (null, 'paiement_auto', x.bar_id, jsonb_build_object('montant', x.amount, 'formule', x.plan, 'mois', x.months, 'reference', p_ref));
    return 'validee';
  end if;
  update public.subscriptions set status = 'echouee', decided_at = now(), admin_note = left(coalesce(p_msg, 'Paiement non abouti'), 300) where id = p_id;
  return 'echouee';
end $$;

revoke all on function public.gb_admin_sub_push_start(uuid, text, int, text, text), public.gb_admin_sub_push_ref(uuid, text), public.gb_admin_sub_get(uuid, uuid), public.gb_admin_sub_push_done(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.gb_admin_sub_push_start(uuid, text, int, text, text), public.gb_admin_sub_push_ref(uuid, text), public.gb_admin_sub_get(uuid, uuid), public.gb_admin_sub_push_done(uuid, boolean, text, text) to service_role;
revoke all on function public.gb_pf_sub_push(boolean) from public, anon; grant execute on function public.gb_pf_sub_push(boolean) to authenticated;
