-- 012 : espace Avis (chaque membre de l'équipe note le logiciel et donne son point de vue ; lecture dans la console éditeur)
create table if not exists public.feedback (
  id bigserial primary key,
  bar_id uuid not null references public.bars(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  role text, rating int not null check (rating between 1 and 5),
  topics text[] not null default '{}',
  message text check (message is null or length(message) <= 2000),
  created_at timestamptz not null default now(), admin_seen_at timestamptz
);
create index if not exists feedback_bar on public.feedback(bar_id, created_at desc);
alter table public.feedback enable row level security;
create policy feedback_read on public.feedback for select to authenticated using (staff_id = (select gb_private.me()) or (select gb_private.is_platform_admin()));

-- Envoi d'un avis (possible même si le bar est bloqué : on veut aussi l'avis des bars qui ne renouvellent pas). 5 avis par personne et par jour.
create or replace function public.gb_feedback_send(p_rating int, p_topics text[], p_message text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; n int;
begin
  perform set_config('gb.allow_blocked', '1', true);
  select * into c from gb_private.ctx();
  perform set_config('gb.allow_blocked', '', true);
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choisissez une note de 1 à 5 étoiles.'; end if;
  select count(*) into n from public.feedback where staff_id = c.sid and created_at > now() - interval '1 day';
  if n >= 5 then raise exception 'Merci ! Vous avez déjà envoyé plusieurs avis aujourd''hui.'; end if;
  insert into public.feedback(bar_id, staff_id, role, rating, topics, message)
  values (c.bid, c.sid, c.srole, p_rating, coalesce((select array_agg(t) from unnest(p_topics) t where t in ('simple','rapide','fiable','utile','manque','bug','lent','prix','autre')), '{}'), nullif(left(trim(coalesce(p_message, '')), 2000), ''));
end $$;
revoke all on function public.gb_feedback_send(int, text[], text) from public, anon; grant execute on function public.gb_feedback_send(int, text[], text) to authenticated;

create or replace function public.gb_pf_feedback() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform gb_private.need_admin();
  return (select coalesce(jsonb_agg(row_to_json(x) order by x.created_at desc), '[]') from (
    select f.*, b.name as bar_name, b.code as bar_code, s.name as staff_name from public.feedback f
    left join public.bars b on b.id = f.bar_id left join public.staff s on s.id = f.staff_id order by f.created_at desc limit 500) x);
end $$;
create or replace function public.gb_pf_feedback_seen() returns void language plpgsql security definer set search_path = '' as $$
begin perform gb_private.need_admin(); update public.feedback set admin_seen_at = now() where admin_seen_at is null; end $$;
revoke all on function public.gb_pf_feedback(), public.gb_pf_feedback_seen() from public, anon;
grant execute on function public.gb_pf_feedback(), public.gb_pf_feedback_seen() to authenticated;
