-- 022 : vraies notifications push (application fermée) : abonnements par appareil, envoi par le serveur à chaque événement
create extension if not exists pg_net;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null, auth text not null, ua text,
  created_at timestamptz not null default now(), last_ok timestamptz);
create index if not exists push_sub_staff on public.push_subscriptions(staff_id);
alter table public.push_subscriptions enable row level security;   -- aucune lecture directe : tout passe par les fonctions

-- Clés VAPID et secret du crochet : générés côté serveur, jamais visibles par les clients
create table if not exists gb_private.push_config (id int primary key default 1 check (id = 1), vapid_public text, vapid_private text,
  hook_secret text not null default encode(extensions.gen_random_bytes(24), 'hex'));
insert into gb_private.push_config(id) values (1) on conflict do nothing;

create or replace function public.gb_push_register(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null) returns void
language plpgsql security definer set search_path to '' as $$
declare c record;
begin
  select * into c from gb_private.ctx();
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'Abonnement aux notifications invalide.'; end if;
  insert into public.push_subscriptions(bar_id, staff_id, endpoint, p256dh, auth, ua) values (c.bid, c.sid, p_endpoint, p_p256dh, p_auth, left(p_ua, 200))
  on conflict (endpoint) do update set bar_id = excluded.bar_id, staff_id = excluded.staff_id, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua, created_at = now();
end $$;
create or replace function public.gb_push_unregister(p_endpoint text) returns void
language sql security definer set search_path to '' as $$ delete from public.push_subscriptions where endpoint = p_endpoint $$;
revoke all on function public.gb_push_register(text, text, text, text), public.gb_push_unregister(text) from public, anon;
grant execute on function public.gb_push_register(text, text, text, text), public.gb_push_unregister(text) to authenticated;

-- Réservé à la fonction serveur gesco-push (clé de service)
create or replace function public.gb_admin_push_config() returns jsonb
language sql security definer set search_path to '' as $$
  select jsonb_build_object('pub', vapid_public, 'priv', vapid_private, 'hook', hook_secret) from gb_private.push_config where id = 1 $$;
create or replace function public.gb_admin_push_set_vapid(p_pub text, p_priv text) returns void
language sql security definer set search_path to '' as $$ update gb_private.push_config set vapid_public = p_pub, vapid_private = p_priv where id = 1 and vapid_public is null $$;
revoke all on function public.gb_admin_push_config(), public.gb_admin_push_set_vapid(text, text) from public, anon, authenticated;
grant execute on function public.gb_admin_push_config(), public.gb_admin_push_set_vapid(text, text) to service_role;

-- Envoi : appel asynchrone (pg_net) de la fonction serveur ; jamais à la personne qui fait l'action
create or replace function gb_private.push(p_bar uuid, p_staff uuid[], p_title text, p_body text, p_url text, p_tag text) returns void
language plpgsql security definer set search_path to '' as $$
declare ids uuid[]; sec text;
begin
  select array_agg(x) into ids from unnest(p_staff) x
    where x is not null and not exists (select 1 from public.staff s where s.id = x and s.user_id = auth.uid());
  if ids is null or not exists (select 1 from public.push_subscriptions where staff_id = any(ids)) then return; end if;
  select hook_secret into sec from gb_private.push_config where id = 1;
  perform net.http_post(url := 'https://tkiuepleshsvptranoik.supabase.co/functions/v1/gesco-push',
    body := jsonb_build_object('staff', to_jsonb(ids), 'title', p_title, 'body', p_body, 'url', coalesce(p_url, './'), 'tag', p_tag),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook', sec), timeout_milliseconds := 8000);
exception when others then null;   -- une notification ne doit jamais bloquer une vente
end $$;
create or replace function gb_private.staff_of(p_bar uuid, p_roles text[]) returns uuid[]
language sql stable security definer set search_path to '' as $$
  select coalesce(array_agg(id), '{}') from public.staff where bar_id = p_bar and active and role = any(p_roles) $$;
create or replace function gb_private.fcfa(n int) returns text language sql immutable as $$ select replace(to_char(coalesce(n, 0), 'FM999G999G999'), ',', ' ') || ' FCFA' $$;

-- Tickets : commande envoyée, annulation demandée, Mobile Money, validation, table confiée
create or replace function gb_private.push_tickets() returns trigger
language plpgsql security definer set search_path to '' as $$
declare w public.staff; who text;
begin
  select * into w from public.staff where id = new.waitress_id; who := coalesce(w.name, '');
  if w.role = 'serveuse' then
    if new.status = 'sent' and old.status = 'draft' then
      perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Nouvelle commande', who || ' · ' || coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=direct', 't' || new.id);
    end if;
    if new.cancel_requested and not coalesce(old.cancel_requested, false) then
      perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Annulation demandée', who || ' · ' || coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=direct', 'c' || new.id);
    end if;
    if new.status = 'cashed' and old.status <> 'cashed' and new.pay_method = 'momo' then
      perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Mobile Money à vérifier', who || ' · ' || coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=direct', 'm' || new.id);
    end if;
    if new.status = 'paid' and old.status <> 'paid' then
      perform gb_private.push(new.bar_id, array[new.waitress_id], case when new.pay_method = 'momo' then 'Paiement Mobile Money reçu' else 'Commande validée par la caisse' end,
        coalesce(new.client_label, '') || ' · ' || gb_private.fcfa(new.total), './?tab=service', 'p' || new.id);
    end if;
    if new.waitress_id <> old.waitress_id then
      perform gb_private.push(new.bar_id, array[new.waitress_id], 'Table confiée', coalesce(new.client_label, '') || ' · ticket N°' || coalesce(new.number::text, '') || ' est maintenant à vous.', './?tab=service', 'x' || new.id);
    end if;
  end if;
  return null;
end $$;
drop trigger if exists push_tickets on public.tickets;
create trigger push_tickets after update on public.tickets for each row execute function gb_private.push_tickets();

-- Cuisine : nouveau bon (et plat gardé disponible), plat prêt, plat annulé à décider
create or replace function gb_private.push_kitchen() returns trigger
language plpgsql security definer set search_path to '' as $$
declare p text; w text; cooks uuid[];
begin
  select name into p from public.products where id = new.product_id; select name into w from public.staff where id = new.waitress_id;
  cooks := gb_private.staff_of(new.bar_id, array['cuisine']);
  if tg_op = 'INSERT' and new.status = 'attente' then
    perform gb_private.push(new.bar_id, cooks, 'Nouvelle commande en cuisine', 'Bon ' || new.bon || ' · ' || new.qty || '× ' || p || ' · ' || coalesce(new.label, '') || ' · ' || coalesce(w, ''), './?tab=kitchen', 'k' || new.id);
    if exists (select 1 from public.kitchen_orders k where k.bar_id = new.bar_id and k.product_id = new.product_id and k.status = 'revente' and k.decided_at > now() - interval '6 hours') then
      perform gb_private.push(new.bar_id, cooks, '♻ Plat gardé disponible', new.qty || '× ' || p || ' pour ' || coalesce(new.label, 'une table') || ' : un plat identique est gardé.', './?tab=kitchen', 'g' || new.id);
    end if;
  elsif tg_op = 'UPDATE' and new.status = 'pret' and old.status <> 'pret' then
    perform gb_private.push(new.bar_id, array[new.waitress_id], 'Plat prêt en cuisine 🍽', new.qty || '× ' || p || ' · ' || coalesce(new.label, '') || ' · bon ' || new.bon || ' : allez le récupérer.', './?tab=service', 'r' || new.id);
  elsif tg_op = 'UPDATE' and new.status = 'a_decider' and old.status <> 'a_decider' then
    perform gb_private.push(new.bar_id, cooks || gb_private.staff_of(new.bar_id, array['caisse']), 'Plat annulé après préparation', new.qty || '× ' || p || ' · bon ' || new.bon || ' : revendre, repas du personnel ou perte ?', './?tab=kitchen', 'd' || new.id);
  end if;
  return null;
end $$;
drop trigger if exists push_kitchen on public.kitchen_orders;
create trigger push_kitchen after insert or update on public.kitchen_orders for each row execute function gb_private.push_kitchen();

-- Permissions demandées (directeur ou PDG), relève de caisse, journée clôturée (PDG)
create or replace function gb_private.push_leave() returns trigger
language plpgsql security definer set search_path to '' as $$
declare s public.staff;
begin
  select * into s from public.staff where id = new.staff_id;
  perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, case when s.role = 'directeur' then array['pdg'] else array['directeur', 'pdg'] end),
    'Demande de permission', s.name || ' · ' || to_char(new.day_from, 'DD/MM') || case when new.day_to <> new.day_from then ' → ' || to_char(new.day_to, 'DD/MM') else '' end || coalesce(' · ' || nullif(new.reason, ''), ''), './?tab=pres', 'l' || new.id);
  return null;
end $$;
drop trigger if exists push_leave on public.leave_requests;
create trigger push_leave after insert on public.leave_requests for each row execute function gb_private.push_leave();

create or replace function gb_private.push_handover() returns trigger
language plpgsql security definer set search_path to '' as $$
begin
  perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['caisse']), 'Relève de caisse',
    (select name from public.staff where id = new.from_staff) || ' vous passe la caisse avec ' || gb_private.fcfa(new.counted) || ' : vérifiez et confirmez.', './?tab=direct', 'h' || new.id);
  return null;
end $$;
drop trigger if exists push_handover on public.cash_handovers;
create trigger push_handover after insert on public.cash_handovers for each row execute function gb_private.push_handover();

create or replace function gb_private.push_dayclose() returns trigger
language plpgsql security definer set search_path to '' as $$
begin
  if new.status = 'closed' and old.status <> 'closed' then
    perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['pdg', 'directeur']), 'Journée clôturée',
      'Ventes ' || gb_private.fcfa((new.summary->>'ventes')::int) || ' · écart de caisse ' || gb_private.fcfa(coalesce(new.counted_cash, 0) - coalesce(new.expected_cash, 0)), './?tab=day', 'j' || new.id);
  end if;
  return null;
end $$;
drop trigger if exists push_dayclose on public.service_days;
create trigger push_dayclose after update on public.service_days for each row execute function gb_private.push_dayclose();
