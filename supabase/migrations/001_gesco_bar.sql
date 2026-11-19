-- GesCo Bar · schéma multi-bars (SaaS B2B)
-- Toutes les écritures passent par des fonctions serveur (RPC) qui contrôlent le rôle.
-- Les tables sont en lecture seule pour les clients, filtrées par établissement (RLS).

create extension if not exists pgcrypto with schema extensions;
create schema if not exists gb_private;

-- ───────────────────────── Tables ─────────────────────────
create table public.bars (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 80),
  code text not null unique,
  city text,
  owner_user uuid references auth.users(id) on delete set null,
  cash_cap integer not null default 20000 check (cash_cap >= 0),
  low_stock integer not null default 12 check (low_stock >= 0),
  next_ticket integer not null default 1,
  next_voucher integer not null default 1,
  plan text not null default 'beta',
  created_at timestamptz not null default now()
);

create table public.staff (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  user_id uuid unique references auth.users(id) on delete set null,
  name text not null check (length(trim(name)) between 1 and 40),
  role text not null check (role in ('caisse','serveuse')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (bar_id, name)
);

-- PIN séparé : aucune politique RLS, jamais lisible par l'application.
create table gb_private.staff_pins (
  staff_id uuid primary key references public.staff(id) on delete cascade,
  pin_hash text not null,
  failed_attempts int not null default 0,
  locked_until timestamptz
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 60),
  category text not null default 'Bières',
  price integer not null check (price >= 0),
  stock integer not null default 0,
  active boolean not null default true,
  sort integer not null default 0,
  created_at timestamptz not null default now(),
  unique (bar_id, name)
);

create table public.service_days (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  business_date date not null,
  status text not null default 'open' check (status in ('open','closed')),
  opened_at timestamptz not null default now(),
  opened_by uuid references public.staff(id),
  closed_at timestamptz,
  closed_by uuid references public.staff(id),
  counted_cash integer,
  expected_cash integer,
  summary jsonb
);
create unique index service_days_one_open on public.service_days(bar_id) where status = 'open';
create index service_days_bar_date on public.service_days(bar_id, business_date);

create table public.tickets (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  day_id uuid not null references public.service_days(id),
  number integer not null,
  waitress_id uuid not null references public.staff(id),
  client_label text not null,
  status text not null default 'draft' check (status in ('draft','sent','cashed','paid','cancelled')),
  pay_method text check (pay_method in ('cash','momo')),
  total integer not null default 0,
  received integer,
  change_due integer not null default 0,
  change_status text not null default 'none' check (change_status in ('none','pending','given','voucher')),
  corrections integer not null default 0,
  cancel_requested boolean not null default false,
  voucher_id uuid,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  cashed_at timestamptz,
  paid_at timestamptz,
  updated_at timestamptz not null default now()
);
create index tickets_bar_day on public.tickets(bar_id, day_id);
create index tickets_waitress_status on public.tickets(waitress_id, status);
create index tickets_bar_status on public.tickets(bar_id, status);

create table public.ticket_items (
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  product_id uuid not null references public.products(id),
  bar_id uuid not null references public.bars(id) on delete cascade,
  qty integer not null check (qty > 0),
  unit_price integer not null,
  primary key (ticket_id, product_id)
);
create index ticket_items_bar on public.ticket_items(bar_id);
create index ticket_items_product on public.ticket_items(product_id);

-- Bouteilles en main de chaque serveuse (négatif = à prendre à la caisse)
create table public.holdings (
  bar_id uuid not null references public.bars(id) on delete cascade,
  waitress_id uuid not null references public.staff(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  qty integer not null default 0,
  primary key (waitress_id, product_id)
);
create index holdings_bar on public.holdings(bar_id);
create index holdings_product on public.holdings(product_id);

create table public.remittances (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  day_id uuid not null references public.service_days(id),
  waitress_id uuid not null references public.staff(id),
  expected integer not null,
  received integer not null,
  diff integer generated always as (received - expected) stored,
  ticket_count integer not null,
  created_by uuid references public.staff(id),
  created_at timestamptz not null default now()
);
create index remittances_bar_day on public.remittances(bar_id, day_id);
create index remittances_waitress on public.remittances(waitress_id);
create index remittances_creator on public.remittances(created_by);
create index remittances_day on public.remittances(day_id);

create table public.vouchers (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  number text not null,
  code text not null unique,
  amount integer not null check (amount > 0),
  client_label text not null,
  waitress_id uuid references public.staff(id),
  ticket_id uuid references public.tickets(id),
  status text not null default 'active' check (status in ('active','used','void')),
  issued_by uuid references public.staff(id),
  issued_at timestamptz not null default now(),
  used_by uuid references public.staff(id),
  used_at timestamptz,
  unique (bar_id, number)
);
create index vouchers_bar_status on public.vouchers(bar_id, status);
create index vouchers_waitress on public.vouchers(waitress_id);
create index vouchers_ticket on public.vouchers(ticket_id);
create index vouchers_issued_by on public.vouchers(issued_by);
create index vouchers_used_by on public.vouchers(used_by);

create table public.stock_moves (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  waitress_id uuid references public.staff(id),
  qty integer not null,
  kind text not null check (kind in ('appro','dotation','reprise','ajustement')),
  created_by uuid references public.staff(id),
  created_at timestamptz not null default now()
);
create index stock_moves_bar on public.stock_moves(bar_id, created_at desc);
create index stock_moves_product on public.stock_moves(product_id);
create index stock_moves_waitress on public.stock_moves(waitress_id);
create index stock_moves_creator on public.stock_moves(created_by);

create table public.audit_log (
  id bigint generated always as identity primary key,
  bar_id uuid not null references public.bars(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_log_bar on public.audit_log(bar_id, created_at desc);
create index audit_log_staff on public.audit_log(staff_id);

create index tickets_day on public.tickets(day_id);
create index service_days_opened_by on public.service_days(opened_by);
create index service_days_closed_by on public.service_days(closed_by);
create index bars_owner on public.bars(owner_user);

-- ───────────────────────── Fonctions internes ─────────────────────────
create or replace function gb_private.bar() returns uuid
language sql stable security definer set search_path = '' as $$
  select s.bar_id from public.staff s where s.user_id = (select auth.uid()) and s.active
$$;

create or replace function gb_private.me() returns uuid
language sql stable security definer set search_path = '' as $$
  select s.id from public.staff s where s.user_id = (select auth.uid()) and s.active
$$;

create or replace function gb_private.is_caisse() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.role = 'caisse' from public.staff s where s.user_id = (select auth.uid()) and s.active), false)
$$;

create or replace function gb_private.ctx(out sid uuid, out bid uuid, out srole text, out sname text)
language plpgsql stable security definer set search_path = '' as $$
begin
  select s.id, s.bar_id, s.role, s.name into sid, bid, srole, sname
  from public.staff s where s.user_id = auth.uid() and s.active;
  if sid is null then
    raise exception 'Session invalide ou compte désactivé. Reconnectez-vous.' using errcode = '42501';
  end if;
end $$;

create or replace function gb_private.need_caisse(r text) returns void
language plpgsql set search_path = '' as $$
begin
  if r is distinct from 'caisse' then
    raise exception 'Action réservée à la caisse.' using errcode = '42501';
  end if;
end $$;

create or replace function gb_private.log(p_bar uuid, p_staff uuid, p_action text, p_details jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log(bar_id, staff_id, action, details) values (p_bar, p_staff, p_action, coalesce(p_details, '{}'::jsonb));
$$;

-- Date de service : un bar qui ferme à 3 h compte sur la journée de la veille (bascule à 6 h, heure de Douala)
create or replace function gb_private.biz_date() returns date
language sql stable set search_path = '' as $$
  select ((now() at time zone 'Africa/Douala') - interval '6 hours')::date
$$;

create or replace function gb_private.current_day(p_bar uuid, p_staff uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare d uuid;
begin
  select id into d from public.service_days where bar_id = p_bar and status = 'open';
  if d is null then
    begin
      insert into public.service_days(bar_id, business_date, opened_by)
      values (p_bar, gb_private.biz_date(), p_staff) returning id into d;
    exception when unique_violation then
      select id into d from public.service_days where bar_id = p_bar and status = 'open';
    end;
  end if;
  return d;
end $$;

create or replace function gb_private.rand_code(n int) returns text
language plpgsql volatile set search_path = '' as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(n); r text := ''; i int;
begin
  for i in 0..n-1 loop r := r || substr(a, (get_byte(b, i) % 32) + 1, 1); end loop;
  return r;
end $$;

create or replace function gb_private.check_pin_format(p text) returns void
language plpgsql set search_path = '' as $$
begin
  if p is null or p !~ '^[0-9]{4,6}$' then
    raise exception 'Le PIN doit contenir 4 à 6 chiffres.';
  end if;
end $$;

-- Rend les bouteilles d'un ticket à la serveuse et l'annule
create or replace function gb_private.cancel_ticket(p_ticket uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tickets;
begin
  select * into t from public.tickets where id = p_ticket for update;
  insert into public.holdings(bar_id, waitress_id, product_id, qty)
    select t.bar_id, t.waitress_id, i.product_id, i.qty from public.ticket_items i where i.ticket_id = p_ticket
  on conflict (waitress_id, product_id) do update set qty = public.holdings.qty + excluded.qty;
  update public.vouchers set status = 'void' where ticket_id = p_ticket and status = 'active';
  update public.tickets set status = 'cancelled', cancel_requested = false, updated_at = now() where id = p_ticket;
  perform gb_private.log(t.bar_id, p_staff, 'ticket_supprime',
    jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total, 'statut_avant', t.status));
end $$;

-- ───────────────────────── RPC : tickets (serveuse et caisse) ─────────────────────────
create or replace function public.gb_ticket_create(p_id uuid, p_client text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c record; n int; d uuid; ex public.tickets;
begin
  select * into c from gb_private.ctx();
  p_client := nullif(trim(p_client), '');
  if p_client is null then raise exception 'Indiquez le nom du client ou un repère de table.'; end if;
  p_id := coalesce(p_id, gen_random_uuid());
  select * into ex from public.tickets where id = p_id;
  if found then
    if ex.waitress_id <> c.sid then raise exception 'Conflit de ticket.'; end if;
    return p_id; -- rejouer hors ligne sans doublon
  end if;
  d := gb_private.current_day(c.bid, c.sid);
  update public.bars set next_ticket = next_ticket + 1 where id = c.bid returning next_ticket - 1 into n;
  insert into public.tickets(id, bar_id, day_id, number, waitress_id, client_label)
  values (p_id, c.bid, d, n, c.sid, left(p_client, 40));
  return p_id;
end $$;

create or replace function public.gb_ticket_set_qty(p_ticket uuid, p_product uuid, p_qty int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; p public.products; cur int; d int;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if c.srole <> 'caisse' and t.waitress_id <> c.sid then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status not in ('draft','sent') then raise exception 'Ticket déjà encaissé : il est verrouillé.'; end if;
  p_qty := greatest(0, coalesce(p_qty, 0));
  if p_qty > 200 then raise exception 'Quantité trop élevée.'; end if;
  select * into p from public.products where id = p_product and bar_id = c.bid;
  if not found then raise exception 'Produit introuvable.'; end if;
  select qty into cur from public.ticket_items where ticket_id = p_ticket and product_id = p_product;
  cur := coalesce(cur, 0); d := p_qty - cur;
  if d = 0 then return; end if;
  if cur = 0 and not p.active then raise exception 'Ce produit n''est plus disponible.'; end if;
  if p_qty = 0 then
    delete from public.ticket_items where ticket_id = p_ticket and product_id = p_product;
  elsif cur = 0 then
    insert into public.ticket_items(ticket_id, product_id, bar_id, qty, unit_price) values (p_ticket, p_product, c.bid, p_qty, p.price);
  else
    update public.ticket_items set qty = p_qty where ticket_id = p_ticket and product_id = p_product;
  end if;
  insert into public.holdings(bar_id, waitress_id, product_id, qty) values (c.bid, t.waitress_id, p_product, -d)
  on conflict (waitress_id, product_id) do update set qty = public.holdings.qty - d;
  update public.tickets set
    total = (select coalesce(sum(qty * unit_price), 0) from public.ticket_items where ticket_id = p_ticket),
    corrections = corrections + case when t.status = 'sent' and d < 0 then 1 else 0 end,
    updated_at = now()
  where id = p_ticket;
  if t.status = 'sent' then
    perform gb_private.log(c.bid, c.sid, 'ticket_modifie',
      jsonb_build_object('ticket', t.number, 'client', t.client_label, 'produit', p.name, 'variation', d));
  end if;
end $$;

create or replace function public.gb_ticket_send(p_ticket uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if c.srole <> 'caisse' and t.waitress_id <> c.sid then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status <> 'draft' then return; end if;
  if t.total <= 0 then raise exception 'Ajoutez au moins une boisson avant d''envoyer.'; end if;
  update public.tickets set status = 'sent', sent_at = now(), updated_at = now() where id = p_ticket;
end $$;

create or replace function public.gb_ticket_cash(p_ticket uuid, p_method text, p_received int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; r int;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if c.srole <> 'caisse' and t.waitress_id <> c.sid then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status in ('cashed','paid') then return; end if;
  if t.status <> 'sent' then raise exception 'Envoyez d''abord la commande à la caisse.'; end if;
  if t.cancel_requested then raise exception 'Une annulation est en attente sur ce ticket.'; end if;
  if p_method not in ('cash','momo') then raise exception 'Mode de paiement inconnu.'; end if;
  if p_method = 'cash' then
    r := coalesce(p_received, t.total);
    if r < t.total then raise exception 'Le montant reçu (% FCFA) est inférieur au total (% FCFA).', r, t.total; end if;
    if r > t.total + 100000 then raise exception 'Montant reçu invraisemblable.'; end if;
  else
    r := t.total;
  end if;
  update public.tickets set status = 'cashed', pay_method = p_method, received = r,
    change_due = r - t.total, change_status = case when r > t.total then 'pending' else 'none' end,
    cashed_at = now(), updated_at = now()
  where id = p_ticket;
end $$;

-- Serveuse : brouillon supprimé directement, commande envoyée = demande à la caisse. Caisse : suppression directe.
create or replace function public.gb_ticket_delete(p_ticket uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.status = 'cancelled' then return 'cancelled'; end if;
  if c.srole = 'caisse' then
    perform gb_private.cancel_ticket(p_ticket, c.sid); return 'cancelled';
  end if;
  if t.waitress_id <> c.sid then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status = 'draft' then
    perform gb_private.cancel_ticket(p_ticket, c.sid); return 'cancelled';
  elsif t.status = 'sent' then
    update public.tickets set cancel_requested = true, updated_at = now() where id = p_ticket;
    perform gb_private.log(c.bid, c.sid, 'annulation_demandee', jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total));
    return 'requested';
  else
    raise exception 'Ticket déjà encaissé : seule la caisse peut le supprimer.';
  end if;
end $$;

create or replace function public.gb_ticket_reject_cancel(p_ticket uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  update public.tickets set cancel_requested = false, updated_at = now() where id = p_ticket and bar_id = c.bid returning * into t;
  if t.id is not null then
    perform gb_private.log(c.bid, c.sid, 'annulation_refusee', jsonb_build_object('ticket', t.number, 'client', t.client_label));
  end if;
end $$;

create or replace function public.gb_ticket_reopen(p_ticket uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.status not in ('cashed','paid') then raise exception 'Seul un ticket encaissé peut être rouvert.'; end if;
  update public.vouchers set status = 'void' where ticket_id = p_ticket and status = 'active';
  update public.tickets set status = 'sent', pay_method = null, received = null, change_due = 0, change_status = 'none',
    voucher_id = null, cashed_at = null, paid_at = null, updated_at = now() where id = p_ticket;
  perform gb_private.log(c.bid, c.sid, 'ticket_rouvert', jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total, 'statut_avant', t.status));
end $$;

-- ───────────────────────── RPC : caisse ─────────────────────────
create or replace function public.gb_remit(p_waitress uuid, p_received int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; exp int; n int; d uuid; w text;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if p_received is null or p_received < 0 then raise exception 'Saisissez le montant reçu.'; end if;
  select name into w from public.staff where id = p_waitress and bar_id = c.bid;
  if w is null then raise exception 'Serveuse introuvable.'; end if;
  select coalesce(sum(coalesce(received, total)), 0), count(*) into exp, n
  from public.tickets where bar_id = c.bid and waitress_id = p_waitress and status = 'cashed' and pay_method = 'cash';
  if n = 0 then raise exception 'Aucune espèce à recevoir de %.', w; end if;
  update public.tickets set status = 'paid', paid_at = now(), updated_at = now()
  where bar_id = c.bid and waitress_id = p_waitress and status = 'cashed' and pay_method = 'cash';
  d := gb_private.current_day(c.bid, c.sid);
  insert into public.remittances(bar_id, day_id, waitress_id, expected, received, ticket_count, created_by)
  values (c.bid, d, p_waitress, exp, p_received, n, c.sid);
  perform gb_private.log(c.bid, c.sid, 'versement', jsonb_build_object('serveuse', w, 'attendu', exp, 'recu', p_received, 'ecart', p_received - exp, 'tickets', n));
  return jsonb_build_object('expected', exp, 'received', p_received, 'diff', p_received - exp, 'tickets', n);
end $$;

create or replace function public.gb_momo_confirm(p_ticket uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  update public.tickets set status = 'paid', paid_at = now(), updated_at = now()
  where id = p_ticket and bar_id = c.bid and status = 'cashed' and pay_method = 'momo' returning * into t;
  if t.id is null then raise exception 'Aucun paiement Mobile Money en attente sur ce ticket.'; end if;
  perform gb_private.log(c.bid, c.sid, 'momo_confirme', jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total));
end $$;

create or replace function public.gb_change_given(p_ticket uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  update public.tickets set change_status = 'given', updated_at = now()
  where id = p_ticket and bar_id = c.bid and change_status = 'pending' and status = 'paid' returning * into t;
  if t.id is null then raise exception 'Validez d''abord le versement de la serveuse.'; end if;
  perform gb_private.log(c.bid, c.sid, 'monnaie_remise', jsonb_build_object('ticket', t.number, 'client', t.client_label, 'montant', t.change_due));
end $$;

create or replace function public.gb_voucher_issue(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; v public.vouchers; n int; k text;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.status <> 'paid' or t.change_status <> 'pending' then raise exception 'Validez d''abord le versement de la serveuse.'; end if;
  update public.bars set next_voucher = next_voucher + 1 where id = c.bid returning next_voucher - 1 into n;
  loop
    k := gb_private.rand_code(4) || '-' || gb_private.rand_code(4);
    exit when not exists (select 1 from public.vouchers where code = k);
  end loop;
  insert into public.vouchers(bar_id, number, code, amount, client_label, waitress_id, ticket_id, issued_by)
  values (c.bid, 'B-' || lpad(n::text, 4, '0'), k, t.change_due, t.client_label, t.waitress_id, t.id, c.sid) returning * into v;
  update public.tickets set change_status = 'voucher', voucher_id = v.id, updated_at = now() where id = p_ticket;
  perform gb_private.log(c.bid, c.sid, 'bon_emis', jsonb_build_object('bon', v.number, 'montant', v.amount, 'client', v.client_label));
  return to_jsonb(v);
end $$;

create or replace function public.gb_voucher_check(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; v jsonb;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select to_jsonb(x) || jsonb_build_object('waitress_name', s.name) into v
  from public.vouchers x left join public.staff s on s.id = x.waitress_id
  where x.bar_id = c.bid and x.code = upper(trim(p_code));
  perform gb_private.log(c.bid, c.sid, 'bon_verifie', jsonb_build_object('code', upper(trim(p_code)), 'trouve', v is not null));
  return v;
end $$;

create or replace function public.gb_voucher_use(p_voucher uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; v public.vouchers;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  update public.vouchers set status = 'used', used_at = now(), used_by = c.sid
  where id = p_voucher and bar_id = c.bid and status = 'active' returning * into v;
  if v.id is null then raise exception 'Ce bon n''est plus valable.'; end if;
  perform gb_private.log(c.bid, c.sid, 'bon_utilise', jsonb_build_object('bon', v.number, 'montant', v.amount));
end $$;

-- Dotation (+) ou reprise (−) de bouteilles entre stock général et serveuse
create or replace function public.gb_dotation(p_waitress uuid, p_product uuid, p_qty int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; p public.products; h int; w text;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if coalesce(p_qty, 0) = 0 then raise exception 'Indiquez une quantité.'; end if;
  select name into w from public.staff where id = p_waitress and bar_id = c.bid and active;
  if w is null then raise exception 'Serveuse introuvable.'; end if;
  select * into p from public.products where id = p_product and bar_id = c.bid for update;
  if not found then raise exception 'Produit introuvable.'; end if;
  select qty into h from public.holdings where waitress_id = p_waitress and product_id = p_product;
  h := coalesce(h, 0);
  if p_qty > 0 and p.stock < p_qty then raise exception 'Stock insuffisant : il reste % × %.', p.stock, p.name; end if;
  if p_qty < 0 and h < -p_qty then raise exception '% n''a que % × % en main.', w, greatest(h, 0), p.name; end if;
  update public.products set stock = stock - p_qty where id = p_product;
  insert into public.holdings(bar_id, waitress_id, product_id, qty) values (c.bid, p_waitress, p_product, p_qty)
  on conflict (waitress_id, product_id) do update set qty = public.holdings.qty + p_qty;
  insert into public.stock_moves(bar_id, product_id, waitress_id, qty, kind, created_by)
  values (c.bid, p_product, p_waitress, p_qty, case when p_qty > 0 then 'dotation' else 'reprise' end, c.sid);
end $$;

create or replace function public.gb_fill_missing(p_waitress uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare c record; r record; n int; total int := 0;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  for r in select h.product_id, h.qty, p.stock from public.holdings h join public.products p on p.id = h.product_id
           where h.waitress_id = p_waitress and h.bar_id = c.bid and h.qty < 0 loop
    n := least(-r.qty, r.stock);
    if n > 0 then perform public.gb_dotation(p_waitress, r.product_id, n); total := total + n; end if;
  end loop;
  return total;
end $$;

create or replace function public.gb_appro(p_product uuid, p_qty int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; p public.products;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if coalesce(p_qty, 0) <= 0 then raise exception 'La quantité doit être positive.'; end if;
  update public.products set stock = stock + p_qty where id = p_product and bar_id = c.bid returning * into p;
  if p.id is null then raise exception 'Produit introuvable.'; end if;
  insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (c.bid, p_product, p_qty, 'appro', c.sid);
  perform gb_private.log(c.bid, c.sid, 'approvisionnement', jsonb_build_object('produit', p.name, 'quantite', p_qty));
end $$;

create or replace function public.gb_product_save(p_id uuid, p_name text, p_category text, p_price int, p_stock int, p_active boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare c record; p public.products; nid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  p_name := nullif(trim(p_name), '');
  if p_name is null then raise exception 'Donnez un nom au produit.'; end if;
  if coalesce(p_price, -1) < 0 then raise exception 'Indiquez un prix valide.'; end if;
  if p_id is null then
    insert into public.products(bar_id, name, category, price, stock, active, sort)
    values (c.bid, p_name, coalesce(nullif(trim(p_category), ''), 'Bières'), p_price, greatest(coalesce(p_stock, 0), 0), coalesce(p_active, true),
            (select coalesce(max(sort), 0) + 1 from public.products where bar_id = c.bid))
    returning id into nid;
    if coalesce(p_stock, 0) > 0 then
      insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (c.bid, nid, p_stock, 'appro', c.sid);
    end if;
    perform gb_private.log(c.bid, c.sid, 'produit_ajoute', jsonb_build_object('produit', p_name, 'prix', p_price));
    return nid;
  end if;
  select * into p from public.products where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Produit introuvable.'; end if;
  update public.products set name = p_name, category = coalesce(nullif(trim(p_category), ''), category), price = p_price,
    stock = coalesce(p_stock, stock), active = coalesce(p_active, active) where id = p_id;
  if p_stock is not null and p_stock <> p.stock then
    insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (c.bid, p_id, p_stock - p.stock, 'ajustement', c.sid);
  end if;
  perform gb_private.log(c.bid, c.sid, 'produit_modifie', jsonb_build_object('produit', p_name, 'prix_avant', p.price, 'prix', p_price, 'stock_avant', p.stock, 'stock', coalesce(p_stock, p.stock)));
  return p_id;
exception when unique_violation then
  raise exception 'Un produit porte déjà ce nom.';
end $$;

create or replace function public.gb_staff_update(p_staff uuid, p_name text, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; s public.staff; busy int;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into s from public.staff where id = p_staff and bar_id = c.bid for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  if p_staff = c.sid and (coalesce(p_active, true) = false or coalesce(p_role, s.role) <> 'caisse') then
    raise exception 'Vous ne pouvez pas retirer votre propre accès caisse.';
  end if;
  if coalesce(p_active, true) = false and s.active then
    select count(*) into busy from public.tickets where waitress_id = p_staff and status in ('draft','sent','cashed');
    if busy > 0 then raise exception '% a encore % ticket(s) non soldé(s).', s.name, busy; end if;
    if exists (select 1 from public.holdings where waitress_id = p_staff and qty <> 0) then
      raise exception 'Reprenez d''abord les bouteilles en main de %.', s.name;
    end if;
  end if;
  update public.staff set name = coalesce(nullif(trim(p_name), ''), name), role = coalesce(p_role, role), active = coalesce(p_active, active)
  where id = p_staff;
  perform gb_private.log(c.bid, c.sid, 'equipe_modifiee', jsonb_build_object('membre', s.name, 'nom', coalesce(nullif(trim(p_name), ''), s.name), 'role', coalesce(p_role, s.role), 'actif', coalesce(p_active, s.active)));
exception when unique_violation then
  raise exception 'Ce nom est déjà utilisé dans l''équipe.';
end $$;

create or replace function public.gb_staff_set_pin(p_staff uuid, p_pin text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; n text;
begin
  select * into c from gb_private.ctx();
  if p_staff <> c.sid then perform gb_private.need_caisse(c.srole); end if;
  perform gb_private.check_pin_format(p_pin);
  select name into n from public.staff where id = p_staff and bar_id = c.bid;
  if n is null then raise exception 'Membre introuvable.'; end if;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (p_staff, extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null;
  perform gb_private.log(c.bid, c.sid, 'pin_change', jsonb_build_object('membre', n));
end $$;

create or replace function public.gb_bar_update(p_name text, p_city text, p_cash_cap int, p_low_stock int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  update public.bars set name = coalesce(nullif(trim(p_name), ''), name), city = coalesce(trim(p_city), city),
    cash_cap = coalesce(p_cash_cap, cash_cap), low_stock = coalesce(p_low_stock, low_stock) where id = c.bid;
  perform gb_private.log(c.bid, c.sid, 'reglages_modifies', jsonb_build_object('nom', p_name, 'plafond_especes', p_cash_cap, 'seuil_stock', p_low_stock));
end $$;

create or replace function public.gb_day_close(p_counted int, p_force boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; d public.service_days; pending int; s jsonb; exp int; sales int; cash_in int; change_out int; momo int; vouch int;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if p_counted is null or p_counted < 0 then raise exception 'Saisissez les espèces comptées dans la caisse.'; end if;
  select * into d from public.service_days where bar_id = c.bid and status = 'open' for update;
  if not found then raise exception 'Aucune journée de service ouverte.'; end if;
  select count(*) into pending from public.tickets where day_id = d.id and status in ('draft','sent','cashed');
  if pending > 0 and not coalesce(p_force, false) then
    raise exception 'Il reste % ticket(s) non soldé(s). Soldez-les ou forcez la clôture.', pending using errcode = 'P0002';
  end if;
  select coalesce(sum(total) filter (where status in ('cashed','paid')), 0),
         coalesce(sum(total) filter (where status = 'paid' and pay_method = 'momo'), 0),
         coalesce(sum(change_due) filter (where change_status = 'given'), 0),
         coalesce(sum(change_due) filter (where change_status = 'voucher'), 0)
    into sales, momo, change_out, vouch
  from public.tickets where day_id = d.id;
  select coalesce(sum(received), 0) into cash_in from public.remittances where day_id = d.id;
  exp := cash_in - change_out;
  select jsonb_build_object(
    'ventes', sales, 'especes_versees', cash_in, 'monnaie_rendue', change_out, 'mobile_money', momo, 'bons_emis', vouch,
    'tickets', (select count(*) from public.tickets where day_id = d.id and status in ('cashed','paid')),
    'annules', (select count(*) from public.tickets where day_id = d.id and status = 'cancelled'),
    'non_soldes', pending,
    'serveuses', coalesce((select jsonb_agg(jsonb_build_object(
        'nom', st.name,
        'ventes', coalesce((select sum(total) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id and t.status in ('cashed','paid')), 0),
        'tickets', (select count(*) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id and t.status in ('cashed','paid')),
        'corrections', coalesce((select sum(corrections) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id), 0),
        'annules', (select count(*) from public.tickets t where t.day_id = d.id and t.waitress_id = st.id and t.status = 'cancelled'),
        'ecart_versements', coalesce((select sum(diff) from public.remittances r where r.day_id = d.id and r.waitress_id = st.id), 0),
        'bouteilles_en_main', coalesce((select sum(greatest(qty, 0)) from public.holdings h where h.waitress_id = st.id), 0)
      ) order by st.name) from public.staff st where st.bar_id = c.bid and st.role = 'serveuse'), '[]'::jsonb)
  ) into s;
  update public.service_days set status = 'closed', closed_at = now(), closed_by = c.sid, counted_cash = p_counted,
    expected_cash = exp, summary = s where id = d.id;
  perform gb_private.log(c.bid, c.sid, 'journee_cloturee', jsonb_build_object('date', d.business_date, 'ventes', sales, 'attendu', exp, 'compte', p_counted, 'ecart', p_counted - exp));
  return s || jsonb_build_object('attendu', exp, 'compte', p_counted, 'ecart', p_counted - exp, 'date', d.business_date);
end $$;

create or replace function public.gb_revenue() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; m date := date_trunc('month', gb_private.biz_date())::date;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  return jsonb_build_object(
    'months', coalesce((select jsonb_agg(x order by x.month desc) from (
        select to_char(date_trunc('month', d.business_date), 'YYYY-MM') as month,
               sum(t.total) filter (where t.status in ('cashed','paid')) as total,
               sum(t.total) filter (where t.status = 'paid') as paid,
               count(*) filter (where t.status in ('cashed','paid')) as tickets
        from public.tickets t join public.service_days d on d.id = t.day_id
        where t.bar_id = c.bid and d.business_date >= (m - interval '11 months')
        group by 1) x), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(y order by y.day desc) from (
        select d.business_date as day, sum(t.total) filter (where t.status in ('cashed','paid')) as total,
               count(*) filter (where t.status in ('cashed','paid')) as tickets
        from public.tickets t join public.service_days d on d.id = t.day_id
        where t.bar_id = c.bid and d.business_date >= m group by 1) y), '[]'::jsonb),
    'waitresses', coalesce((select jsonb_agg(z order by z.total desc) from (
        select s.name, coalesce(sum(t.total) filter (where t.status in ('cashed','paid')), 0) as total,
               count(*) filter (where t.status in ('cashed','paid')) as tickets
        from public.tickets t join public.service_days d on d.id = t.day_id join public.staff s on s.id = t.waitress_id
        where t.bar_id = c.bid and d.business_date >= m group by s.name) z), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(w order by w.qty desc) from (
        select p.name, sum(i.qty) as qty, sum(i.qty * i.unit_price) as total
        from public.ticket_items i join public.tickets t on t.id = i.ticket_id join public.service_days d on d.id = t.day_id
        join public.products p on p.id = i.product_id
        where t.bar_id = c.bid and d.business_date >= m and t.status in ('cashed','paid') group by p.name) w), '[]'::jsonb)
  );
end $$;

-- ───────────────────────── RPC : administration (fonction serveur uniquement) ─────────────────────────
create or replace function gb_private.seed_products(p_bar uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.products(bar_id, name, category, price, sort) values
    (p_bar, 'Castel Beer 65cl', 'Bières', 650, 1),
    (p_bar, '33 Export 65cl', 'Bières', 650, 2),
    (p_bar, 'Mützig 65cl', 'Bières', 650, 3),
    (p_bar, 'Beaufort 65cl', 'Bières', 650, 4),
    (p_bar, 'Guinness 65cl', 'Bières', 1000, 5),
    (p_bar, 'Orijin', 'Bières', 650, 6),
    (p_bar, 'Coca-Cola', 'Sucreries', 500, 7),
    (p_bar, 'Top Pamplemousse', 'Sucreries', 500, 8),
    (p_bar, 'Eau minérale 1,5 L', 'Eaux', 600, 9);
$$;

create or replace function public.gb_admin_create_bar(p_user uuid, p_bar_name text, p_city text, p_owner_name text, p_pin text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b uuid; s uuid; k text;
begin
  perform gb_private.check_pin_format(p_pin);
  if nullif(trim(p_bar_name), '') is null then raise exception 'Indiquez le nom du bar.'; end if;
  if nullif(trim(p_owner_name), '') is null then raise exception 'Indiquez votre nom.'; end if;
  loop
    k := gb_private.rand_code(6);
    exit when not exists (select 1 from public.bars where code = k);
  end loop;
  insert into public.bars(name, code, city, owner_user) values (trim(p_bar_name), k, nullif(trim(p_city), ''), p_user) returning id into b;
  insert into public.staff(bar_id, user_id, name, role) values (b, p_user, trim(p_owner_name), 'caisse') returning id into s;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (s, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  perform gb_private.seed_products(b);
  perform gb_private.log(b, s, 'bar_cree', jsonb_build_object('nom', trim(p_bar_name)));
  return jsonb_build_object('bar_id', b, 'code', k, 'staff_id', s);
end $$;

create or replace function public.gb_admin_staff_list(p_code text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('bar', b.name, 'staff', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', s.role) order by s.role desc, s.name)
      from public.staff s where s.bar_id = b.id and s.active and s.user_id is not null), '[]'::jsonb))
  from public.bars b where b.code = upper(trim(p_code))
$$;

create or replace function public.gb_admin_check_pin(p_code text, p_staff uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff; pp gb_private.staff_pins; left_tries int;
begin
  select st.* into s from public.staff st join public.bars b on b.id = st.bar_id
  where st.id = p_staff and b.code = upper(trim(p_code)) and st.active;
  if not found then return jsonb_build_object('ok', false, 'error', 'Membre introuvable pour ce bar.'); end if;
  select * into pp from gb_private.staff_pins where staff_id = s.id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Aucun PIN défini. Demandez à la caisse.'); end if;
  if pp.locked_until is not null and pp.locked_until > now() then
    return jsonb_build_object('ok', false, 'error',
      format('Trop d''essais. Réessayez dans %s min.', ceil(extract(epoch from (pp.locked_until - now())) / 60)::int));
  end if;
  if pp.pin_hash = extensions.crypt(coalesce(p_pin, ''), pp.pin_hash) then
    update gb_private.staff_pins set failed_attempts = 0, locked_until = null where staff_id = s.id;
    return jsonb_build_object('ok', true, 'user_id', s.user_id);
  end if;
  if pp.failed_attempts + 1 >= 5 then
    update gb_private.staff_pins set failed_attempts = 0, locked_until = now() + interval '5 minutes' where staff_id = s.id;
    perform gb_private.log(s.bar_id, s.id, 'pin_bloque', '{}'::jsonb);
    return jsonb_build_object('ok', false, 'error', 'Trop d''essais. Compte bloqué 5 minutes.');
  end if;
  update gb_private.staff_pins set failed_attempts = failed_attempts + 1 where staff_id = s.id;
  left_tries := 4 - pp.failed_attempts;
  return jsonb_build_object('ok', false, 'error', format('PIN incorrect. %s essai(s) restant(s).', left_tries));
end $$;

create or replace function public.gb_admin_caller(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('staff_id', s.id, 'bar_id', s.bar_id, 'role', s.role)
  from public.staff s where s.user_id = p_user and s.active
$$;

create or replace function public.gb_admin_add_staff(p_caller uuid, p_user uuid, p_name text, p_role text, p_pin text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.staff; s uuid;
begin
  select * into c from public.staff where user_id = p_caller and active and role = 'caisse';
  if not found then raise exception 'Action réservée à la caisse.'; end if;
  perform gb_private.check_pin_format(p_pin);
  if nullif(trim(p_name), '') is null then raise exception 'Indiquez un nom.'; end if;
  if p_role not in ('caisse','serveuse') then raise exception 'Rôle inconnu.'; end if;
  insert into public.staff(bar_id, user_id, name, role) values (c.bar_id, p_user, trim(p_name), p_role) returning id into s;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (s, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  perform gb_private.log(c.bar_id, c.id, 'membre_ajoute', jsonb_build_object('membre', trim(p_name), 'role', p_role));
  return s;
exception when unique_violation then
  raise exception 'Ce nom est déjà utilisé dans l''équipe.';
end $$;

-- ───────────────────────── Sécurité : RLS ─────────────────────────
alter table public.bars enable row level security;
alter table public.staff enable row level security;
alter table gb_private.staff_pins enable row level security;
alter table public.products enable row level security;
alter table public.service_days enable row level security;
alter table public.tickets enable row level security;
alter table public.ticket_items enable row level security;
alter table public.holdings enable row level security;
alter table public.remittances enable row level security;
alter table public.vouchers enable row level security;
alter table public.stock_moves enable row level security;
alter table public.audit_log enable row level security;

create policy bars_read on public.bars for select to authenticated using (id = (select gb_private.bar()));
create policy staff_read on public.staff for select to authenticated using (bar_id = (select gb_private.bar()));
create policy products_read on public.products for select to authenticated using (bar_id = (select gb_private.bar()));
create policy days_read on public.service_days for select to authenticated using (bar_id = (select gb_private.bar()));
create policy tickets_read on public.tickets for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or waitress_id = (select gb_private.me())));
create policy items_read on public.ticket_items for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse())
         or exists (select 1 from public.tickets t where t.id = ticket_id and t.waitress_id = (select gb_private.me()))));
create policy holdings_read on public.holdings for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or waitress_id = (select gb_private.me())));
create policy remittances_read on public.remittances for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or waitress_id = (select gb_private.me())));
create policy vouchers_read on public.vouchers for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or waitress_id = (select gb_private.me())));
create policy moves_read on public.stock_moves for select to authenticated
  using (bar_id = (select gb_private.bar()) and (select gb_private.is_caisse()));
create policy audit_read on public.audit_log for select to authenticated
  using (bar_id = (select gb_private.bar()) and (select gb_private.is_caisse()));

-- Lecture seule côté client : toutes les écritures passent par les fonctions ci-dessus.
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant select on all tables in schema public to authenticated;
revoke all on all tables in schema gb_private from anon, authenticated;

revoke all on schema gb_private from public;
grant usage on schema gb_private to authenticated, service_role;
revoke execute on all functions in schema gb_private from public, anon, authenticated;
grant execute on function gb_private.bar(), gb_private.me(), gb_private.is_caisse() to authenticated;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'gb\_%' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname like 'gb\_admin\_%' then
      execute format('revoke execute on function %s from authenticated', f.sig);
      execute format('grant execute on function %s to service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;

-- Temps réel
alter publication supabase_realtime add table public.tickets, public.ticket_items, public.holdings,
  public.vouchers, public.remittances, public.products, public.service_days;
