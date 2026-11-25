-- 026 : remontée des erreurs de l'application (téléphones, ordinateurs, console) vers la console éditeur.
-- Une même erreur sur un même bar est regroupée (compteur), plafond anti-abus, aucune lecture directe.
create table if not exists public.client_errors (
  id bigint generated always as identity primary key,
  sig text not null,
  source text not null check (source in ('app', 'console')),
  message text not null, stack text, url text, tab text, role text, version text, ua text,
  bar_id uuid references public.bars(id) on delete set null,
  staff_id uuid references public.staff(id) on delete set null,
  count int not null default 1,
  first_at timestamptz not null default now(), last_at timestamptz not null default now(),
  resolved_at timestamptz);
create index if not exists client_errors_open on public.client_errors(last_at desc) where resolved_at is null;
create index if not exists client_errors_sig on public.client_errors(sig, source) where resolved_at is null;
alter table public.client_errors enable row level security;   -- aucune politique : accès par les fonctions seulement

create or replace function public.gb_log_error(p_message text, p_stack text default null, p_source text default 'app', p_url text default null,
  p_tab text default null, p_version text default null, p_ua text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff; msg text := left(trim(coalesce(p_message, '')), 500); sg text; n int;
begin
  if msg = '' or p_source not in ('app', 'console') then return; end if;
  select * into s from public.staff where user_id = auth.uid() and active;
  -- empreinte : chiffres et identifiants retirés, pour regrouper la même erreur
  sg := md5(p_source || '|' || regexp_replace(regexp_replace(msg, '[0-9a-f]{8}-[0-9a-f-]{27}', '#', 'gi'), '[0-9]+', '#', 'g'));
  update public.client_errors set count = count + 1, last_at = now(), stack = coalesce(left(p_stack, 2000), stack),
    version = coalesce(left(p_version, 20), version), tab = coalesce(left(p_tab, 40), tab), ua = coalesce(left(p_ua, 200), ua)
  where id = (select id from public.client_errors where sig = sg and source = p_source and resolved_at is null
    and bar_id is not distinct from s.bar_id order by last_at desc limit 1);
  if found then return; end if;
  delete from public.client_errors where last_at < now() - interval '30 days';   -- 026b : effacement après 30 jours
  select count(*) into n from public.client_errors where first_at > now() - interval '1 hour';
  if n >= 300 then return; end if;   -- plafond anti-abus
  insert into public.client_errors(sig, source, message, stack, url, tab, role, version, ua, bar_id, staff_id)
  values (sg, p_source, msg, left(p_stack, 2000), left(p_url, 300), left(p_tab, 40), s.role, left(p_version, 20), left(p_ua, 200), s.bar_id, s.id);
exception when others then null;   -- la remontée d'une erreur ne doit jamais en créer une autre
end $$;
revoke all on function public.gb_log_error(text, text, text, text, text, text, text) from public;
grant execute on function public.gb_log_error(text, text, text, text, text, text, text) to anon, authenticated;

create or replace function public.gb_pf_errors() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  return (select coalesce(jsonb_agg(row_to_json(x) order by x.resolved_at is null desc, x.last_at desc), '[]') from (
    select e.*, b.name as bar_name, b.code as bar_code, st.name as staff_name from public.client_errors e
    left join public.bars b on b.id = e.bar_id left join public.staff st on st.id = e.staff_id
    where e.resolved_at is null or e.resolved_at > now() - interval '14 days' order by e.last_at desc limit 300) x);
end $$;
create or replace function public.gb_pf_error_resolve(p_id bigint default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  update public.client_errors set resolved_at = now() where resolved_at is null and (p_id is null or id = p_id);
end $$;
revoke all on function public.gb_pf_errors(), public.gb_pf_error_resolve(bigint) from public, anon;
grant execute on function public.gb_pf_errors(), public.gb_pf_error_resolve(bigint) to authenticated;

-- 026b : les erreurs de plus de 30 jours sont effacées automatiquement (promesse de la politique de confidentialité)
-- (dans gb_log_error, avant chaque nouvelle erreur : delete from public.client_errors where last_at < now() - interval '30 days')
