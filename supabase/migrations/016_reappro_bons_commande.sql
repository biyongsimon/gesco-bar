-- 016 · Réapprovisionnement intelligent et bons de commande
-- gb_reappro : rythme de vente réel (14 derniers jours) → jours de stock restants et quantité à commander
-- purchase_orders : bon envoyé au fournisseur ; à la réception, le stock est mis à jour automatiquement (comme un approvisionnement)

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  number int not null,
  supplier text, supplier_phone text,
  status text not null default 'envoye' check (status in ('envoye', 'recu', 'annule')),
  items jsonb not null default '[]'::jsonb,       -- [{p: id produit, n: nom, q: quantité, c: prix d'achat unitaire}]
  total int not null default 0,
  created_by uuid, created_at timestamptz not null default now(),
  received_at timestamptz, received_by uuid
);
create index if not exists purchase_orders_bar on public.purchase_orders(bar_id, created_at desc);
alter table public.purchase_orders enable row level security;
drop policy if exists po_read on public.purchase_orders;
create policy po_read on public.purchase_orders for select to authenticated
  using (bar_id = (select gb_private.bar()) and (select gb_private.is_caisse()));

create or replace function public.gb_reappro(p_days int default 7) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; win numeric; first_t timestamptz;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la caisse et à la direction.'; end if;
  p_days := least(greatest(coalesce(p_days, 7), 1), 60);
  select min(created_at) into first_t from public.tickets where bar_id = c.bid and status <> 'cancelled';
  win := least(14, greatest(3, extract(epoch from (now() - coalesce(first_t, now()))) / 86400.0));
  return jsonb_build_object('items', coalesce((
    with sold as (
      select ti.product_id, sum(ti.qty)::numeric q from public.ticket_items ti join public.tickets t on t.id = ti.ticket_id
      where ti.bar_id = c.bid and t.status not in ('draft', 'cancelled') and t.created_at > now() - make_interval(days => 14)
      group by 1),
    hold as (select product_id, sum(greatest(qty, 0)) q from public.holdings where bar_id = c.bid group by 1),
    base as (
      select p.id, p.name, p.stock, p.cost, coalesce(h.q, 0) en_main,
        coalesce(s.q, 0) + coalesce((select sum(coalesce(s2.q, 0) / greatest(g.doses, 1)) from public.products g left join sold s2 on s2.product_id = g.id
                                     where g.parent_id = p.id), 0) vendu,
        coalesce((select sum(g.stock::numeric / greatest(g.doses, 1)) from public.products g where g.parent_id = p.id), 0) verres
      from public.products p left join sold s on s.product_id = p.id left join hold h on h.product_id = p.id
      where p.bar_id = c.bid and p.parent_id is null and p.active)
    select jsonb_agg(jsonb_build_object('id', id, 'stock', stock, 'en_main', en_main, 'vendu', round(vendu, 1),
      'par_jour', round(vendu / win, 2), 'dispo', round(stock + en_main + verres, 1),
      'jours', case when vendu > 0 then round((stock + en_main + verres) / (vendu / win), 1) end,
      'conseil', greatest(0, ceil(vendu / win * p_days - (stock + en_main + verres)))::int, 'cout', cost) order by name)
    from base), '[]'::jsonb), 'fenetre', round(win, 1), 'jours_couverts', p_days);
end $$;

create or replace function public.gb_po_create(p_supplier text, p_phone text, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; it jsonb; p public.products; items jsonb := '[]'::jsonb; tot int := 0; q int; uc int; n int; nid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Ajoutez au moins un produit au bon de commande.'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    q := coalesce((it->>'q')::int, 0); if q <= 0 then continue; end if; if q > 100000 then raise exception 'Quantité trop élevée.'; end if;
    select * into p from public.products where id = (it->>'p')::uuid and bar_id = c.bid;
    if not found then raise exception 'Produit introuvable.'; end if;
    uc := greatest(coalesce((it->>'c')::int, p.cost, 0), 0);
    items := items || jsonb_build_object('p', p.id, 'n', p.name, 'q', q, 'c', uc); tot := tot + q * uc;
  end loop;
  if jsonb_array_length(items) = 0 then raise exception 'Ajoutez au moins une quantité.'; end if;
  select coalesce(max(number), 0) + 1 into n from public.purchase_orders where bar_id = c.bid;
  insert into public.purchase_orders(bar_id, number, supplier, supplier_phone, items, total, created_by)
  values (c.bid, n, nullif(trim(coalesce(p_supplier, '')), ''), nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), ''), items, tot, c.sid)
  returning id into nid;
  perform gb_private.log(c.bid, c.sid, 'bon_commande', jsonb_build_object('numero', n, 'fournisseur', p_supplier, 'montant', tot));
  return jsonb_build_object('id', nid, 'number', n);
end $$;

-- Réception : chaque ligne reçue entre dans le stock (approvisionnement tracé, prix d'achat mis à jour pour la compta)
create or replace function public.gb_po_receive(p_id uuid, p_items jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; po public.purchase_orders; it jsonb; p public.products; q int; uc int; got jsonb := '[]'::jsonb; tot int := 0;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into po from public.purchase_orders where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Bon de commande introuvable.'; end if;
  if po.status <> 'envoye' then raise exception 'Ce bon de commande est déjà %.', case po.status when 'recu' then 'reçu' else 'annulé' end; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, po.items)) loop
    q := coalesce((it->>'q')::int, 0); if q <= 0 then continue; end if; if q > 100000 then raise exception 'Quantité trop élevée.'; end if;
    uc := (it->>'c')::int; if uc is not null and uc < 0 then raise exception 'Prix d''achat invalide.'; end if;
    update public.products set stock = stock + q, cost = coalesce(nullif(uc, 0), cost) where id = (it->>'p')::uuid and bar_id = c.bid returning * into p;
    if p.id is null then raise exception 'Produit introuvable.'; end if;
    uc := coalesce(nullif(uc, 0), p.cost, 0);
    insert into public.stock_moves(bar_id, product_id, qty, kind, created_by, unit_cost) values (c.bid, p.id, q, 'appro', c.sid, uc);
    got := got || jsonb_build_object('p', p.id, 'n', p.name, 'q', q, 'c', uc); tot := tot + q * uc;
  end loop;
  update public.purchase_orders set status = 'recu', items = got, total = tot, received_at = now(), received_by = c.sid where id = po.id;
  perform gb_private.log(c.bid, c.sid, 'livraison_recue', jsonb_build_object('numero', po.number, 'fournisseur', po.supplier, 'montant', tot));
end $$;

create or replace function public.gb_po_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; po public.purchase_orders;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  update public.purchase_orders set status = 'annule' where id = p_id and bar_id = c.bid and status = 'envoye' returning * into po;
  if po.id is null then raise exception 'Bon de commande introuvable ou déjà traité.'; end if;
  perform gb_private.log(c.bid, c.sid, 'bon_commande_annule', jsonb_build_object('numero', po.number));
end $$;

revoke all on function public.gb_reappro(int), public.gb_po_create(text, text, jsonb), public.gb_po_receive(uuid, jsonb), public.gb_po_cancel(uuid) from public, anon;
grant execute on function public.gb_reappro(int), public.gb_po_create(text, text, jsonb), public.gb_po_receive(uuid, jsonb), public.gb_po_cancel(uuid) to authenticated;
