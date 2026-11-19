-- 010 : Assistant IA d'assistance (fils de discussion, quota, contexte du bar, console éditeur)
create table if not exists public.support_threads (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid references public.bars(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  anon_hash text, contact text,
  status text not null default 'ia' check (status in ('ia', 'transmis', 'resolu')),
  urgence text, summary text,
  created_at timestamptz not null default now(), last_msg_at timestamptz not null default now(), admin_seen_at timestamptz
);
create index if not exists support_threads_bar on public.support_threads(bar_id);
create index if not exists support_threads_staff on public.support_threads(staff_id);
create table if not exists public.support_messages (
  id bigserial primary key,
  thread_id uuid not null references public.support_threads(id) on delete cascade,
  sender text not null check (sender in ('client', 'ia', 'bismo')),
  body text not null check (length(body) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists support_messages_thread on public.support_messages(thread_id, id);
alter table public.support_threads enable row level security;
alter table public.support_messages enable row level security;
create policy st_read on public.support_threads for select to authenticated using (staff_id = (select gb_private.me()) or (select gb_private.is_platform_admin()));
create policy sm_read on public.support_messages for select to authenticated using (exists (select 1 from public.support_threads t where t.id = thread_id and (t.staff_id = (select gb_private.me()) or (select gb_private.is_platform_admin()))));
alter publication supabase_realtime add table public.support_messages;

create table if not exists gb_private.assist_usage (key text not null, day date not null default current_date, n int not null default 0, primary key (key, day));

create or replace function public.gb_admin_assist_quota(p_key text, p_max int) returns boolean language plpgsql security definer set search_path = '' as $$
declare v int;
begin
  insert into gb_private.assist_usage(key, day, n) values (p_key, current_date, 1) on conflict (key, day) do update set n = gb_private.assist_usage.n + 1 returning n into v;
  return v <= p_max;
end $$;

create or replace function public.gb_admin_assist_context(p_user uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.staff; b public.bars;
begin
  select * into s from public.staff where user_id = p_user and active; if not found then return null; end if;
  select * into b from public.bars where id = s.bar_id;
  return jsonb_build_object('staff_id', s.id, 'bar_id', b.id, 'nom', s.name, 'role', s.role, 'bar', b.name, 'code_bar', b.code, 'ville', b.city,
    'formule', b.plan, 'fin_formule', b.plan_until, 'activation_provisoire_jusqu_au', case when b.plan_trial_until > now() then b.plan_trial_until end, 'formule_provisoire', b.trial_plan,
    'suspendu', b.suspended, 'blocage', gb_private.bar_block(b.id),
    'paiement_en_verification', (select jsonb_build_object('formule', x.plan, 'mois', x.months, 'montant', x.amount, 'envoye_le', x.created_at) from public.subscriptions x where x.bar_id = b.id and x.status = 'en_attente' limit 1),
    'dernier_paiement_refuse', (select jsonb_build_object('le', x.decided_at, 'note', x.admin_note) from public.subscriptions x where x.bar_id = b.id and x.status = 'refusee' order by x.decided_at desc limit 1),
    'equipe', (select jsonb_object_agg(role, n) from (select role, count(*) n from public.staff where bar_id = b.id and active group by role) z),
    'qr_paiement_configure', b.om_code is not null or b.mtn_code is not null, 'paiement_par_numero_active', b.push_enabled,
    'journee_ouverte', exists (select 1 from public.service_days d where d.bar_id = b.id and d.status = 'open'));
end $$;

create or replace function public.gb_pf_support_list() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  return (select coalesce(jsonb_agg(row_to_json(x) order by (x.status = 'transmis') desc, x.last_msg_at desc), '[]') from (
    select t.*, b.name as bar_name, b.code as bar_code, s.name as staff_name, s.role as staff_role,
      (select count(*) from public.support_messages m where m.thread_id = t.id) as nb,
      (select left(m.body, 160) from public.support_messages m where m.thread_id = t.id and m.sender = 'client' order by m.id desc limit 1) as dernier
    from public.support_threads t left join public.bars b on b.id = t.bar_id left join public.staff s on s.id = t.staff_id
    order by t.last_msg_at desc limit 200) x);
end $$;
create or replace function public.gb_pf_support_reply(p_thread uuid, p_body text, p_close boolean) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  if nullif(trim(p_body), '') is not null then insert into public.support_messages(thread_id, sender, body) values (p_thread, 'bismo', trim(p_body)); end if;
  update public.support_threads set status = case when p_close then 'resolu' else status end, last_msg_at = now(), admin_seen_at = now() where id = p_thread;
  insert into public.platform_log(admin_id, action, bar_id, data) select auth.uid(), case when p_close then 'assistance_resolue' else 'assistance_reponse' end, bar_id, jsonb_build_object('fil', p_thread) from public.support_threads where id = p_thread;
end $$;
create or replace function public.gb_pf_support_seen(p_thread uuid) returns void language plpgsql security definer set search_path = '' as $$
begin perform gb_private.need_admin(); update public.support_threads set admin_seen_at = now() where id = p_thread; end $$;

revoke all on function public.gb_admin_assist_quota(text, int), public.gb_admin_assist_context(uuid) from public, anon, authenticated;
grant execute on function public.gb_admin_assist_quota(text, int), public.gb_admin_assist_context(uuid) to service_role;
revoke all on function public.gb_pf_support_list(), public.gb_pf_support_reply(uuid, text, boolean), public.gb_pf_support_seen(uuid) from public, anon;
grant execute on function public.gb_pf_support_list(), public.gb_pf_support_reply(uuid, text, boolean), public.gb_pf_support_seen(uuid) to authenticated;
