-- 027 : alertes de l'éditeur (BISMO Agency) sur son téléphone ou son ordinateur, même console fermée :
--       nouvelle erreur chez un bar, application qui ne démarre pas, site en panne (surveillance GitHub).
-- Les abonnements de l'éditeur sont séparés de ceux du personnel : un même navigateur peut recevoir les deux.
create table if not exists gb_private.admin_push (
  endpoint text primary key, user_id uuid not null, p256dh text not null, auth text not null, ua text,
  created_at timestamptz not null default now(), last_ok timestamptz);
create table if not exists gb_private.admin_alerts (id bigint generated always as identity primary key, at timestamptz not null default now(), title text);

alter table public.client_errors drop constraint if exists client_errors_source_check;
alter table public.client_errors add constraint client_errors_source_check check (source in ('app', 'console', 'surveillance'));

create or replace function public.gb_pf_push_register(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'Abonnement aux alertes invalide.'; end if;
  insert into gb_private.admin_push(endpoint, user_id, p256dh, auth, ua) values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_ua, 200))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua, created_at = now();
end $$;
create or replace function public.gb_pf_push_unregister(p_endpoint text) returns void
language plpgsql security definer set search_path = '' as $$
begin perform gb_private.need_admin(); delete from gb_private.admin_push where endpoint = p_endpoint; end $$;
create or replace function public.gb_pf_push_state(p_endpoint text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  return jsonb_build_object('ici', exists (select 1 from gb_private.admin_push where endpoint = p_endpoint), 'appareils', (select count(*) from gb_private.admin_push));
end $$;

-- Envoi (asynchrone, par la fonction serveur gesco-push) ; plafond de 12 alertes par heure
create or replace function gb_private.push_admins(p_title text, p_body text, p_url text default '/console#erreurs', p_tag text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare sec text;
begin
  if not exists (select 1 from gb_private.admin_push) then return; end if;
  if (select count(*) from gb_private.admin_alerts where at > now() - interval '1 hour') >= 12 then return; end if;
  insert into gb_private.admin_alerts(title) values (left(p_title, 120));
  delete from gb_private.admin_alerts where at < now() - interval '2 days';
  select hook_secret into sec from gb_private.push_config where id = 1;
  perform net.http_post(url := 'https://tkiuepleshsvptranoik.supabase.co/functions/v1/gesco-push',
    body := jsonb_build_object('admins', true, 'title', p_title, 'body', p_body, 'url', coalesce(p_url, '/console'), 'tag', p_tag),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook', sec), timeout_milliseconds := 8000);
exception when others then null;
end $$;
create or replace function public.gb_pf_push_test() returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  perform gb_private.push_admins('✅ Alertes GesCo activées', 'Vous serez prévenu ici dès qu’une erreur apparaît chez un bar ou que le site ne répond plus.', '/console#erreurs', 'test');
end $$;

-- Réservé à gesco-push (clé de service) : liste des appareils de l'éditeur, nettoyage des abonnements expirés
create or replace function public.gb_admin_push_admins() returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]') from gb_private.admin_push $$;
create or replace function public.gb_admin_push_admins_done(p_ok text[], p_gone text[]) returns void
language sql security definer set search_path = '' as $$
  update gb_private.admin_push set last_ok = now() where endpoint = any(p_ok);
  delete from gb_private.admin_push where endpoint = any(p_gone); $$;

revoke all on function public.gb_pf_push_register(text, text, text, text), public.gb_pf_push_unregister(text), public.gb_pf_push_state(text), public.gb_pf_push_test() from public, anon;
grant execute on function public.gb_pf_push_register(text, text, text, text), public.gb_pf_push_unregister(text), public.gb_pf_push_state(text), public.gb_pf_push_test() to authenticated;
revoke all on function public.gb_admin_push_admins(), public.gb_admin_push_admins_done(text[], text[]) from public, anon, authenticated;
grant execute on function public.gb_admin_push_admins(), public.gb_admin_push_admins_done(text[], text[]) to service_role;

-- Remontée d'erreur : une erreur NOUVELLE (ou revenue après correction) déclenche une alerte
create or replace function public.gb_log_error(p_message text, p_stack text default null, p_source text default 'app', p_url text default null,
  p_tab text default null, p_version text default null, p_ua text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff; msg text := left(trim(coalesce(p_message, '')), 500); sg text; n int; bname text; nid bigint;
  ROL constant jsonb := '{"pdg":"PDG","directeur":"Directeur","caisse":"Caisse","serveuse":"Serveuse","cuisine":"Cuisine"}';
begin
  if msg = '' or p_source not in ('app', 'console', 'surveillance') then return; end if;
  -- la surveillance n'est appelée que depuis la base (connexion directe), jamais par un navigateur
  if p_source = 'surveillance' and coalesce(auth.role(), '') in ('anon', 'authenticated') then return; end if;
  select * into s from public.staff where user_id = auth.uid() and active;
  sg := md5(p_source || '|' || regexp_replace(regexp_replace(msg, '[0-9a-f]{8}-[0-9a-f-]{27}', '#', 'gi'), '[0-9]+', '#', 'g'));
  update public.client_errors set count = count + 1, last_at = now(), stack = coalesce(left(p_stack, 2000), stack),
    version = coalesce(left(p_version, 20), version), tab = coalesce(left(p_tab, 40), tab), ua = coalesce(left(p_ua, 200), ua)
  where id = (select id from public.client_errors where sig = sg and source = p_source and resolved_at is null
    and bar_id is not distinct from s.bar_id order by last_at desc limit 1);
  if found then return; end if;
  delete from public.client_errors where last_at < now() - interval '30 days';   -- effacement après 30 jours
  select count(*) into n from public.client_errors where first_at > now() - interval '1 hour';
  if n >= 300 then return; end if;
  insert into public.client_errors(sig, source, message, stack, url, tab, role, version, ua, bar_id, staff_id)
  values (sg, p_source, msg, left(p_stack, 2000), left(p_url, 300), left(p_tab, 40), s.role, left(p_version, 20), left(p_ua, 200), s.bar_id, s.id)
  returning id into nid;
  select name into bname from public.bars where id = s.bar_id;
  perform gb_private.push_admins(
    case when p_source = 'surveillance' then '🚨 ' || left(msg, 80)
         when msg like 'DÉMARRAGE%' then '🚨 GesCo ne démarre pas' || coalesce(' chez ' || bname, '')
         when p_source = 'console' then '⚠ Erreur dans la console éditeur'
         else '⚠ Nouvelle erreur' || coalesce(' chez ' || bname, ' (écran de connexion)') end,
    case when p_source = 'surveillance' then left(msg, 200)
         else coalesce((ROL->>s.role) || coalesce(' · ' || s.name, '') || ' · ', '') || coalesce('écran ' || nullif(p_tab, '') || ' : ', '') || left(msg, 140) end,
    '/console#erreurs', 'err' || nid);
exception when others then null;
end $$;
