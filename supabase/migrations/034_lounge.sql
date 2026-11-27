-- 034 : fonctions lounge et boîte de nuit (chacune activable dans Options du bar).
--  f_nuit  : prix de nuit à partir d'une heure choisie (jusqu'à 6 h), par produit
--  f_vip   : réservations de tables avec minimum de consommation
--  f_porte : entrées payantes à la porte (espèces dans le tiroir)
--  f_garde : bouteilles entamées gardées au nom du client
alter table public.products add column if not exists night_price int check (night_price is null or night_price between 0 and 10000000);

-- Prix appliqué maintenant (tarif de nuit si l'option est active et l'heure atteinte, heure de Douala)
create or replace function gb_private.price_now(p_bar uuid, p_product uuid) returns int
language plpgsql stable security definer set search_path = '' as $$
declare o jsonb; p public.products; t time := (now() at time zone 'Africa/Douala')::time; h time;
begin
  select * into p from public.products where id = p_product; select opts into o from public.bars where id = p_bar;
  if p.night_price is null or not coalesce((o->>'f_nuit')::boolean, false) or coalesce(o->>'nuit_debut', '') !~ '^\d{2}:\d{2}$' then return p.price; end if;
  h := (o->>'nuit_debut')::time;
  if (h > '06:00' and (t >= h or t < '06:00')) or (h <= '06:00' and t >= h and t < '06:00') then return p.night_price; end if;
  return p.price;
end $$;
revoke all on function gb_private.price_now(uuid, uuid) from public, anon, authenticated;

create or replace function public.gb_product_night(p_id uuid, p_price int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; p public.products;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if p_price is not null and p_price < 0 then raise exception 'Prix invalide.'; end if;
  update public.products set night_price = p_price where id = p_id and bar_id = c.bid returning * into p;
  if p.id is null then raise exception 'Produit introuvable.'; end if;
  perform gb_private.log(c.bid, c.sid, 'produit_modifie', jsonb_build_object('produit', p.name, 'prix_nuit', p_price));
end $$;

-- La ligne de ticket prend le prix du moment (jour ou nuit)
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
    insert into public.ticket_items(ticket_id, product_id, bar_id, qty, unit_price) values (p_ticket, p_product, c.bid, p_qty, gb_private.price_now(c.bid, p_product));
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

-- Réservations de tables (VIP)
create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  day date not null, hour text check (hour is null or hour ~ '^\d{2}:\d{2}$'),
  name text not null check (length(trim(name)) between 2 and 60), phone text check (phone is null or length(phone) <= 30),
  people int check (people is null or people between 1 and 200), table_label text check (table_label is null or length(table_label) <= 40),
  min_spend int not null default 0 check (min_spend between 0 and 100000000),
  status text not null default 'prevue' check (status in ('prevue', 'arrivee', 'terminee', 'annulee', 'absente')),
  ticket_id uuid references public.tickets(id) on delete set null, note text check (note is null or length(note) <= 200),
  created_by uuid references public.staff(id), created_at timestamptz not null default now());
create index if not exists reservations_bar_day on public.reservations(bar_id, day);
alter table public.reservations enable row level security;
drop policy if exists reservations_read on public.reservations;
create policy reservations_read on public.reservations for select to authenticated using (bar_id = (select gb_private.bar()));
grant select on public.reservations to authenticated;

create or replace function public.gb_resa_save(p_id uuid, p_day date, p_hour text, p_name text, p_phone text, p_people int, p_table text, p_min int, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c record; nid uuid;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Les réservations sont gérées par la caisse et la direction.'; end if;
  perform gb_private.need_opt(c.bid, 'f_vip', 'Les réservations');
  if p_day is null or p_day < gb_private.biz_date() then raise exception 'Choisissez une date à venir.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Indiquez le nom du client.'; end if;
  if p_id is null then
    insert into public.reservations(bar_id, day, hour, name, phone, people, table_label, min_spend, note, created_by)
    values (c.bid, p_day, nullif(p_hour, ''), trim(p_name), nullif(trim(coalesce(p_phone, '')), ''), p_people, nullif(trim(coalesce(p_table, '')), ''), coalesce(p_min, 0), nullif(trim(coalesce(p_note, '')), ''), c.sid)
    returning id into nid;
  else
    update public.reservations set day = p_day, hour = nullif(p_hour, ''), name = trim(p_name), phone = nullif(trim(coalesce(p_phone, '')), ''), people = p_people,
      table_label = nullif(trim(coalesce(p_table, '')), ''), min_spend = coalesce(p_min, 0), note = nullif(trim(coalesce(p_note, '')), '')
    where id = p_id and bar_id = c.bid returning id into nid;
    if nid is null then raise exception 'Réservation introuvable.'; end if;
  end if;
  perform gb_private.log(c.bid, c.sid, 'reservation', jsonb_build_object('client', trim(p_name), 'date', p_day, 'table', p_table, 'minimum', p_min));
  return nid;
end $$;

-- Arrivée (avec le ticket ouvert par la serveuse), fin, annulation, absence
create or replace function public.gb_resa_status(p_id uuid, p_status text, p_ticket uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; r public.reservations;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_opt(c.bid, 'f_vip', 'Les réservations');
  select * into r from public.reservations where id = p_id and bar_id = c.bid for update; if not found then raise exception 'Réservation introuvable.'; end if;
  if p_status not in ('prevue', 'arrivee', 'terminee', 'annulee', 'absente') then raise exception 'Statut inconnu.'; end if;
  if c.srole = 'serveuse' then
    if p_status <> 'arrivee' or p_ticket is null then raise exception 'La serveuse ouvre seulement le ticket de la table réservée.'; end if;
    if not exists (select 1 from public.tickets where id = p_ticket and bar_id = c.bid and waitress_id = c.sid) then raise exception 'Ticket introuvable.'; end if;
  elsif c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Action non autorisée.'; end if;
  if p_ticket is not null and not exists (select 1 from public.tickets where id = p_ticket and bar_id = c.bid) then raise exception 'Ticket introuvable.'; end if;
  update public.reservations set status = p_status, ticket_id = coalesce(p_ticket, ticket_id) where id = r.id;
  perform gb_private.log(c.bid, c.sid, 'reservation_' || p_status, jsonb_build_object('client', r.name, 'table', r.table_label));
end $$;

-- Entrées à la porte
create table if not exists public.door_entries (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  day_id uuid references public.service_days(id), label text not null check (length(label) between 1 and 40),
  qty int not null check (qty between 1 and 500), unit_price int not null check (unit_price between 0 and 1000000), total int not null,
  method text not null check (method in ('cash', 'momo')), remittance_id uuid references public.remittances(id) on delete set null,
  created_by uuid references public.staff(id), created_at timestamptz not null default now());
create index if not exists door_entries_day on public.door_entries(bar_id, day_id);
alter table public.door_entries enable row level security;
drop policy if exists door_entries_read on public.door_entries;
create policy door_entries_read on public.door_entries for select to authenticated using (bar_id = (select gb_private.bar()) and (select gb_private.is_caisse() or gb_private.is_manager()));
grant select on public.door_entries to authenticated;

create or replace function public.gb_door_sell(p_label text, p_price int, p_qty int, p_method text default 'cash') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; d uuid; rid uuid; nid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  perform gb_private.need_opt(c.bid, 'f_porte', 'Les entrées à la porte');
  if length(trim(coalesce(p_label, ''))) = 0 then raise exception 'Choisissez le tarif.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 500 then raise exception 'Nombre d''entrées invalide.'; end if;
  if p_price is null or p_price < 0 then raise exception 'Prix invalide.'; end if;
  if p_method not in ('cash', 'momo') then raise exception 'Mode de paiement inconnu.'; end if;
  d := gb_private.current_day(c.bid, c.sid);
  if p_method = 'cash' and p_price * p_qty > 0 then
    insert into public.remittances(bar_id, day_id, waitress_id, expected, received, ticket_count, created_by) values (c.bid, d, c.sid, p_price * p_qty, p_price * p_qty, 0, c.sid) returning id into rid;
  end if;
  insert into public.door_entries(bar_id, day_id, label, qty, unit_price, total, method, remittance_id, created_by)
  values (c.bid, d, trim(p_label), p_qty, p_price, p_price * p_qty, p_method, rid, c.sid) returning id into nid;
  return jsonb_build_object('id', nid, 'total', p_price * p_qty);
end $$;

create or replace function public.gb_door_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; e public.door_entries;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into e from public.door_entries where id = p_id and bar_id = c.bid; if not found then raise exception 'Entrée introuvable.'; end if;
  if e.created_at < now() - interval '15 minutes' and c.srole <> 'pdg' then raise exception 'Après 15 minutes, seul le PDG peut annuler une entrée.'; end if;
  if exists (select 1 from public.service_days where id = e.day_id and status = 'closed') then raise exception 'La journée est clôturée.'; end if;
  delete from public.door_entries where id = e.id;
  if e.remittance_id is not null then delete from public.remittances where id = e.remittance_id; end if;
  perform gb_private.log(c.bid, c.sid, 'entree_annulee', jsonb_build_object('tarif', e.label, 'quantite', e.qty, 'montant', e.total));
end $$;

-- Bouteilles gardées pour le client
create table if not exists public.kept_bottles (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  client text not null check (length(trim(client)) between 2 and 60), phone text check (phone is null or length(phone) <= 30),
  product_id uuid not null references public.products(id), level text not null default '1/2' check (level in ('3/4', '1/2', '1/4', 'fond')),
  tag text check (tag is null or length(tag) <= 20), note text check (note is null or length(note) <= 200),
  status text not null default 'gardee' check (status in ('gardee', 'rendue', 'retiree')),
  created_by uuid references public.staff(id), created_at timestamptz not null default now(), closed_by uuid references public.staff(id), closed_at timestamptz);
create index if not exists kept_bottles_bar on public.kept_bottles(bar_id, status);
alter table public.kept_bottles enable row level security;
drop policy if exists kept_bottles_read on public.kept_bottles;
create policy kept_bottles_read on public.kept_bottles for select to authenticated using (bar_id = (select gb_private.bar()));
grant select on public.kept_bottles to authenticated;

create or replace function public.gb_keep_add(p_client text, p_phone text, p_product uuid, p_level text, p_tag text default null, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c record; nid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  perform gb_private.need_opt(c.bid, 'f_garde', 'Les bouteilles gardées');
  if not exists (select 1 from public.products where id = p_product and bar_id = c.bid) then raise exception 'Produit introuvable.'; end if;
  insert into public.kept_bottles(bar_id, client, phone, product_id, level, tag, note, created_by)
  values (c.bid, trim(p_client), nullif(trim(coalesce(p_phone, '')), ''), p_product, coalesce(p_level, '1/2'), nullif(trim(coalesce(p_tag, '')), ''), nullif(trim(coalesce(p_note, '')), ''), c.sid) returning id into nid;
  perform gb_private.log(c.bid, c.sid, 'bouteille_gardee', jsonb_build_object('client', trim(p_client), 'produit', (select name from public.products where id = p_product), 'niveau', p_level));
  return nid;
end $$;

create or replace function public.gb_keep_close(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; k public.kept_bottles;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if p_status not in ('rendue', 'retiree') then raise exception 'Statut inconnu.'; end if;
  update public.kept_bottles set status = p_status, closed_by = c.sid, closed_at = now() where id = p_id and bar_id = c.bid and status = 'gardee' returning * into k;
  if k.id is null then raise exception 'Bouteille introuvable ou déjà rendue.'; end if;
  perform gb_private.log(c.bid, c.sid, 'bouteille_' || p_status, jsonb_build_object('client', k.client, 'produit', (select name from public.products where id = k.product_id)));
end $$;

revoke all on function public.gb_product_night(uuid, int), public.gb_resa_save(uuid, date, text, text, text, int, text, int, text), public.gb_resa_status(uuid, text, uuid),
  public.gb_door_sell(text, int, int, text), public.gb_door_cancel(uuid), public.gb_keep_add(text, text, uuid, text, text, text), public.gb_keep_close(uuid, text) from public, anon;
grant execute on function public.gb_product_night(uuid, int), public.gb_resa_save(uuid, date, text, text, text, int, text, int, text), public.gb_resa_status(uuid, text, uuid),
  public.gb_door_sell(text, int, int, text), public.gb_door_cancel(uuid), public.gb_keep_add(text, text, uuid, text, text, text), public.gb_keep_close(uuid, text) to authenticated;

-- Options : heure du tarif de nuit et tarifs de la porte
create or replace function public.gb_bar_opts(p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; k text; v jsonb; o jsonb; x jsonb;
begin
  select * into c from gb_private.ctx();
  if c.srole <> 'pdg' then raise exception 'Seul le PDG modifie ces réglages.'; end if;
  if jsonb_typeof(coalesce(p_patch, '{}')) <> 'object' then raise exception 'Réglages invalides.'; end if;
  select opts into o from public.bars where id = c.bid;
  for k, v in select * from jsonb_each(p_patch) loop
    if k in ('remit_r1', 'remit_r2', 'remit_r3') then
      if jsonb_typeof(v) <> 'number' or (v::text)::int < 0 or (v::text)::int > 600 then raise exception 'Délai invalide (0 à 600 minutes).'; end if;
    elsif k = 'phone' then
      if jsonb_typeof(v) <> 'string' or length(v #>> '{}') > 40 then raise exception 'Téléphone invalide.'; end if;
    elsif k in ('f_ardoise', 'f_vides', 'f_vip', 'f_porte', 'f_nuit', 'f_garde', 'f_print', 'f_mural', 'f_recettes') then
      if jsonb_typeof(v) <> 'boolean' then raise exception 'Option invalide.'; end if;
    elsif k = 'nuit_debut' then
      if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Heure invalide (ex. 22:00).'; end if;
    elsif k = 'porte_tarifs' then
      if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) > 8 then raise exception 'Tarifs invalides (8 au maximum).'; end if;
      for x in select * from jsonb_array_elements(v) loop
        if jsonb_typeof(x->'l') <> 'string' or length(x->>'l') not between 1 and 40 or jsonb_typeof(x->'p') <> 'number' or (x->>'p')::int < 0 then raise exception 'Tarif invalide.'; end if;
      end loop;
    else raise exception 'Réglage inconnu : %', k; end if;
    o := o || jsonb_build_object(k, v);
  end loop;
  if coalesce((o->>'remit_r1')::int, 20) > 0 and ((o->>'remit_r2')::int between 1 and coalesce((o->>'remit_r1')::int, 20)
     or (o->>'remit_r3')::int between 1 and coalesce((o->>'remit_r2')::int, 45)) then
    raise exception 'Les délais doivent aller croissant (1er rappel, puis caisse, puis directeur).'; end if;
  update public.bars set opts = o where id = c.bid;
  perform gb_private.log(c.bid, c.sid, 'reglages_modifies', p_patch);
  return o;
end $$;

-- Rapport de clôture : entrées de la porte
create or replace function public.gb_day_close(p_counted integer, p_force boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; d public.service_days; pending int; s jsonb; exp int; sales int; cash_in int; change_out int; momo int; vouch int; tir int; pl jsonb;
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
  tir := gb_private.tiroir_out(c.bid, d.opened_at);
  exp := cash_in - change_out - tir;
  -- Plats vendus (tickets payés de la journée), au prix enregistré sur le ticket
  select jsonb_build_object('montant', coalesce(sum(x.m), 0), 'qte', coalesce(sum(x.q), 0),
      'detail', coalesce(jsonb_agg(jsonb_build_object('plat', x.name, 'qte', x.q, 'prix', x.unit_price, 'montant', x.m) order by x.m desc), '[]'::jsonb))
    into pl
  from (select p.name, i.unit_price, sum(i.qty)::int q, sum(i.qty * i.unit_price)::int m
        from public.ticket_items i join public.tickets t on t.id = i.ticket_id join public.products p on p.id = i.product_id
        where t.day_id = d.id and t.status in ('cashed', 'paid') and (p.category = 'Cuisine' or p.unit in ('plat', 'portion'))
        group by p.name, i.unit_price) x;
  select jsonb_build_object(
    'ventes', sales, 'especes_versees', cash_in, 'monnaie_rendue', change_out, 'mobile_money', momo, 'bons_emis', vouch,
    'depenses_caisse', tir, 'plats', pl, 'boissons', sales - coalesce((pl->>'montant')::int, 0),
    'ardoise', coalesce((select sum(total) from public.tickets where day_id = d.id and status = 'paid' and pay_method = 'credit'), 0),
    'ardoise_remb', coalesce((select sum(amount) from public.credit_moves where bar_id = c.bid and kind = 'remboursement' and created_at >= d.opened_at), 0),
    'entrees', (select jsonb_build_object('n', coalesce(sum(qty), 0), 'montant', coalesce(sum(total), 0), 'especes', coalesce(sum(total) filter (where method = 'cash'), 0),
        'momo', coalesce(sum(total) filter (where method = 'momo'), 0)) from public.door_entries where day_id = d.id),
    'tickets', (select count(*) from public.tickets where day_id = d.id and status in ('cashed','paid')),
    'annules', (select count(*) from public.tickets where day_id = d.id and status = 'cancelled'),
    'non_soldes', pending,
    'services', coalesce((select jsonb_agg(jsonb_build_object('caisse', (select name from public.staff where id = h.from_staff),
        'relaye_par', (select name from public.staff where id = h.to_staff), 'heure', h.created_at, 'ventes', h.summary->'ventes',
        'compte', h.counted, 'ecart_service', h.summary->'ecart_service') order by h.created_at) from public.cash_handovers h where h.day_id = d.id), '[]'::jsonb),
    'cuisine_pertes', coalesce((select jsonb_agg(jsonb_build_object('plat', p.name, 'qte', k.qty, 'issue', k.status, 'valeur', k.qty * coalesce(p.cost, 0), 'note', k.note))
        from public.kitchen_orders k join public.products p on p.id = k.product_id where k.bar_id = c.bid and k.status in ('perte', 'personnel') and k.decided_at >= d.opened_at), '[]'::jsonb),
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
