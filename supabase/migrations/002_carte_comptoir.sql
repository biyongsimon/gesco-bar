-- GesCo Bar · v2 : carte libre (vins, spiritueux, vente au verre) et ventes au comptoir par la caisse

-- 1. Produits : unité de vente et vente au verre rattachée à une bouteille
alter table public.products
  add column unit text not null default 'bouteille',
  add column parent_id uuid references public.products(id) on delete set null,
  add column doses integer check (doses is null or doses between 2 and 200);
create index products_parent on public.products(parent_id);

alter table public.stock_moves drop constraint stock_moves_kind_check;
alter table public.stock_moves add constraint stock_moves_kind_check
  check (kind in ('appro','dotation','reprise','ajustement','ouverture','vente_comptoir'));

-- 2. Rend les articles d'un ticket : à la serveuse, ou au stock général si c'est une vente comptoir de la caisse
create or replace function gb_private.cancel_ticket(p_ticket uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tickets; owner_role text;
begin
  select * into t from public.tickets where id = p_ticket for update;
  select role into owner_role from public.staff where id = t.waitress_id;
  if owner_role = 'caisse' then
    update public.products p set stock = p.stock + i.qty from public.ticket_items i where i.ticket_id = p_ticket and p.id = i.product_id;
  else
    insert into public.holdings(bar_id, waitress_id, product_id, qty)
      select t.bar_id, t.waitress_id, i.product_id, i.qty from public.ticket_items i where i.ticket_id = p_ticket
    on conflict (waitress_id, product_id) do update set qty = public.holdings.qty + excluded.qty;
  end if;
  update public.vouchers set status = 'void' where ticket_id = p_ticket and status = 'active';
  update public.tickets set status = 'cancelled', cancel_requested = false, updated_at = now() where id = p_ticket;
  perform gb_private.log(t.bar_id, p_staff, 'ticket_supprime',
    jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total, 'statut_avant', t.status));
end $$;

create or replace function public.gb_ticket_set_qty(p_ticket uuid, p_product uuid, p_qty int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets; p public.products; cur int; d int; owner_role text;
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
  select role into owner_role from public.staff where id = t.waitress_id;
  if owner_role = 'caisse' then
    update public.products set stock = stock - d where id = p_product; -- vente comptoir : le stock général bouge directement
  else
    insert into public.holdings(bar_id, waitress_id, product_id, qty) values (c.bid, t.waitress_id, p_product, -d)
    on conflict (waitress_id, product_id) do update set qty = public.holdings.qty - d;
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

-- 3. Encaissement : une vente comptoir de la caisse est payée tout de suite (l'argent est déjà dans le tiroir)
create or replace function public.gb_ticket_cash(p_ticket uuid, p_method text, p_received int) returns void
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
    if owner_role = 'caisse' then t.status := 'sent'; update public.tickets set status = 'sent', sent_at = now() where id = p_ticket; end if;
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

-- 4. Fiche produit complète (remplace l'ancienne version)
drop function if exists public.gb_product_save(uuid, text, text, int, int, boolean);
create or replace function public.gb_product_save(p_id uuid, p_name text, p_category text, p_price int, p_stock int, p_active boolean,
  p_unit text, p_parent uuid, p_doses int)
returns uuid language plpgsql security definer set search_path = '' as $$
declare c record; p public.products; par public.products; nid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  p_name := nullif(trim(p_name), '');
  if p_name is null then raise exception 'Donnez un nom au produit.'; end if;
  if coalesce(p_price, -1) < 0 then raise exception 'Indiquez un prix valide.'; end if;
  p_unit := coalesce(nullif(trim(p_unit), ''), 'bouteille');
  if p_parent is not null then
    select * into par from public.products where id = p_parent and bar_id = c.bid;
    if not found then raise exception 'Bouteille de référence introuvable.'; end if;
    if par.parent_id is not null then raise exception 'La référence doit être une bouteille, pas un verre.'; end if;
    if p_id is not null and p_parent = p_id then raise exception 'Un produit ne peut pas être sa propre bouteille.'; end if;
    if coalesce(p_doses, 0) < 2 then raise exception 'Indiquez combien de verres donne une bouteille (au moins 2).'; end if;
  else
    p_doses := null;
  end if;
  if p_id is null then
    insert into public.products(bar_id, name, category, price, stock, active, sort, unit, parent_id, doses)
    values (c.bid, p_name, coalesce(nullif(trim(p_category), ''), 'Bières'), p_price, greatest(coalesce(p_stock, 0), 0), coalesce(p_active, true),
            (select coalesce(max(sort), 0) + 1 from public.products where bar_id = c.bid), p_unit, p_parent, p_doses)
    returning id into nid;
    if coalesce(p_stock, 0) > 0 then
      insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (c.bid, nid, p_stock, 'appro', c.sid);
    end if;
    perform gb_private.log(c.bid, c.sid, 'produit_ajoute', jsonb_build_object('produit', p_name, 'prix', p_price, 'unite', p_unit));
    return nid;
  end if;
  select * into p from public.products where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Produit introuvable.'; end if;
  if p_parent is not null and exists (select 1 from public.products where parent_id = p_id) then
    raise exception 'Ce produit sert déjà de bouteille de référence à un verre.';
  end if;
  update public.products set name = p_name, category = coalesce(nullif(trim(p_category), ''), category), price = p_price,
    stock = coalesce(p_stock, stock), active = coalesce(p_active, active), unit = p_unit, parent_id = p_parent, doses = p_doses where id = p_id;
  if p_stock is not null and p_stock <> p.stock then
    insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (c.bid, p_id, p_stock - p.stock, 'ajustement', c.sid);
  end if;
  perform gb_private.log(c.bid, c.sid, 'produit_modifie', jsonb_build_object('produit', p_name, 'prix_avant', p.price, 'prix', p_price, 'stock_avant', p.stock, 'stock', coalesce(p_stock, p.stock)));
  return p_id;
exception when unique_violation then
  raise exception 'Un produit porte déjà ce nom.';
end $$;

-- 5. Ouvrir une bouteille pour la vente au verre : 1 bouteille du stock devient N verres
create or replace function public.gb_open_bottle(p_glass uuid, p_count int) returns int
language plpgsql security definer set search_path = '' as $$
declare c record; g public.products; par public.products; n int;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  p_count := coalesce(p_count, 1);
  if p_count < 1 or p_count > 50 then raise exception 'Nombre de bouteilles invalide.'; end if;
  select * into g from public.products where id = p_glass and bar_id = c.bid for update;
  if not found or g.parent_id is null then raise exception 'Ce produit n''est pas vendu au verre.'; end if;
  select * into par from public.products where id = g.parent_id for update;
  if par.stock < p_count then raise exception 'Stock insuffisant : il reste % bouteille(s) de %.', par.stock, par.name; end if;
  n := p_count * g.doses;
  update public.products set stock = stock - p_count where id = par.id;
  update public.products set stock = stock + n where id = g.id;
  insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values
    (c.bid, par.id, -p_count, 'ouverture', c.sid), (c.bid, g.id, n, 'ouverture', c.sid);
  perform gb_private.log(c.bid, c.sid, 'bouteille_ouverte', jsonb_build_object('produit', par.name, 'quantite', p_count, 'verres', n));
  return n;
end $$;

-- 6. Carte de départ plus complète pour les nouveaux bars
create or replace function gb_private.seed_products(p_bar uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare jb uuid; vr uuid;
begin
  insert into public.products(bar_id, name, category, price, sort, unit) values
    (p_bar, 'Castel Beer 65cl', 'Bières', 650, 1, 'bouteille'),
    (p_bar, '33 Export 65cl', 'Bières', 650, 2, 'bouteille'),
    (p_bar, 'Mützig 65cl', 'Bières', 650, 3, 'bouteille'),
    (p_bar, 'Beaufort 65cl', 'Bières', 650, 4, 'bouteille'),
    (p_bar, 'Guinness 65cl', 'Bières', 1000, 5, 'bouteille'),
    (p_bar, 'Orijin', 'Bières', 650, 6, 'bouteille'),
    (p_bar, 'Coca-Cola', 'Sucreries', 500, 7, 'bouteille'),
    (p_bar, 'Top Pamplemousse', 'Sucreries', 500, 8, 'bouteille'),
    (p_bar, 'Eau minérale 1,5 L', 'Eaux', 600, 9, 'bouteille'),
    (p_bar, 'Vin rouge (bouteille)', 'Vins rouges', 5000, 10, 'bouteille'),
    (p_bar, 'Vin blanc (bouteille)', 'Vins blancs', 5000, 12, 'bouteille'),
    (p_bar, 'Whisky J&B 75cl', 'Spiritueux', 15000, 14, 'bouteille');
  select id into vr from public.products where bar_id = p_bar and name = 'Vin rouge (bouteille)';
  select id into jb from public.products where bar_id = p_bar and name = 'Whisky J&B 75cl';
  insert into public.products(bar_id, name, category, price, sort, unit, parent_id, doses) values
    (p_bar, 'Vin rouge (verre)', 'Vins rouges', 1000, 11, 'verre', vr, 6),
    (p_bar, 'Whisky J&B (verre)', 'Spiritueux', 1500, 15, 'verre', jb, 15);
end $$;

-- Droits des nouvelles fonctions
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
revoke execute on all functions in schema gb_private from public, anon, authenticated;
grant execute on function gb_private.bar(), gb_private.me(), gb_private.is_caisse() to authenticated;
