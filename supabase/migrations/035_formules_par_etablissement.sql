-- 035 : formules par type d'établissement, appliquées par le serveur.
--   bar    Snack-Bar         10 000 F : boissons (1 caisse, 5 serveuses)
--   resto  Snack-Restaurant  20 000 F : + cuisine, paie, compta, paiement par numéro, imprimante (2 caisses, 10 serveuses, 2 cuisiniers, 1 directeur)
--   lounge Lounge            35 000 F : + prix de nuit, réservations, entrées, bouteilles gardées, écran mural (illimité)
-- Anciennes formules : simple/premium = niveau Snack-Bar, gold = Snack-Restaurant. Bêta et essai : tout est ouvert.
alter table public.subscriptions drop constraint if exists subscriptions_plan_check;
alter table public.subscriptions add constraint subscriptions_plan_check check (plan in ('bar', 'resto', 'lounge', 'simple', 'premium', 'gold'));

create or replace function gb_private.plan_price(p text) returns int language sql immutable as $$
  select case p when 'bar' then 10000 when 'resto' then 20000 when 'lounge' then 35000 when 'simple' then 10000 when 'premium' then 15000 when 'gold' then 20000 else 0 end $$;
create or replace function gb_private.tier_of(p text) returns int language sql immutable as $$
  select case when p in ('bar', 'simple', 'premium') then 1 when p in ('resto', 'gold') then 2 when p = 'lounge' then 3 else 9 end $$;
create or replace function gb_private.plan_tier(p_bar uuid) returns int
language sql stable security definer set search_path = '' as $$
  select case when b.plan_trial_until > now() and b.trial_plan is not null then gb_private.tier_of(b.trial_plan) else gb_private.tier_of(b.plan) end
  from public.bars b where b.id = p_bar $$;
create or replace function gb_private.need_tier(p_bar uuid, p_min int, p_label text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(gb_private.plan_tier(p_bar), 9) < p_min then
    raise exception '% est inclus à partir de la formule % (rubrique Abonnement).', p_label, case p_min when 2 then 'Snack-Restaurant' else 'Lounge' end;
  end if;
end $$;
revoke all on function gb_private.plan_tier(uuid), gb_private.need_tier(uuid, int, text) from public, anon, authenticated;

-- Une option n'est active que si elle est cochée ET comprise dans la formule
create or replace function gb_private.opt_tier(p_flag text) returns int language sql immutable as $$
  select case when p_flag in ('f_print', 'f_recettes') then 2 when p_flag in ('f_nuit', 'f_vip', 'f_porte', 'f_garde', 'f_mural') then 3 else 1 end $$;
create or replace function gb_private.need_opt(p_bar uuid, p_flag text, p_label text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select (opts->>p_flag)::boolean from public.bars where id = p_bar), false) then
    raise exception '% n''est pas activé (Réglages → Options du bar).', p_label; end if;
  perform gb_private.need_tier(p_bar, gb_private.opt_tier(p_flag), p_label);
end $$;

-- Limites d'équipe par formule
create or replace function gb_private.check_staff_limit(p_bar uuid, p_role text, p_except uuid default null) returns void
language plpgsql stable security definer set search_path = '' as $$
declare t int := coalesce(gb_private.plan_tier(p_bar), 9); n int; lim int; nm text;
begin
  if t >= 3 then return; end if;
  nm := case t when 1 then 'Snack-Bar' else 'Snack-Restaurant' end;
  lim := case p_role when 'serveuse' then case t when 1 then 5 else 10 end when 'caisse' then t when 'cuisine' then case t when 1 then 0 else 2 end
                     when 'directeur' then case t when 1 then 0 else 1 end else null end;
  if lim is null then return; end if;
  select count(*) into n from public.staff where bar_id = p_bar and active and role = p_role and id is distinct from p_except;
  if n >= lim then
    raise exception '%', case when lim = 0 and p_role = 'cuisine' then 'Le module Cuisine est inclus à partir de la formule Snack-Restaurant (rubrique Abonnement).'
      when lim = 0 then 'La formule Snack-Bar ne comprend pas de directeur : passez à Snack-Restaurant.'
      else format('La formule %s comprend %s %s%s : passez à la formule supérieure pour en ajouter.', nm, lim,
        case p_role when 'serveuse' then 'serveuse' when 'caisse' then 'caisse' when 'cuisine' then 'cuisinier' else 'directeur' end, case when lim > 1 then 's' else '' end) end;
  end if;
end $$;

-- Passage à une formule sans cuisine : le module Cuisine se coupe
create or replace function gb_private.bars_tier_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t int;
begin
  t := case when new.plan_trial_until > now() and new.trial_plan is not null then gb_private.tier_of(new.trial_plan) else gb_private.tier_of(new.plan) end;
  if t < 2 then new.kitchen_on := false; end if;
  return new;
end $$;
drop trigger if exists bars_tier_guard on public.bars;
create trigger bars_tier_guard before update of plan, plan_until, plan_trial_until, trial_plan, kitchen_on on public.bars for each row execute function gb_private.bars_tier_guard();

-- Options : une fonction ne s'active que si la formule la comprend
create or replace function public.gb_bar_opts(p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; k text; v jsonb; o jsonb; x jsonb;
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
      if v = 'true'::jsonb then perform gb_private.need_tier(c.bid, gb_private.opt_tier(k), 'Cette fonction'); end if;
    elsif k = 'nuit_debut' then
      if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Heure invalide (ex. 22:00).'; end if;
    elsif k = 'porte_tarifs' then
      if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) > 8 then raise exception 'Tarifs invalides (8 au maximum).'; end if;
      for x in select * from jsonb_array_elements(v) loop
        if jsonb_typeof(x->'l') <> 'string' or length(x->>'l') not between 1 and 40 or jsonb_typeof(x->'p') <> 'number' or (x->>'p')::int < 0 then raise exception 'Tarif invalide.'; end if;
      end loop;
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

-- Ajout des contrôles de formule dans les fonctions existantes (paie, compta, paiement par numéro, cuisine, prix)
do $mig$
declare f record; d text; n text;
begin
  for f in select * from (values
      ('public.gb_pay(uuid,text,integer,integer,text,text)', 'La paie'), ('public.gb_pay_cancel(uuid)', 'La paie'), ('public.gb_salary_set(uuid,integer)', 'La paie'),
      ('public.gb_accounting(text)', 'La comptabilité'), ('public.gb_expense_add(date,text,text,integer,text)', 'La comptabilité'), ('public.gb_expense_delete(uuid)', 'La comptabilité')) v(sig, lbl) loop
    d := pg_get_functiondef(f.sig::regprocedure);
    if position('need_tier' in d) = 0 then
      n := regexp_replace(d, 'perform gb_private\.need_pdg\(c\.srole\);', 'perform gb_private.need_pdg(c.srole); perform gb_private.need_tier(c.bid, 2, ''' || f.lbl || ''');');
      if n = d then raise exception 'Injection impossible dans %', f.sig; end if;
      execute n;
    end if;
  end loop;
  d := pg_get_functiondef('public.gb_admin_momo_start(uuid,uuid,text,text)'::regprocedure);
  if position('need_tier' in d) = 0 then
    n := regexp_replace(d, '(if not found then raise exception ''Session invalide\.''; end if;)', '\1 perform gb_private.need_tier(s.bar_id, 2, ''Le paiement par numéro'');');
    if n = d then raise exception 'Injection impossible dans gb_admin_momo_start'; end if;
    execute n;
  end if;
  d := pg_get_functiondef('public.gb_kitchen_toggle(boolean)'::regprocedure);
  n := regexp_replace(d, 'if coalesce\(p_on, false\) and pl in \(''simple'', ''premium''\) then raise exception ''[^'']*''; end if;',
    'if coalesce(p_on, false) then perform gb_private.need_tier(c.bid, 2, ''Le module Cuisine''); end if;');
  if n <> d then execute n; end if;
  for f in select * from (values ('public.gb_sub_request(text,integer,text,text,text)', ''), ('public.gb_admin_sub_push_start(uuid,text,integer,text,text)', '')) v(sig, lbl) loop
    d := pg_get_functiondef(f.sig::regprocedure);
    n := replace(d, 'case p_plan when ''simple'' then 10000 when ''premium'' then 15000 when ''gold'' then 20000 when ''lounge'' then 30000 end',
      'case when p_plan in (''bar'', ''resto'', ''lounge'') then gb_private.plan_price(p_plan) end');
    if n <> d then execute n; end if;
  end loop;
  d := pg_get_functiondef('public.gb_pf_overview()'::regprocedure);
  n := replace(d, 'case plan when ''simple'' then 10000 when ''premium'' then 15000 when ''gold'' then 20000 when ''lounge'' then 30000 else 0 end', 'gb_private.plan_price(plan)');
  if n <> d then execute n; end if;
  d := pg_get_functiondef('public.gb_pf_bar_set(uuid,text,date,boolean,text)'::regprocedure);
  n := replace(d, '(''beta'', ''essai'', ''simple'', ''premium'', ''gold'', ''lounge'')', '(''beta'', ''essai'', ''bar'', ''resto'', ''lounge'', ''simple'', ''premium'', ''gold'')');
  if n <> d then execute n; end if;
end $mig$;
