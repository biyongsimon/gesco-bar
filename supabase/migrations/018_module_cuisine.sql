-- 018 · Module Cuisine (inclus à partir de Snack Gold)
-- Plats = produits de catégorie « Cuisine » ou vendus au « plat » / à la « portion », quand le module est activé.
-- À l'envoi du ticket, chaque plat crée un bon cuisine (numéro, table, serveuse) ; les ingrédients de la recette sortent du stock.
-- Écran cuisine : attente → en préparation → prêt ; la serveuse du ticket confirme le retrait (servi).
-- Annulation avant préparation : ingrédients rendus au stock. Les plats ne passent jamais par les bouteilles en main.

alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (role in ('pdg', 'directeur', 'caisse', 'serveuse', 'cuisine'));
alter table public.bars add column if not exists kitchen_on boolean not null default false, add column if not exists next_bon int not null default 1;
alter table public.stock_moves drop constraint if exists stock_moves_kind_check;
alter table public.stock_moves add constraint stock_moves_kind_check
  check (kind in ('appro', 'dotation', 'reprise', 'ajustement', 'ouverture', 'vente_comptoir', 'inventaire', 'cuisine', 'cuisine_retour'));

create table if not exists public.kitchen_orders (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  product_id uuid not null references public.products(id),
  waitress_id uuid not null references public.staff(id),
  label text, ticket_no int, bon int not null, qty int not null check (qty > 0),
  status text not null default 'attente' check (status in ('attente', 'prep', 'pret', 'servi', 'annule')),
  created_at timestamptz not null default now(), started_at timestamptz, ready_at timestamptz, served_at timestamptz,
  cook_id uuid references public.staff(id)
);
create index if not exists kitchen_orders_bar on public.kitchen_orders(bar_id, created_at desc);
create index if not exists kitchen_orders_ticket on public.kitchen_orders(ticket_id);

create table if not exists public.recipes (
  bar_id uuid not null references public.bars(id) on delete cascade,
  dish_id uuid not null references public.products(id) on delete cascade,
  ingredient_id uuid not null references public.products(id) on delete cascade,
  qty numeric not null check (qty > 0 and qty <= 100000),
  primary key (dish_id, ingredient_id)
);

create or replace function gb_private.my_role() returns text
language sql stable security definer set search_path = '' as $$
  select s.role from public.staff s where s.user_id = (select auth.uid()) and s.active
$$;

alter table public.kitchen_orders enable row level security;
alter table public.recipes enable row level security;
drop policy if exists ko_read on public.kitchen_orders;
create policy ko_read on public.kitchen_orders for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or (select gb_private.my_role()) = 'cuisine' or waitress_id = (select gb_private.me())));
drop policy if exists recipes_read on public.recipes;
create policy recipes_read on public.recipes for select to authenticated using (bar_id = (select gb_private.bar()));
do $$ begin alter publication supabase_realtime add table public.kitchen_orders; exception when others then null; end $$;

create or replace function gb_private.is_dish(p_product uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select b.kitchen_on and (p.category = 'Cuisine' or p.unit in ('plat', 'portion'))
    from public.products p join public.bars b on b.id = p.bar_id where p.id = p_product), false)
$$;

-- Bon cuisine + sortie des ingrédients
create or replace function gb_private.kitchen_take(p_ticket uuid, p_product uuid, p_qty int, p_sid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tickets; n int; r record; q int;
begin
  if coalesce(p_qty, 0) <= 0 then return; end if;
  select * into t from public.tickets where id = p_ticket;
  update public.bars set next_bon = next_bon + 1 where id = t.bar_id returning next_bon - 1 into n;
  insert into public.kitchen_orders(bar_id, ticket_id, product_id, waitress_id, label, ticket_no, bon, qty)
  values (t.bar_id, t.id, p_product, t.waitress_id, t.client_label, t.number, n, p_qty);
  for r in select ingredient_id, qty from public.recipes where dish_id = p_product loop
    q := ceil(r.qty * p_qty)::int;
    update public.products set stock = stock - q where id = r.ingredient_id;
    insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (t.bar_id, r.ingredient_id, -q, 'cuisine', p_sid);
  end loop;
end $$;

-- Ingrédients rendus au stock (plat annulé avant d'être préparé)
create or replace function gb_private.kitchen_release(p_order uuid, p_qty int, p_sid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.kitchen_orders; r record; q int;
begin
  select * into o from public.kitchen_orders where id = p_order;
  for r in select ingredient_id, qty from public.recipes where dish_id = o.product_id loop
    q := ceil(r.qty * p_qty)::int;
    update public.products set stock = stock + q where id = r.ingredient_id;
    insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (o.bar_id, r.ingredient_id, q, 'cuisine_retour', p_sid);
  end loop;
end $$;

create or replace function gb_private.kitchen_send(p_ticket uuid, p_sid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare i record;
begin
  for i in select product_id, qty from public.ticket_items where ticket_id = p_ticket loop
    if gb_private.is_dish(i.product_id) then perform gb_private.kitchen_take(p_ticket, i.product_id, i.qty, p_sid); end if;
  end loop;
end $$;

-- Réduire les bons pas encore commencés (sinon refus : le plat est déjà en préparation)
create or replace function gb_private.kitchen_reduce(p_ticket uuid, p_product uuid, p_qty int, p_sid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare o record; left_q int := p_qty; take int; pend int;
begin
  select coalesce(sum(qty), 0) into pend from public.kitchen_orders where ticket_id = p_ticket and product_id = p_product and status = 'attente';
  if pend < p_qty then raise exception 'Ce plat est déjà en préparation en cuisine : demandez son annulation à la caisse.'; end if;
  for o in select * from public.kitchen_orders where ticket_id = p_ticket and product_id = p_product and status = 'attente' order by created_at desc loop
    exit when left_q <= 0;
    take := least(o.qty, left_q);
    perform gb_private.kitchen_release(o.id, take, p_sid);
    if take = o.qty then update public.kitchen_orders set status = 'annule' where id = o.id;
    else update public.kitchen_orders set qty = qty - take where id = o.id; end if;
    left_q := left_q - take;
  end loop;
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
  perform gb_private.kitchen_send(p_ticket, c.sid);
end $$;

create or replace function public.gb_ticket_cash(p_ticket uuid, p_method text, p_received integer) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; r int; owner_role text; d uuid;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if c.srole <> 'caisse' and t.waitress_id <> c.sid then raise exception 'Ce ticket appartient à une autre serveuse.'; end if;
  if t.status in ('cashed','paid') then return; end if;
  if t.status = 'draft' and t.total > 0 then
    select role into owner_role from public.staff where id = t.waitress_id;
    if owner_role = 'caisse' then t.status := 'sent'; update public.tickets set status = 'sent', sent_at = now() where id = p_ticket;
      perform gb_private.kitchen_send(p_ticket, c.sid); end if;
  end if;
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
  select role into owner_role from public.staff where id = t.waitress_id;
  update public.tickets set status = case when owner_role = 'caisse' then 'paid' else 'cashed' end,
    pay_method = p_method, received = r, change_due = r - t.total,
    change_status = case when r > t.total then 'pending' else 'none' end,
    cashed_at = now(), paid_at = case when owner_role = 'caisse' then now() end, updated_at = now()
  where id = p_ticket;
  if owner_role = 'caisse' and p_method = 'cash' then
    d := gb_private.current_day(c.bid, c.sid);
    insert into public.remittances(bar_id, day_id, waitress_id, expected, received, ticket_count, created_by)
    values (c.bid, d, t.waitress_id, r, r, 1, c.sid);
  end if;
end $$;

create or replace function public.gb_ticket_set_qty(p_ticket uuid, p_product uuid, p_qty integer) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; p public.products; cur int; d int; owner_role text; dish boolean;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.waitress_id <> c.sid then
    if c.srole = 'caisse' then raise exception 'La caisse ne peut pas modifier la commande d''une serveuse. Seule la serveuse corrige sa commande.'; end if;
    raise exception 'Ce ticket appartient à une autre serveuse.';
  end if;
  if t.status not in ('draft','sent') then raise exception 'Ticket déjà encaissé : il est verrouillé.'; end if;
  p_qty := greatest(0, coalesce(p_qty, 0));
  if p_qty > 200 then raise exception 'Quantité trop élevée.'; end if;
  select * into p from public.products where id = p_product and bar_id = c.bid;
  if not found then raise exception 'Produit introuvable.'; end if;
  select qty into cur from public.ticket_items where ticket_id = p_ticket and product_id = p_product;
  cur := coalesce(cur, 0); d := p_qty - cur;
  if d = 0 then return; end if;
  if cur = 0 and not p.active then raise exception 'Ce produit n''est plus disponible.'; end if;
  dish := gb_private.is_dish(p_product);
  if dish and t.status = 'sent' and d < 0 then perform gb_private.kitchen_reduce(p_ticket, p_product, -d, c.sid); end if;
  if p_qty = 0 then
    delete from public.ticket_items where ticket_id = p_ticket and product_id = p_product;
  elsif cur = 0 then
    insert into public.ticket_items(ticket_id, product_id, bar_id, qty, unit_price) values (p_ticket, p_product, c.bid, p_qty, p.price);
  else
    update public.ticket_items set qty = p_qty where ticket_id = p_ticket and product_id = p_product;
  end if;
  if dish then
    if t.status = 'sent' and d > 0 then perform gb_private.kitchen_take(p_ticket, p_product, d, c.sid); end if;
  else
    select role into owner_role from public.staff where id = t.waitress_id;
    if owner_role = 'caisse' then
      update public.products set stock = stock - d where id = p_product;
    else
      insert into public.holdings(bar_id, waitress_id, product_id, qty) values (c.bid, t.waitress_id, p_product, -d)
      on conflict (waitress_id, product_id) do update set qty = public.holdings.qty - d;
    end if;
  end if;
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

create or replace function gb_private.cancel_ticket(p_ticket uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tickets; owner_role text; o record;
begin
  select * into t from public.tickets where id = p_ticket for update;
  select role into owner_role from public.staff where id = t.waitress_id;
  if owner_role = 'caisse' then
    update public.products p set stock = p.stock + i.qty from public.ticket_items i
    where i.ticket_id = p_ticket and p.id = i.product_id and not gb_private.is_dish(i.product_id);
  else
    insert into public.holdings(bar_id, waitress_id, product_id, qty)
      select t.bar_id, t.waitress_id, i.product_id, i.qty from public.ticket_items i where i.ticket_id = p_ticket and not gb_private.is_dish(i.product_id)
    on conflict (waitress_id, product_id) do update set qty = public.holdings.qty + excluded.qty;
  end if;
  for o in select * from public.kitchen_orders where ticket_id = p_ticket and status in ('attente', 'prep', 'pret') loop
    if o.status = 'attente' then perform gb_private.kitchen_release(o.id, o.qty, p_staff); end if;
    update public.kitchen_orders set status = 'annule' where id = o.id;
  end loop;
  update public.vouchers set status = 'void' where ticket_id = p_ticket and status = 'active';
  update public.tickets set status = 'cancelled', cancel_requested = false, updated_at = now() where id = p_ticket;
  perform gb_private.log(t.bar_id, p_staff, 'ticket_supprime',
    jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total, 'statut_avant', t.status));
end $$;

-- Écran cuisine : faire avancer un bon ; la serveuse du ticket confirme le retrait
create or replace function public.gb_kitchen_step(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; o public.kitchen_orders;
begin
  select * into c from gb_private.ctx();
  select * into o from public.kitchen_orders where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Bon cuisine introuvable.'; end if;
  if o.status in ('servi', 'annule') then raise exception 'Ce bon est déjà %.', case o.status when 'servi' then 'servi' else 'annulé' end; end if;
  if p_status = 'servi' then
    if o.waitress_id <> c.sid and c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Seule la serveuse de la table récupère ce plat.'; end if;
    if o.status <> 'pret' then raise exception 'Le plat n''est pas encore prêt.'; end if;
    update public.kitchen_orders set status = 'servi', served_at = now() where id = p_id;
  elsif p_status in ('prep', 'pret', 'attente') then
    if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine.'; end if;
    update public.kitchen_orders set status = p_status,
      started_at = case when p_status in ('prep', 'pret') then coalesce(started_at, now()) else null end,
      ready_at = case when p_status = 'pret' then now() else null end, cook_id = c.sid where id = p_id;
  else raise exception 'Étape inconnue.'; end if;
end $$;

create or replace function public.gb_kitchen_toggle(p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; b public.bars; pl text;
begin
  select * into c from gb_private.ctx();
  if c.srole <> 'pdg' then raise exception 'Seul le PDG active le module Cuisine.'; end if;
  select * into b from public.bars where id = c.bid;
  pl := case when b.plan_trial_until > now() and b.trial_plan is not null then b.trial_plan else b.plan end;
  if coalesce(p_on, false) and pl in ('simple', 'premium') then raise exception 'Le module Cuisine est inclus à partir de la formule Snack Gold (rubrique Abonnement).'; end if;
  update public.bars set kitchen_on = coalesce(p_on, false) where id = c.bid;
  perform gb_private.log(c.bid, c.sid, 'module_cuisine', jsonb_build_object('actif', coalesce(p_on, false)));
end $$;

-- Recette d'un plat : liste d'ingrédients (produits du stock) et quantité par plat
create or replace function public.gb_recipe_set(p_dish uuid, p_items jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; d public.products; it jsonb; q numeric; n int := 0;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into d from public.products where id = p_dish and bar_id = c.bid;
  if not found then raise exception 'Plat introuvable.'; end if;
  delete from public.recipes where dish_id = p_dish;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    q := (it->>'q')::numeric; if q is null or q <= 0 then continue; end if;
    if (it->>'i')::uuid = p_dish then raise exception 'Un plat ne peut pas être son propre ingrédient.'; end if;
    if not exists (select 1 from public.products where id = (it->>'i')::uuid and bar_id = c.bid) then raise exception 'Ingrédient introuvable.'; end if;
    insert into public.recipes(bar_id, dish_id, ingredient_id, qty) values (c.bid, p_dish, (it->>'i')::uuid, q)
    on conflict (dish_id, ingredient_id) do update set qty = excluded.qty;
    n := n + 1;
  end loop;
  perform gb_private.log(c.bid, c.sid, 'recette_modifiee', jsonb_build_object('plat', d.name, 'ingredients', n));
end $$;

create or replace function gb_private.check_staff_limit(p_bar uuid, p_role text, p_except uuid default null) returns void
language plpgsql stable security definer set search_path = '' as $$
declare b public.bars; pl text; nserv int; ncaisse int; ntot int; label text;
begin
  select * into b from public.bars where id = p_bar;
  pl := case when b.plan_trial_until > now() and b.trial_plan is not null then b.trial_plan else b.plan end;
  if pl in ('beta', 'lounge') or pl is null then return; end if;
  label := case pl when 'simple' then 'Snack Simple' when 'premium' then 'Snack Premium' when 'gold' then 'Snack Gold' else pl end;
  select count(*) filter (where role = 'serveuse'), count(*) filter (where role = 'caisse'), count(*) filter (where role <> 'pdg')
    into nserv, ncaisse, ntot from public.staff where bar_id = p_bar and active and id is distinct from p_except;
  if p_role = 'directeur' and pl in ('simple', 'premium') then raise exception 'La formule % ne comprend pas de directeur : passez à Snack Gold.', label; end if;
  if p_role = 'cuisine' and pl in ('simple', 'premium') then raise exception 'Le module Cuisine est inclus à partir de Snack Gold.'; end if;
  if pl = 'simple' and ((p_role = 'serveuse' and nserv >= 3) or (p_role = 'caisse' and ncaisse >= 1)) then
    raise exception 'La formule Snack Simple comprend 1 caisse et 3 serveuses : passez à Snack Premium pour en ajouter.'; end if;
  if pl = 'premium' and ((p_role = 'serveuse' and nserv >= 6) or (p_role = 'caisse' and ncaisse >= 2)) then
    raise exception 'La formule Snack Premium comprend 2 caisses et 6 serveuses : passez à Snack Gold pour en ajouter.'; end if;
  if pl = 'gold' and ntot >= 12 then raise exception 'La formule Snack Gold comprend 12 employés : passez à Lounge pour en ajouter.'; end if;
end $$;

create or replace function public.gb_admin_add_staff(p_caller uuid, p_user uuid, p_name text, p_role text, p_pin text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.staff; s uuid; blk text;
begin
  select * into c from public.staff where user_id = p_caller and active and role in ('pdg','directeur');
  if not found then raise exception 'Seuls le directeur et le PDG ajoutent des membres.'; end if;
  blk := gb_private.bar_block(c.bar_id); if blk is not null then raise exception '%', blk; end if;
  perform gb_private.check_pin_format(p_pin);
  if nullif(trim(p_name), '') is null then raise exception 'Indiquez un nom.'; end if;
  if p_role not in ('directeur','caisse','serveuse','cuisine') then raise exception 'Rôle inconnu.'; end if;
  if p_role = 'directeur' and c.role <> 'pdg' then raise exception 'Seul le PDG peut ajouter un directeur.'; end if;
  perform gb_private.check_staff_limit(c.bar_id, p_role);
  insert into public.staff(bar_id, user_id, name, role) values (c.bar_id, p_user, trim(p_name), p_role) returning id into s;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (s, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  perform gb_private.log(c.bar_id, c.id, 'membre_ajoute', jsonb_build_object('membre', trim(p_name), 'role', p_role));
  return s;
exception when unique_violation then raise exception 'Ce nom est déjà utilisé dans l''équipe.';
end $$;

revoke all on function public.gb_kitchen_step(uuid, text), public.gb_kitchen_toggle(boolean), public.gb_recipe_set(uuid, jsonb) from public, anon;
grant execute on function public.gb_kitchen_step(uuid, text), public.gb_kitchen_toggle(boolean), public.gb_recipe_set(uuid, jsonb) to authenticated;
