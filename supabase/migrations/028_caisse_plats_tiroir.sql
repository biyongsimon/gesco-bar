-- 028 : la caissière ne suit plus la cuisine, elle suit l'argent des plats.
-- 1) Courses du marché payées avec l'argent du tiroir (« tiroir ») : retirées des espèces attendues,
--    à la relève comme à la clôture, pour que son comptage tombe juste.
-- 2) Le rapport de clôture sépare boissons et plats (montant, quantités, détail par plat).
alter table public.expenses drop constraint if exists expenses_method_check;
alter table public.expenses add constraint expenses_method_check check (method in ('cash', 'momo', 'banque', 'tiroir'));

-- Espèces sorties du tiroir pendant la journée ouverte
create or replace function gb_private.tiroir_out(p_bar uuid, p_since timestamptz) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(amount), 0)::int from public.expenses where bar_id = p_bar and method = 'tiroir' and created_at >= p_since $$;
revoke all on function gb_private.tiroir_out(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.gb_market_add(p_items jsonb, p_method text default 'cash') returns int
language plpgsql security definer set search_path = '' as $$
declare c record; it jsonb; n int := 0; tot int := 0; a text; m int; meth text;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine, la caisse et la direction.'; end if;
  meth := case when p_method in ('cash', 'momo', 'tiroir') then p_method else 'cash' end;
  if meth = 'tiroir' and c.srole not in ('caisse', 'pdg', 'directeur') then raise exception 'Seule la caisse peut payer avec l''argent du tiroir.'; end if;
  if meth = 'tiroir' and not exists (select 1 from public.service_days where bar_id = c.bid and status = 'open') then
    raise exception 'Aucune journée de service ouverte : le tiroir n''a pas encore d''espèces.'; end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 60 then raise exception 'Ajoutez au moins un article.'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    a := left(trim(coalesce(it->>'a', '')), 60); m := (it->>'m')::int;
    if a = '' then raise exception 'Indiquez l''article acheté.'; end if;
    if m is null or m <= 0 then raise exception 'Indiquez le montant de « % ».', a; end if;
    insert into public.expenses(bar_id, day, category, label, amount, method, created_by)
    values (c.bid, gb_private.biz_date(), 'Courses du marché', a || coalesce(' · ' || nullif(left(trim(coalesce(it->>'q', '')), 40), ''), ''), m, meth, c.sid);
    n := n + 1; tot := tot + m;
  end loop;
  perform gb_private.log(c.bid, c.sid, 'courses_marche', jsonb_build_object('articles', n, 'total', tot, 'tiroir', meth = 'tiroir'));
  return n;
end $$;

create or replace function public.gb_market_list(p_day date default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; dd date := coalesce(p_day, gb_private.biz_date()); d public.service_days;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine, la caisse et la direction.'; end if;
  select * into d from public.service_days where bar_id = c.bid and status = 'open';
  return jsonb_build_object('day', dd, 'items', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'label', e.label, 'amount', e.amount, 'method', e.method,
      'by', (select name from public.staff where id = e.created_by), 'at', e.created_at) order by e.created_at)
    from public.expenses e where e.bar_id = c.bid and e.category = 'Courses du marché' and e.day = dd), '[]'::jsonb),
    'week', (select coalesce(sum(amount), 0) from public.expenses where bar_id = c.bid and category = 'Courses du marché' and day > dd - 7 and day <= dd),
    'tiroir_jour', case when d.id is null then 0 else gb_private.tiroir_out(c.bid, d.opened_at) end);
end $$;

-- Retrait d'un achat payé avec le tiroir : seulement pendant la journée ouverte (sinon la clôture ne correspondrait plus)
create or replace function public.gb_market_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; e public.expenses; d public.service_days;
begin
  select * into c from gb_private.ctx();
  select * into e from public.expenses where id = p_id and bar_id = c.bid and category = 'Courses du marché';
  if not found then raise exception 'Achat introuvable.'; end if;
  if not (c.srole in ('caisse', 'pdg') or e.created_by = c.sid) then raise exception 'Seule la personne qui l''a saisi ou la caisse peut le retirer.'; end if;
  if e.day < gb_private.biz_date() and c.srole <> 'pdg' then raise exception 'Seul le PDG corrige les achats des jours passés.'; end if;
  if e.method = 'tiroir' then
    select * into d from public.service_days where bar_id = c.bid and status = 'open';
    if d.id is null or e.created_at < d.opened_at then raise exception 'Cet achat payé avec le tiroir appartient à une journée clôturée : il ne peut plus être retiré.'; end if;
  end if;
  delete from public.expenses where id = p_id;
  perform gb_private.log(c.bid, c.sid, 'courses_retirees', jsonb_build_object('article', e.label, 'montant', e.amount));
end $$;

create or replace function public.gb_handover(p_counted integer, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; d public.service_days; t0 timestamptz; prev public.cash_handovers; sales int; momo int; cash_all int; change_all int; cash_in int; nt int; exp int; s jsonb; nid uuid; tir_all int; tir int;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if p_counted is null or p_counted < 0 then raise exception 'Saisissez les espèces comptées dans la caisse.'; end if;
  select * into d from public.service_days where bar_id = c.bid and status = 'open';
  if not found then raise exception 'Aucune journée de service ouverte.'; end if;
  if exists (select 1 from public.cash_handovers where day_id = d.id and confirmed_at is null) then
    raise exception 'Une relève attend déjà la confirmation de la caisse suivante.'; end if;
  select * into prev from public.cash_handovers where day_id = d.id order by created_at desc limit 1;
  t0 := coalesce(prev.created_at, d.opened_at);
  select coalesce(sum(total) filter (where status in ('cashed', 'paid') and coalesce(cashed_at, paid_at, updated_at) >= t0), 0),
         coalesce(sum(total) filter (where status = 'paid' and pay_method = 'momo' and coalesce(paid_at, updated_at) >= t0), 0),
         count(*) filter (where status in ('cashed', 'paid') and coalesce(cashed_at, paid_at, updated_at) >= t0),
         coalesce(sum(change_due) filter (where change_status = 'given'), 0)
    into sales, momo, nt, change_all from public.tickets where day_id = d.id;
  select coalesce(sum(received), 0), coalesce(sum(received) filter (where created_at >= t0), 0) into cash_all, cash_in from public.remittances where day_id = d.id;
  tir_all := gb_private.tiroir_out(c.bid, d.opened_at); tir := gb_private.tiroir_out(c.bid, t0);
  exp := cash_all - change_all - tir_all;
  s := jsonb_build_object('ventes', sales, 'tickets', nt, 'mobile_money', momo, 'especes_versees', cash_in, 'depenses_caisse', tir, 'attendu', exp, 'compte', p_counted,
    'ecart', p_counted - exp, 'ecart_service', (p_counted - exp) - coalesce(prev.diff, 0), 'debut', t0, 'fin', now(),
    'serveuses', coalesce((select jsonb_agg(jsonb_build_object('nom', st.name, 'ventes', x.v, 'tickets', x.n) order by st.name)
      from (select waitress_id, sum(total) v, count(*) n from public.tickets where day_id = d.id and status in ('cashed', 'paid') and coalesce(cashed_at, paid_at, updated_at) >= t0 group by 1) x
      join public.staff st on st.id = x.waitress_id), '[]'::jsonb));
  insert into public.cash_handovers(bar_id, day_id, from_staff, period_start, counted, expected, diff, summary, note)
  values (c.bid, d.id, c.sid, t0, p_counted, exp, p_counted - exp, s, nullif(trim(coalesce(p_note, '')), '')) returning id into nid;
  perform gb_private.log(c.bid, c.sid, 'releve_caisse', jsonb_build_object('ventes', sales, 'compte', p_counted, 'ecart_service', s->'ecart_service'));
  return s || jsonb_build_object('id', nid);
end $$;

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
