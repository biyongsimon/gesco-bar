-- 033 : emballages consignés (casiers et bouteilles vides).
-- Vides théoriques = dernier comptage + bouteilles vendues (ou ouvertes au verre) depuis − vides rendus au dépôt − casse.
-- Le comptage physique révèle les vides manquants (valeur de la consigne perdue). Les vides rendus partent avec le bon de commande.
create table if not exists public.packagings (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 60),
  deposit int not null default 0 check (deposit between 0 and 100000),          -- consigne par bouteille
  per_crate int not null default 12 check (per_crate between 1 and 48),
  active boolean not null default true, created_at timestamptz not null default now());
create index if not exists packagings_bar on public.packagings(bar_id);
alter table public.products add column if not exists packaging_id uuid references public.packagings(id) on delete set null;
create table if not exists public.packaging_moves (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  packaging_id uuid not null references public.packagings(id) on delete cascade,
  kind text not null check (kind in ('comptage', 'retour', 'casse')),
  qty int not null check (qty >= 0 and qty <= 100000), theo int, po_id uuid references public.purchase_orders(id) on delete set null,
  note text check (note is null or length(note) <= 200), created_by uuid references public.staff(id), created_at timestamptz not null default now());
create index if not exists packaging_moves_pack on public.packaging_moves(packaging_id, created_at desc);
alter table public.packagings enable row level security;
alter table public.packaging_moves enable row level security;
drop policy if exists packagings_read on public.packagings;
create policy packagings_read on public.packagings for select to authenticated using (bar_id = (select gb_private.bar()));
grant select on public.packagings to authenticated;
alter table public.purchase_orders add column if not exists empties jsonb not null default '[]'::jsonb;

create or replace function gb_private.pack_theo(p_pack uuid) returns int
language plpgsql stable security definer set search_path = '' as $$
declare lc public.packaging_moves; t0 timestamptz; base int; sold int; opened int; gone int;
begin
  select * into lc from public.packaging_moves where packaging_id = p_pack and kind = 'comptage' order by created_at desc limit 1;
  t0 := coalesce(lc.created_at, (select created_at from public.packagings where id = p_pack)); base := coalesce(lc.qty, 0);
  select coalesce(sum(i.qty), 0) into sold from public.ticket_items i join public.tickets t on t.id = i.ticket_id join public.products p on p.id = i.product_id
    where p.packaging_id = p_pack and t.status in ('cashed', 'paid') and coalesce(t.cashed_at, t.paid_at, t.updated_at) > t0;
  select coalesce(sum(-m.qty), 0) into opened from public.stock_moves m join public.products p on p.id = m.product_id
    where p.packaging_id = p_pack and m.kind = 'ouverture' and m.qty < 0 and m.created_at > t0;
  select coalesce(sum(qty), 0) into gone from public.packaging_moves where packaging_id = p_pack and kind in ('retour', 'casse') and created_at > t0;
  return base + sold + opened - gone;
end $$;
revoke all on function gb_private.pack_theo(uuid) from public, anon, authenticated;

create or replace function gb_private.need_pack(p_bar uuid, p_role text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_role not in ('caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la caisse et à la direction.'; end if;
  perform gb_private.need_opt(p_bar, 'f_vides', 'Le suivi des emballages');
end $$;
revoke all on function gb_private.need_pack(uuid, text) from public, anon, authenticated;

create or replace function public.gb_pack_save(p_id uuid, p_name text, p_deposit int, p_per_crate int, p_products uuid[], p_active boolean default true) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c record; nid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pack(c.bid, c.srole);
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Indiquez le nom de l''emballage (ex. Casier 65 cl).'; end if;
  if p_id is null then
    insert into public.packagings(bar_id, name, deposit, per_crate, active) values (c.bid, trim(p_name), coalesce(p_deposit, 0), coalesce(p_per_crate, 12), coalesce(p_active, true)) returning id into nid;
  else
    update public.packagings set name = trim(p_name), deposit = coalesce(p_deposit, 0), per_crate = coalesce(p_per_crate, 12), active = coalesce(p_active, true)
      where id = p_id and bar_id = c.bid returning id into nid;
    if nid is null then raise exception 'Emballage introuvable.'; end if;
  end if;
  update public.products set packaging_id = null where bar_id = c.bid and packaging_id = nid and not (id = any(coalesce(p_products, '{}')));
  update public.products set packaging_id = nid where bar_id = c.bid and id = any(coalesce(p_products, '{}'));
  perform gb_private.log(c.bid, c.sid, 'emballage', jsonb_build_object('emballage', trim(p_name), 'consigne', p_deposit, 'produits', coalesce(array_length(p_products, 1), 0)));
  return nid;
end $$;

create or replace function public.gb_pack_state() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pack(c.bid, c.srole);
  return coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'deposit', k.deposit, 'per_crate', k.per_crate, 'active', k.active,
      'theo', gb_private.pack_theo(k.id),
      'products', coalesce((select jsonb_agg(p.id) from public.products p where p.packaging_id = k.id), '[]'::jsonb),
      'last_count', (select jsonb_build_object('at', m.created_at, 'qty', m.qty, 'theo', m.theo, 'by', (select name from public.staff where id = m.created_by))
         from public.packaging_moves m where m.packaging_id = k.id and m.kind = 'comptage' order by m.created_at desc limit 1),
      'moves', coalesce((select jsonb_agg(x order by x->>'at' desc) from (select jsonb_build_object('kind', m.kind, 'qty', m.qty, 'theo', m.theo, 'at', m.created_at, 'note', m.note,
         'po', (select number from public.purchase_orders where id = m.po_id), 'by', (select name from public.staff where id = m.created_by)) x
         from public.packaging_moves m where m.packaging_id = k.id order by m.created_at desc limit 8) y), '[]'::jsonb))
    order by k.name) from public.packagings k where k.bar_id = c.bid), '[]'::jsonb);
end $$;

-- Comptage (inventaire des vides), retour au dépôt hors bon de commande, casse
create or replace function public.gb_pack_move(p_pack uuid, p_kind text, p_qty int, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; k public.packagings; th int;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pack(c.bid, c.srole);
  select * into k from public.packagings where id = p_pack and bar_id = c.bid; if not found then raise exception 'Emballage introuvable.'; end if;
  if p_kind not in ('comptage', 'retour', 'casse') then raise exception 'Mouvement inconnu.'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'Indiquez la quantité.'; end if;
  th := gb_private.pack_theo(k.id);
  if p_kind in ('retour', 'casse') and p_qty > th then raise exception 'Il n''y a que % vides de « % » en théorie : comptez d''abord vos vides.', th, k.name; end if;
  insert into public.packaging_moves(bar_id, packaging_id, kind, qty, theo, note, created_by) values (c.bid, k.id, p_kind, p_qty, th, nullif(trim(coalesce(p_note, '')), ''), c.sid);
  perform gb_private.log(c.bid, c.sid, 'emballage_' || p_kind, jsonb_build_object('emballage', k.name, 'quantite', p_qty, 'theorique', th,
    'ecart', case when p_kind = 'comptage' then p_qty - th end, 'manquant_valeur', case when p_kind = 'comptage' and p_qty < th then (th - p_qty) * k.deposit end));
  return jsonb_build_object('theo', th, 'ecart', case when p_kind = 'comptage' then p_qty - th end, 'valeur', case when p_kind = 'comptage' then (p_qty - th) * k.deposit end);
end $$;

-- Vides rendus avec un bon de commande (avant la livraison) ; retirés du stock de vides à la réception
create or replace function public.gb_po_empties(p_po uuid, p_list jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; po public.purchase_orders; it jsonb; k public.packagings; res jsonb := '[]'::jsonb; q int;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pack(c.bid, c.srole);
  select * into po from public.purchase_orders where id = p_po and bar_id = c.bid for update;
  if not found or po.status <> 'envoye' then raise exception 'Bon de commande introuvable ou déjà traité.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_list, '[]')) loop
    q := coalesce((it->>'q')::int, 0); if q <= 0 then continue; end if;
    select * into k from public.packagings where id = (it->>'k')::uuid and bar_id = c.bid; if not found then raise exception 'Emballage introuvable.'; end if;
    res := res || jsonb_build_object('k', k.id, 'n', k.name, 'q', q, 'd', k.deposit, 'pc', k.per_crate);
  end loop;
  update public.purchase_orders set empties = res where id = po.id;
  return res;
end $$;

create or replace function gb_private.po_empties_out() returns trigger
language plpgsql security definer set search_path = '' as $$
declare it jsonb;
begin
  if new.status = 'recu' and old.status = 'envoye' then
    for it in select * from jsonb_array_elements(coalesce(new.empties, '[]')) loop
      insert into public.packaging_moves(bar_id, packaging_id, kind, qty, theo, po_id, note, created_by)
      select new.bar_id, k.id, 'retour', (it->>'q')::int, gb_private.pack_theo(k.id), new.id, 'Rendus avec le bon N°' || new.number, new.received_by
      from public.packagings k where k.id = (it->>'k')::uuid and k.bar_id = new.bar_id;
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists po_empties_out on public.purchase_orders;
create trigger po_empties_out after update of status on public.purchase_orders for each row execute function gb_private.po_empties_out();

revoke all on function public.gb_pack_save(uuid, text, int, int, uuid[], boolean), public.gb_pack_state(), public.gb_pack_move(uuid, text, int, text), public.gb_po_empties(uuid, jsonb) from public, anon;
grant execute on function public.gb_pack_save(uuid, text, int, int, uuid[], boolean), public.gb_pack_state(), public.gb_pack_move(uuid, text, int, text), public.gb_po_empties(uuid, jsonb) to authenticated;
