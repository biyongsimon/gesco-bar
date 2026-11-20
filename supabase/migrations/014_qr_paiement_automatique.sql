-- 014 : QR de paiement automatique (lien de paiement Notch Pay du bar) : le ticket passe « payé » tout seul dès que le client valide
alter table public.momo_requests alter column phone drop not null;
alter table public.momo_requests drop constraint if exists momo_requests_operator_check;
alter table public.momo_requests add constraint momo_requests_operator_check check (operator in ('orange', 'mtn', 'lien'));
alter table public.momo_requests add column if not exists pay_url text;

-- Crée (ou réutilise pendant 15 min) la demande liée au QR d'un ticket
create or replace function public.gb_admin_momo_link_start(p_user uuid, p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff; t public.tickets; k text; b public.bars; r public.momo_requests; rid uuid;
begin
  select * into s from public.staff where user_id = p_user and active; if not found then raise exception 'Session invalide.'; end if;
  select * into t from public.tickets where id = p_ticket and bar_id = s.bar_id for update; if not found then raise exception 'Ticket introuvable.'; end if;
  if t.waitress_id <> s.id then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status <> 'sent' then raise exception 'Ce ticket n''est plus à encaisser.'; end if;
  if t.cancel_requested then raise exception 'Une annulation est en attente sur ce ticket.'; end if;
  if t.total <= 0 then raise exception 'Le ticket est vide.'; end if;
  select public_key into k from gb_private.pay_keys where bar_id = s.bar_id;
  if k is null then raise exception 'Le paiement automatique n''est pas activé par le PDG.'; end if;
  select * into r from public.momo_requests where ticket_id = t.id and operator = 'lien' and status = 'en_cours' and amount = t.total and pay_url is not null and created_at > now() - interval '15 minutes' order by created_at desc limit 1;
  if found then return jsonb_build_object('id', r.id, 'url', r.pay_url, 'reuse', true); end if;
  update public.momo_requests set status = 'echoue', message = 'Remplacée', updated_at = now() where ticket_id = t.id and operator = 'lien' and status = 'en_cours';
  insert into public.momo_requests(bar_id, ticket_id, staff_id, phone, operator, amount) values (s.bar_id, t.id, s.id, null, 'lien', t.total) returning id into rid;
  select * into b from public.bars where id = s.bar_id;
  return jsonb_build_object('id', rid, 'amount', t.total, 'key', k, 'label', b.name || ' · ticket N°' || coalesce(t.number::text, ''), 'client', t.client_label);
end $$;
create or replace function public.gb_admin_momo_link_set(p_req uuid, p_ref text, p_url text) returns void language sql security definer set search_path = '' as $$
  update public.momo_requests set provider_ref = p_ref, pay_url = p_url, updated_at = now() where id = p_req $$;

create or replace function public.gb_admin_momo_get(p_user uuid, p_req uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.staff; r public.momo_requests; k text;
begin
  select * into s from public.staff where user_id = p_user and active; if not found then raise exception 'Session invalide.'; end if;
  select * into r from public.momo_requests where id = p_req and bar_id = s.bar_id; if not found then raise exception 'Demande introuvable.'; end if;
  select public_key into k from gb_private.pay_keys where bar_id = s.bar_id;
  return jsonb_build_object('status', r.status, 'ref', r.provider_ref, 'key', k, 'ticket', r.ticket_id, 'created', r.created_at, 'kind', r.operator, 'amount', r.amount);
end $$;

revoke all on function public.gb_admin_momo_link_start(uuid, uuid), public.gb_admin_momo_link_set(uuid, text, text), public.gb_admin_momo_get(uuid, uuid) from public, anon, authenticated;
grant execute on function public.gb_admin_momo_link_start(uuid, uuid), public.gb_admin_momo_link_set(uuid, text, text), public.gb_admin_momo_get(uuid, uuid) to service_role;
