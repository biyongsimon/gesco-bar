-- 036b : intitulé du document réglable (« Reçu de paiement » tant que le régime fiscal du vendeur n'est pas professionnel, puis « Facture »)
-- et numérotation séparée par intitulé et par année (R-2026-0001, F-2027-0001…).
update public.platform_config set seller = seller || '{"titre": "Reçu de paiement", "prefixe": "R"}'::jsonb where id = 1;
alter table public.platform_config alter column seller set default jsonb_build_object(
  'nom', 'Biyong Biyong Simon Steve', 'statut', 'Entrepreneur individuel', 'enseigne', 'BISMO AGENCY',
  'niu', 'P019718058368X', 'rccm', 'En cours d''immatriculation', 'adresse', 'Ngousso, Yaoundé, Cameroun',
  'email', 'biyongsimonsteve@gmail.com', 'telephone', '+237 691 46 81 75', 'telephone2', '+237 673 38 39 51', 'site', 'gescobar-cm.pages.dev',
  'titre', 'Reçu de paiement', 'prefixe', 'R');
drop table if exists gb_private.invoice_counters;
create table gb_private.invoice_counters (serie text primary key, last int not null default 0);
alter table public.invoices add column if not exists title text not null default 'Reçu de paiement';

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('gb_private.invoice_create()'::regprocedure);
  n := replace(d, $q$    yr := extract(year from now() at time zone 'Africa/Douala')::int;
    insert into gb_private.invoice_counters(year, last) values (yr, 1) on conflict (year) do update set last = gb_private.invoice_counters.last + 1 returning last into n;
    num := format('F-%s-%s', yr, lpad(n::text, 4, '0'));$q$,
  $q$    yr := extract(year from now() at time zone 'Africa/Douala')::int;
    insert into gb_private.invoice_counters(serie, last) values (coalesce((select seller->>'prefixe' from public.platform_config where id = 1), 'F') || '-' || yr, 1)
      on conflict (serie) do update set last = gb_private.invoice_counters.last + 1 returning last into n;
    num := format('%s-%s-%s', coalesce((select seller->>'prefixe' from public.platform_config where id = 1), 'F'), yr, lpad(n::text, 4, '0'));$q$);
  if n = d then raise exception 'numérotation : remplacement impossible'; end if;
  d := n;
  n := replace(d, $q$insert into public.invoices(bar_id, subscription_id, number, plan,$q$, $q$insert into public.invoices(title, bar_id, subscription_id, number, plan,$q$);
  n := replace(n, $q$  values (b.id, s.id, num, s.plan,$q$, $q$  values (coalesce((select seller->>'titre' from public.platform_config where id = 1), 'Facture'), b.id, s.id, num, s.plan,$q$);
  if n = d then raise exception 'intitulé : remplacement impossible'; end if;
  execute n;
end $mig$;
