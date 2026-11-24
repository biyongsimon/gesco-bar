-- 024 : formule test cachée. Un prix de test réglé par l'éditeur (SQL uniquement) pour un bar précis :
--       le paiement direct (Notch Pay) facture ce petit montant pour 1 mois de la formule choisie.
--       Le prix de test s'efface tout seul après un paiement réussi. Aucun client ne peut le régler.
alter table public.bars add column if not exists sub_test_price int check (sub_test_price is null or sub_test_price between 100 and 5000);
alter table public.subscriptions add column if not exists is_test boolean not null default false;

create or replace function public.gb_admin_sub_push_start(p_user uuid, p_plan text, p_months int, p_method text, p_phone text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff; b public.bars; price int; total int; ph text; v_id uuid; tst boolean;
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
  tst := b.sub_test_price is not null;
  if tst then p_months := 1; total := b.sub_test_price; else total := price * case when p_months = 12 then 10 else p_months end; end if;
  insert into public.subscriptions(bar_id, plan, months, amount, method, reference, pay_ref, requested_by, channel, payer_phone, is_test)
  values (b.id, p_plan, p_months, total, p_method, 'Mobile Money (en cours)', 'GB-' || b.code, s.id, 'notchpay', ph, tst) returning id into v_id;
  perform gb_private.log(b.id, s.id, 'abonnement_paiement_direct', jsonb_build_object('formule', p_plan, 'mois', p_months, 'montant', total, 'test', tst));
  return jsonb_build_object('id', v_id, 'amount', total, 'phone', '+237' || ph, 'bar', b.name, 'code', b.code,
    'label', case when tst then 'TEST ' else '' end || 'Abonnement GesCo Bar ' || p_plan || ' ' || p_months || ' mois - ' || b.name || ' (' || b.code || ')');
end $$;

create or replace function public.gb_admin_sub_push_done(p_id uuid, p_ok boolean, p_ref text, p_msg text) returns text language plpgsql security definer set search_path = '' as $$
declare x public.subscriptions; b public.bars;
begin
  select * into x from public.subscriptions where id = p_id for update;
  if not found or x.status <> 'en_attente' or x.channel <> 'notchpay' then return coalesce(x.status, 'introuvable'); end if;
  if p_ok then
    update public.subscriptions set status = 'validee', decided_at = now(), reference = coalesce(nullif(p_ref, ''), reference),
      admin_note = case when x.is_test then 'TEST : ' else '' end || 'Payé par Mobile Money (Notch Pay), validé automatiquement' where id = p_id;
    select * into b from public.bars where id = x.bar_id for update;
    update public.bars set plan = x.plan, plan_trial_until = null, trial_plan = null,
      plan_until = (greatest(coalesce(b.plan_until, current_date), current_date) + make_interval(months => x.months))::date,
      sub_test_price = case when x.is_test then null else sub_test_price end where id = x.bar_id;
    insert into public.platform_log(admin_id, action, bar_id, data) values (null, 'paiement_auto', x.bar_id, jsonb_build_object('montant', x.amount, 'formule', x.plan, 'mois', x.months, 'reference', p_ref, 'test', x.is_test));
    return 'validee';
  end if;
  update public.subscriptions set status = 'echouee', decided_at = now(), admin_note = left(coalesce(p_msg, 'Paiement non abouti'), 300) where id = p_id;
  return 'echouee';
end $$;

-- Prix de test pour Bring win (bar d'essai de l'éditeur)
update public.bars set sub_test_price = 200 where id = 'c20cdf6a-087d-4e6c-87a0-2e61fa3a7564';
