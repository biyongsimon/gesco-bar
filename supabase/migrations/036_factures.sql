-- 036 : facture automatique après chaque abonnement payé ou renouvelé.
-- Le paiement validé (Notch Pay automatique ou transfert validé par BISMO Agency) crée la facture à la fin de la transaction :
-- numéro qui se suit sans trou par année (F-2026-0001), données figées (client, payeur, formule, période),
-- puis la fonction gesco-factures fabrique le PDF, le range dans le stockage privé et l'envoie au PDG par e-mail.

-- Vendeur (affiché en en-tête et pied de page des factures)
alter table public.platform_config add column if not exists seller jsonb not null default jsonb_build_object(
  'nom', 'Biyong Biyong Simon Steve', 'statut', 'Entrepreneur individuel', 'enseigne', 'BISMO AGENCY',
  'niu', 'P019718058368X', 'rccm', 'En cours d''immatriculation', 'adresse', 'Ngousso, Yaoundé, Cameroun',
  'email', 'biyongsimonsteve@gmail.com', 'telephone', '+237 691 46 81 75', 'telephone2', '+237 673 38 39 51', 'site', 'gescobar-cm.pages.dev');

create table if not exists gb_private.invoice_counters (year int primary key, last int not null default 0);

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  subscription_id uuid not null unique references public.subscriptions(id) on delete cascade,
  number text not null unique,
  issued_at timestamptz not null default now(),
  plan text not null, plan_label text not null, months int not null, amount int not null, unit_price int not null,
  period_from date, period_to date,
  client jsonb not null, payer jsonb not null, seller jsonb not null,
  is_test boolean not null default false,
  pdf_path text,
  email_to text[] not null default '{}',
  email_status text not null default 'en_attente' check (email_status in ('en_attente', 'envoi', 'envoye', 'sans_cle', 'sans_adresse', 'echec')),
  email_at timestamptz, email_error text, attempts int not null default 0, locked_at timestamptz
);
create index if not exists invoices_bar on public.invoices(bar_id, issued_at desc);
alter table public.invoices enable row level security;
drop policy if exists invoices_read on public.invoices;
create policy invoices_read on public.invoices for select to authenticated
  using (bar_id = (select gb_private.bar()) and (select gb_private.is_manager()));
revoke insert, update, delete on public.invoices from anon, authenticated;

-- Stockage privé des PDF : lecture par la direction du bar et par l'éditeur ; écriture par le serveur uniquement
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('factures', 'factures', false, 2097152, array['application/pdf']) on conflict (id) do nothing;
drop policy if exists factures_read on storage.objects;
create policy factures_read on storage.objects for select to authenticated
  using (bucket_id = 'factures' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_manager()));
drop policy if exists factures_admin_read on storage.objects;
create policy factures_admin_read on storage.objects for select to authenticated
  using (bucket_id = 'factures' and (select gb_private.is_platform_admin()));

-- Garde l'ancienne date de fin le temps de la transaction (pour la période facturée)
create or replace function gb_private.bars_keep_prev_until() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- valeur « n° de transaction|ancienne date » de la dernière modification de la date de fin dans la transaction
  if new.plan_until is distinct from old.plan_until then
    perform set_config('gb.prev_until_' || replace(new.id::text, '-', ''), txid_current()::text || '|' || coalesce(old.plan_until::text, ''), true);
  end if;
  return new;
end $$;
drop trigger if exists bars_keep_prev_until on public.bars;
create trigger bars_keep_prev_until before update of plan_until on public.bars for each row execute function gb_private.bars_keep_prev_until();

-- Appel de la fonction qui fabrique et envoie la facture
create or replace function gb_private.invoice_kick(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare sec text;
begin
  select hook_secret into sec from gb_private.push_config where id = 1;
  perform net.http_post(url := 'https://tkiuepleshsvptranoik.supabase.co/functions/v1/gesco-factures',
    body := jsonb_build_object('id', p_id), headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook', sec), timeout_milliseconds := 20000);
exception when others then null;
end $$;

-- Création de la facture quand un abonnement passe à « validée » (en fin de transaction, une fois la date de fin du bar mise à jour)
create or replace function gb_private.invoice_create() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s public.subscriptions; b public.bars; yr int; n int; num text; prev text; pf date; pt date; pdg_name text; pdg_mail text; pay_name text; pay_role text; inv uuid; mails text[]; unit int; dd date;
begin
  -- une erreur de facture ne doit jamais annuler la validation du paiement : elle est notée et la facture se refait depuis la console
  begin
  select * into s from public.subscriptions where id = new.id;
  if s.status <> 'validee' or exists (select 1 from public.invoices where subscription_id = s.id) then return null; end if;
  select * into b from public.bars where id = s.bar_id;
  prev := coalesce(current_setting('gb.prev_until_' || replace(b.id::text, '-', ''), true), '');
  prev := case when prev like txid_current()::text || '|%' then split_part(prev, '|', 2) end;
  dd := (coalesce(s.decided_at, now()) at time zone 'Africa/Douala')::date;
  pt := b.plan_until;
  pf := case when prev is not null then greatest(coalesce(nullif(prev, '')::date, dd), dd)
             when pt is not null then (pt - make_interval(months => s.months))::date end;
  if s.is_test then num := 'TEST-' || upper(left(replace(s.id::text, '-', ''), 8));
  else
    yr := extract(year from now() at time zone 'Africa/Douala')::int;
    insert into gb_private.invoice_counters(year, last) values (yr, 1) on conflict (year) do update set last = gb_private.invoice_counters.last + 1 returning last into n;
    num := format('F-%s-%s', yr, lpad(n::text, 4, '0'));
  end if;
  select st.name, u.email into pdg_name, pdg_mail from public.staff st left join auth.users u on u.id = st.user_id where st.bar_id = b.id and st.role = 'pdg' and st.active order by st.created_at limit 1;
  select st.name, st.role into pay_name, pay_role from public.staff st where st.id = s.requested_by;
  mails := array_remove(array[nullif(lower(trim(pdg_mail)), ''), nullif(lower(trim(b.opts->>'billing_email')), '')], null);
  mails := array(select distinct x from unnest(mails) x);
  unit := gb_private.plan_price(s.plan);
  insert into public.invoices(bar_id, subscription_id, number, plan, plan_label, months, amount, unit_price, period_from, period_to, client, payer, seller, is_test, email_to, email_status)
  values (b.id, s.id, num, s.plan,
    case s.plan when 'bar' then 'Snack-Bar' when 'resto' then 'Snack-Restaurant' when 'lounge' then 'Lounge' when 'simple' then 'Snack Simple' when 'premium' then 'Snack Premium' when 'gold' then 'Snack Gold' else s.plan end,
    s.months, s.amount, unit, pf, pt,
    jsonb_build_object('bar', b.name, 'code', b.code, 'ville', b.city, 'raison_sociale', b.legal_name, 'niu', b.niu, 'pdg', pdg_name, 'email', pdg_mail, 'telephone', b.opts->>'phone'),
    jsonb_build_object('nom', pay_name, 'role', pay_role, 'telephone', s.payer_phone, 'methode', s.method, 'canal', s.channel, 'reference', coalesce(nullif(s.reference, ''), s.provider_ref), 'paye_le', coalesce(s.decided_at, now())),
    (select seller from public.platform_config where id = 1), s.is_test, mails, case when cardinality(mails) = 0 then 'sans_adresse' else 'en_attente' end)
  returning id into inv;
  perform gb_private.invoice_kick(inv);
  exception when others then
    insert into public.platform_log(admin_id, action, bar_id, data) values (null, 'facture_erreur', new.bar_id, jsonb_build_object('abonnement', new.id, 'erreur', sqlerrm));
  end;
  return null;
end $$;
drop trigger if exists subscriptions_invoice on public.subscriptions;
create constraint trigger subscriptions_invoice after insert or update of status on public.subscriptions
  deferrable initially deferred for each row when (new.status = 'validee') execute function gb_private.invoice_create();

-- Réservation d'une facture par la fonction d'envoi (évite deux envois en même temps)
create or replace function public.gb_admin_invoice_claim(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare i public.invoices;
begin
  update public.invoices set locked_at = now(), attempts = attempts + 1
  where id = p_id and (locked_at is null or locked_at < now() - interval '5 minutes') and (pdf_path is null or email_status <> 'envoye')
  returning * into i;
  if not found then return null; end if;
  return to_jsonb(i);
end $$;
create or replace function public.gb_admin_invoice_done(p_id uuid, p_pdf text, p_status text, p_error text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.invoices set pdf_path = coalesce(p_pdf, pdf_path), email_status = p_status, email_error = left(p_error, 500),
    email_at = case when p_status = 'envoye' then now() else email_at end, locked_at = null where id = p_id;
end $$;
revoke all on function public.gb_admin_invoice_claim(uuid), public.gb_admin_invoice_done(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.gb_admin_invoice_claim(uuid), public.gb_admin_invoice_done(uuid, text, text, text) to service_role;

-- Reprise automatique : facture pas encore fabriquée ou e-mail non parti (réseau, clé ajoutée plus tard)
create or replace function gb_private.invoice_retry() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select id from public.invoices
    where (pdf_path is null or email_status in ('en_attente', 'echec') or (email_status = 'sans_cle' and coalesce(locked_at, issued_at) < now() - interval '1 hour'))
      and attempts < 24 and coalesce(locked_at, issued_at) < now() - interval '3 minutes' limit 10 loop
    perform gb_private.invoice_kick(r.id);
  end loop;
end $$;
do $$ begin perform cron.unschedule('gesco-factures-reprise'); exception when others then null; end $$;
select cron.schedule('gesco-factures-reprise', '*/10 * * * *', 'select gb_private.invoice_retry()');

-- Console éditeur : liste et renvoi
create or replace function public.gb_pf_invoices(p_bar uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  return coalesce((select jsonb_agg(to_jsonb(i) - 'seller' order by i.issued_at desc) from (select * from public.invoices where p_bar is null or bar_id = p_bar order by issued_at desc limit 500) i), '[]');
end $$;
create or replace function public.gb_pf_invoice_resend(p_id uuid, p_email text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare e text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  perform gb_private.need_admin();
  if e is not null and e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Adresse e-mail invalide.'; end if;
  update public.invoices set email_status = 'en_attente', email_error = null, locked_at = null, attempts = 0,
    email_to = case when e is null then email_to else array(select distinct x from unnest(email_to || e) x) end where id = p_id;
  if not found then raise exception 'Facture introuvable.'; end if;
  perform gb_private.invoice_kick(p_id);
  insert into public.platform_log(admin_id, action, bar_id, data) select auth.uid(), 'facture_renvoyee', bar_id, jsonb_build_object('numero', number, 'email', e) from public.invoices where id = p_id;
end $$;

-- E-mail de facturation facultatif (comptable du bar) dans les réglages du PDG
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.gb_bar_opts(jsonb)'::regprocedure);
  if position('billing_email' in d) = 0 then
    n := replace(d, $q$elsif k = 'phone' then$q$, $q$elsif k = 'billing_email' then
      if jsonb_typeof(v) <> 'string' or ((v #>> '{}') <> '' and (v #>> '{}') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') or length(v #>> '{}') > 120 then raise exception 'Adresse e-mail de facturation invalide.'; end if;
    elsif k = 'phone' then$q$);
    if n = d then raise exception 'Injection impossible dans gb_bar_opts'; end if;
    execute n;
  end if;
end $mig$;

-- Console : refaire une facture manquante (après une erreur notée « facture_erreur »)
create or replace function public.gb_pf_invoice_make(p_sub uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if not exists (select 1 from public.subscriptions where id = p_sub and status = 'validee') then raise exception 'Seul un paiement validé donne une facture.'; end if;
  if exists (select 1 from public.invoices where subscription_id = p_sub) then raise exception 'Ce paiement a déjà sa facture.'; end if;
  update public.subscriptions set status = status where id = p_sub;
end $$;
