create or replace function gb_private.bar_block(p_bar uuid) returns text language sql stable security definer set search_path = '' as $$
  select case
    when b.suspended then 'ACCES_BLOQUE: Ce bar est suspendu par BISMO Agency. Contactez BISMO Agency.'
    when b.plan <> 'beta' and b.plan_until is not null and b.plan_until + 3 < gb_private.biz_date()
         and coalesce(b.plan_trial_until, '-infinity') < now() then
      case when b.plan = 'essai' then 'ACCES_BLOQUE: La période d''essai gratuite est terminée. Le PDG ou le directeur doit choisir une formule (rubrique Abonnement).'
           else 'ACCES_BLOQUE: L''abonnement du bar a expiré. Le PDG ou le directeur doit le renouveler (rubrique Abonnement).' end
  end from public.bars b where b.id = p_bar $$;
