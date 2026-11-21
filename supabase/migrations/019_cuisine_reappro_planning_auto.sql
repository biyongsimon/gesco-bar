-- 019 : plats hors réapprovisionnement (leurs ingrédients comptent), coût des plats par la recette, planning automatique
CREATE OR REPLACE FUNCTION public.gb_reappro(p_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    cuis as (select r.ingredient_id product_id, sum(r.qty * k.qty)::numeric q from public.kitchen_orders k join public.recipes r on r.dish_id = k.product_id
      where k.bar_id = c.bid and k.status <> 'annule' and k.created_at > now() - make_interval(days => 14) group by 1),
    hold as (select product_id, sum(greatest(qty, 0)) q from public.holdings where bar_id = c.bid group by 1),
    base as (
      select p.id, p.name, p.stock, p.cost, coalesce(p.reorder_min, 0) mini, coalesce(h.q, 0) en_main,
        coalesce(s.q, 0) + coalesce(cu.q, 0) + coalesce((select sum(coalesce(s2.q, 0) / greatest(g.doses, 1)) from public.products g left join sold s2 on s2.product_id = g.id
                                     where g.parent_id = p.id), 0) vendu,
        coalesce((select sum(g.stock::numeric / greatest(g.doses, 1)) from public.products g where g.parent_id = p.id), 0) verres
      from public.products p left join sold s on s.product_id = p.id left join hold h on h.product_id = p.id left join cuis cu on cu.product_id = p.id
      where p.bar_id = c.bid and p.parent_id is null and p.active and p.category <> 'Cuisine' and not gb_private.is_dish(p.id))
    select jsonb_agg(jsonb_build_object('id', id, 'stock', stock, 'en_main', en_main, 'vendu', round(vendu, 1), 'min', mini,
      'par_jour', round(vendu / win, 2), 'dispo', round(stock + en_main + verres, 1),
      'jours', case when vendu > 0 then round((stock + en_main + verres) / (vendu / win), 1) end,
      'conseil', greatest(0, ceil(vendu / win * p_days + mini - (stock + en_main + verres)))::int, 'cout', cost) order by name)
    from base), '[]'::jsonb), 'fenetre', round(win, 1), 'jours_couverts', p_days);
end $function$;

-- Recette : le prix d'achat du plat = somme des ingrédients (marge et comptabilité justes)
create or replace function public.gb_recipe_set(p_dish uuid, p_items jsonb) returns void
language plpgsql security definer set search_path to '' as $$
declare c record; d public.products; it jsonb; q numeric; n int := 0; tot numeric;
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
  select round(sum(r.qty * coalesce(p.cost, 0))) into tot from public.recipes r join public.products p on p.id = r.ingredient_id where r.dish_id = p_dish;
  if coalesce(tot, 0) > 0 then update public.products set cost = tot where id = p_dish; end if;
  perform gb_private.log(c.bid, c.sid, 'recette_modifiee', jsonb_build_object('plat', d.name, 'ingredients', n, 'cout', tot));
end $$;
revoke all on function public.gb_recipe_set(uuid, jsonb) from public, anon; grant execute on function public.gb_recipe_set(uuid, jsonb) to authenticated;

-- Planning automatique
alter table public.bars add column if not exists plan_cfg jsonb;

-- Affluence moyenne (tickets par jour) du lundi au dimanche, sur 8 semaines
create or replace function public.gb_plan_load() returns jsonb
language plpgsql security definer set search_path to '' as $$
declare c record;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  return (with d as (
      select ((t.created_at at time zone 'Africa/Douala') - interval '6 hours')::date dd, count(*) n
      from public.tickets t where t.bar_id = c.bid and t.status <> 'cancelled' and t.created_at > now() - interval '56 days' group by 1)
    select jsonb_agg(coalesce((select round(avg(n), 1) from d where extract(isodow from dd) = i), 0) order by i) from generate_series(1, 7) i);
end $$;
revoke all on function public.gb_plan_load() from public, anon; grant execute on function public.gb_plan_load() to authenticated;

-- Enregistre en une fois la semaine proposée (remplace les cases des employés concernés)
create or replace function public.gb_shift_bulk(p_from date, p_items jsonb, p_cfg jsonb default null) returns int
language plpgsql security definer set search_path to '' as $$
declare c record; it jsonb; k text; dy date; n int := 0;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  if extract(isodow from p_from) <> 1 then raise exception 'La semaine doit commencer un lundi.'; end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_items, '[]'::jsonb)) > 400 then raise exception 'Planning invalide.'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) x where not exists (select 1 from public.staff s where s.id = (x->>'s')::uuid and s.bar_id = c.bid and s.active)) then
    raise exception 'Un employé du planning est introuvable.'; end if;
  delete from public.shifts where bar_id = c.bid and day between p_from and p_from + 6
    and staff_id in (select distinct (x->>'s')::uuid from jsonb_array_elements(p_items) x);
  for it in select * from jsonb_array_elements(p_items) loop
    k := it->>'k'; dy := (it->>'d')::date;
    if dy < p_from or dy > p_from + 6 then raise exception 'Jour hors de la semaine.'; end if;
    if k not in ('travail', 'repos') then raise exception 'Type de planning inconnu.'; end if;
    if k = 'travail' and (it->>'a' is null or it->>'b' is null) then raise exception 'Horaire incomplet.'; end if;
    insert into public.shifts(bar_id, staff_id, day, kind, start_time, end_time, note, updated_by)
    values (c.bid, (it->>'s')::uuid, dy, k, case when k = 'travail' then (it->>'a')::time end, case when k = 'travail' then (it->>'b')::time end,
            nullif(left(trim(coalesce(it->>'n', '')), 120), ''), c.sid)
    on conflict (staff_id, day) do update set kind = excluded.kind, start_time = excluded.start_time, end_time = excluded.end_time,
      note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
    n := n + 1;
  end loop;
  if p_cfg is not null and jsonb_typeof(p_cfg) = 'object' and length(p_cfg::text) < 4000 then update public.bars set plan_cfg = p_cfg where id = c.bid; end if;
  perform gb_private.log(c.bid, c.sid, 'planning_auto', jsonb_build_object('semaine', p_from, 'creneaux', n));
  return n;
end $$;
revoke all on function public.gb_shift_bulk(date, jsonb, jsonb) from public, anon; grant execute on function public.gb_shift_bulk(date, jsonb, jsonb) to authenticated;
