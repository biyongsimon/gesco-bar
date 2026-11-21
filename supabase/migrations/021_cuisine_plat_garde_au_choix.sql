-- 021 : le plat gardé n'est plus repris automatiquement ; le cuisinier est alerté et choisit « Servir le plat gardé ».
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

create or replace function public.gb_kitchen_reuse(p_order uuid, p_kept uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; o public.kitchen_orders; k public.kitchen_orders; n int; pname text;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine et à la caisse.'; end if;
  select * into o from public.kitchen_orders where id = p_order and bar_id = c.bid for update;
  if not found then raise exception 'Bon cuisine introuvable.'; end if;
  if o.status not in ('attente', 'prep') then raise exception 'Ce bon n''attend plus de préparation.'; end if;
  select * into k from public.kitchen_orders where id = p_kept and bar_id = c.bid and status = 'revente' and product_id = o.product_id
    and decided_at > now() - interval '6 hours' for update;
  if not found then raise exception 'Plat gardé introuvable ou gardé depuis plus de 6 h.'; end if;
  n := least(o.qty, k.qty);
  perform gb_private.kitchen_release(o.id, n, c.sid);   -- ces plats ne consomment pas de nouveaux ingrédients
  if n = k.qty then update public.kitchen_orders set status = 'reutilise' where id = k.id;
  else update public.kitchen_orders set qty = qty - n where id = k.id; end if;
  if n = o.qty then
    update public.kitchen_orders set status = 'pret', started_at = coalesce(started_at, now()), ready_at = now(), cook_id = c.sid,
      note = 'Plat gardé (bon ' || k.bon || ')' where id = o.id;
  else
    update public.kitchen_orders set qty = qty - n where id = o.id;
    insert into public.kitchen_orders(bar_id, ticket_id, product_id, waitress_id, label, ticket_no, bon, qty, status, started_at, ready_at, cook_id, note)
    values (o.bar_id, o.ticket_id, o.product_id, o.waitress_id, o.label, o.ticket_no, o.bon, n, 'pret', now(), now(), c.sid, 'Plat gardé (bon ' || k.bon || ')');
  end if;
  select name into pname from public.products where id = o.product_id;
  perform gb_private.log(c.bid, c.sid, 'plat_revendu', jsonb_build_object('plat', pname, 'qte', n, 'bon_garde', k.bon, 'bon', o.bon));
end $$;
revoke all on function public.gb_kitchen_reuse(uuid, uuid) from public, anon;
grant execute on function public.gb_kitchen_reuse(uuid, uuid) to authenticated;
