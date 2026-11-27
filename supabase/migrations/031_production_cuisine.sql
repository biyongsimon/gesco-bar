-- 031 : production de la cuisine et coût matière, jour par jour (cuisinier, directeur, PDG).
-- Plats sortis = bons prêts ou servis ; plats vendus = tickets payés ; coût matière = courses du marché / plats vendus.
create or replace function public.gb_kitchen_stats(p_days int default 7) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; n int := least(greatest(coalesce(p_days, 7), 1), 31); d1 date := gb_private.biz_date();
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('cuisine', 'pdg', 'directeur') then raise exception 'Réservé à la cuisine et à la direction.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('jour', g.d,
      'sortis', coalesce((select sum(k.qty) from public.kitchen_orders k join public.tickets t on t.id = k.ticket_id join public.service_days s on s.id = t.day_id
         where k.bar_id = c.bid and s.business_date = g.d and k.status in ('pret', 'servi')), 0),
      'pertes', coalesce((select sum(k.qty) from public.kitchen_orders k join public.tickets t on t.id = k.ticket_id join public.service_days s on s.id = t.day_id
         where k.bar_id = c.bid and s.business_date = g.d and k.status in ('perte', 'personnel')), 0),
      'vendus', coalesce((select sum(i.qty) from public.ticket_items i join public.tickets t on t.id = i.ticket_id join public.service_days s on s.id = t.day_id join public.products p on p.id = i.product_id
         where t.bar_id = c.bid and s.business_date = g.d and t.status in ('cashed', 'paid') and (p.category = 'Cuisine' or p.unit in ('plat', 'portion'))), 0),
      'montant', coalesce((select sum(i.qty * i.unit_price) from public.ticket_items i join public.tickets t on t.id = i.ticket_id join public.service_days s on s.id = t.day_id join public.products p on p.id = i.product_id
         where t.bar_id = c.bid and s.business_date = g.d and t.status in ('cashed', 'paid') and (p.category = 'Cuisine' or p.unit in ('plat', 'portion'))), 0),
      'courses', coalesce((select sum(e.amount) from public.expenses e where e.bar_id = c.bid and e.category = 'Courses du marché' and e.day = g.d), 0)) order by g.d desc)
    from (select (d1 - x)::date d from generate_series(0, n - 1) x) g), '[]'::jsonb);
end $$;
revoke all on function public.gb_kitchen_stats(int) from public, anon;
grant execute on function public.gb_kitchen_stats(int) to authenticated;
