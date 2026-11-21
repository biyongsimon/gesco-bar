-- 020 : cheffe de salle et transfert de tables, relève de caisse (jour / nuit), plats annulés après préparation
--       (revendre / repas du personnel / perte), courses du marché

-- ───────── Cheffe de salle
alter table public.staff add column if not exists head boolean not null default false;

create or replace function gb_private.is_head() returns boolean
language sql stable security definer set search_path to '' as $$
  select coalesce((select s.head and s.role = 'serveuse' from public.staff s where s.user_id = (select auth.uid()) and s.active), false)
$$;
grant execute on function gb_private.is_head() to authenticated;

drop policy if exists tickets_read on public.tickets;
create policy tickets_read on public.tickets for select to authenticated using (
  bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or (select gb_private.is_head()) or waitress_id = (select gb_private.me())));
drop policy if exists items_read on public.ticket_items;
create policy items_read on public.ticket_items for select to authenticated using (
  bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or (select gb_private.is_head())
    or exists (select 1 from public.tickets t where t.id = ticket_items.ticket_id and t.waitress_id = (select gb_private.me()))));
drop policy if exists ko_read on public.kitchen_orders;
create policy ko_read on public.kitchen_orders for select to authenticated using (
  bar_id = (select gb_private.bar()) and ((select gb_private.is_caisse()) or (select gb_private.my_role()) = 'cuisine'
    or (select gb_private.is_head()) or waitress_id = (select gb_private.me())));

create or replace function public.gb_staff_head(p_staff uuid, p_on boolean) returns void
language plpgsql security definer set search_path to '' as $$
declare c record; s public.staff;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into s from public.staff where id = p_staff and bar_id = c.bid and active;
  if not found then raise exception 'Membre introuvable.'; end if;
  if coalesce(p_on, false) and s.role <> 'serveuse' then raise exception 'Seule une serveuse peut être cheffe de salle.'; end if;
  update public.staff set head = coalesce(p_on, false) where id = p_staff;
  perform gb_private.log(c.bid, c.sid, 'cheffe_de_salle', jsonb_build_object('nom', s.name, 'active', coalesce(p_on, false)));
end $$;

-- Confier une table : la cheffe de salle (prendre ou affecter), la caisse / direction, ou la serveuse elle-même (relève)
create or replace function public.gb_ticket_transfer(p_ticket uuid, p_to uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare c record; t public.tickets; d public.staff; f text;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.status not in ('draft', 'sent') then raise exception 'Cette table est déjà encaissée : la serveuse verse d''abord l''argent à la caisse.'; end if;
  select * into d from public.staff where id = p_to and bar_id = c.bid and active and role = 'serveuse';
  if not found then raise exception 'Serveuse introuvable.'; end if;
  if d.id = t.waitress_id then raise exception 'Cette table est déjà à %.', d.name; end if;
  if not (c.srole in ('caisse', 'directeur', 'pdg') or gb_private.is_head() or t.waitress_id = c.sid) then
    raise exception 'Seules la cheffe de salle, la caisse ou la serveuse de la table peuvent la confier.'; end if;
  select name into f from public.staff where id = t.waitress_id;
  update public.tickets set waitress_id = p_to, updated_at = now() where id = p_ticket;
  update public.kitchen_orders set waitress_id = p_to where ticket_id = p_ticket and status in ('attente', 'prep', 'pret');
  perform gb_private.log(c.bid, c.sid, 'table_transferee', jsonb_build_object('ticket', t.number, 'client', t.client_label, 'de', f, 'vers', d.name));
end $$;

-- ───────── Relève de caisse (services jour / nuit dans la même journée)
create table if not exists public.cash_handovers (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  day_id uuid not null references public.service_days(id) on delete cascade,
  from_staff uuid not null references public.staff(id),
  to_staff uuid references public.staff(id),
  period_start timestamptz not null,
  counted int not null, expected int not null, diff int not null,
  summary jsonb, note text,
  created_at timestamptz not null default now(), confirmed_at timestamptz);
create index if not exists cash_handovers_day on public.cash_handovers(day_id, created_at);
alter table public.cash_handovers enable row level security;
drop policy if exists handovers_read on public.cash_handovers;
create policy handovers_read on public.cash_handovers for select to authenticated using (bar_id = (select gb_private.bar()) and (select gb_private.is_caisse()));
do $$ begin alter publication supabase_realtime add table public.cash_handovers; exception when others then null; end $$;

create or replace function public.gb_handover(p_counted integer, p_note text default null) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare c record; d public.service_days; t0 timestamptz; prev public.cash_handovers; sales int; momo int; cash_all int; change_all int; cash_in int; nt int; exp int; s jsonb; nid uuid;
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
  exp := cash_all - change_all;   -- l'argent reste dans le tiroir : attendu cumulé depuis l'ouverture
  s := jsonb_build_object('ventes', sales, 'tickets', nt, 'mobile_money', momo, 'especes_versees', cash_in, 'attendu', exp, 'compte', p_counted,
    'ecart', p_counted - exp, 'ecart_service', (p_counted - exp) - coalesce(prev.diff, 0), 'debut', t0, 'fin', now(),
    'serveuses', coalesce((select jsonb_agg(jsonb_build_object('nom', st.name, 'ventes', x.v, 'tickets', x.n) order by st.name)
      from (select waitress_id, sum(total) v, count(*) n from public.tickets where day_id = d.id and status in ('cashed', 'paid') and coalesce(cashed_at, paid_at, updated_at) >= t0 group by 1) x
      join public.staff st on st.id = x.waitress_id), '[]'::jsonb));
  insert into public.cash_handovers(bar_id, day_id, from_staff, period_start, counted, expected, diff, summary, note)
  values (c.bid, d.id, c.sid, t0, p_counted, exp, p_counted - exp, s, nullif(trim(coalesce(p_note, '')), '')) returning id into nid;
  perform gb_private.log(c.bid, c.sid, 'releve_caisse', jsonb_build_object('ventes', sales, 'compte', p_counted, 'ecart_service', s->'ecart_service'));
  return s || jsonb_build_object('id', nid);
end $$;

create or replace function public.gb_handover_confirm(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare c record; h public.cash_handovers;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into h from public.cash_handovers where id = p_id and bar_id = c.bid and confirmed_at is null for update;
  if not found then raise exception 'Relève introuvable ou déjà confirmée.'; end if;
  if h.from_staff = c.sid and c.srole = 'caisse' then raise exception 'C''est la caissière qui prend le service qui confirme la relève.'; end if;
  update public.cash_handovers set to_staff = c.sid, confirmed_at = now() where id = p_id;
  perform gb_private.log(c.bid, c.sid, 'releve_confirmee', jsonb_build_object('fond_de_caisse', h.counted));
end $$;

-- Départ d'une serveuse : pas de table ouverte ni d'argent non versé
create or replace function public.gb_clock_out() returns void
language plpgsql security definer set search_path to '' as $$
declare c record; d date := gb_private.biz_date(); n_open int; n_cash int;
begin
  select * into c from gb_private.ctx();
  if c.srole = 'serveuse' then
    select count(*) filter (where status in ('draft', 'sent') and total > 0), count(*) filter (where status = 'cashed')
      into n_open, n_cash from public.tickets where waitress_id = c.sid and status in ('draft', 'sent', 'cashed');
    if n_open > 0 or n_cash > 0 then
      raise exception '%', 'Avant de partir : '
        || case when n_open > 0 then 'confiez vos ' || n_open || ' table(s) encore ouverte(s) à une autre serveuse' else '' end
        || case when n_cash > 0 then (case when n_open > 0 then ', puis ' else '' end) || 'versez l''argent de ' || n_cash || ' ticket(s) à la caisse' else '' end || '.';
    end if;
  end if;
  update public.attendance set left_at = now(), updated_at = now() where staff_id = c.sid and day = d and arrived_at is not null;
  if not found then raise exception 'Pointez d''abord votre arrivée.'; end if;
end $$;

-- Clôture : le bilan de la journée reprend chaque service (relèves)
create or replace function public.gb_day_close(p_counted integer, p_force boolean)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
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
end $function$;

-- ───────── Cuisine : un plat commencé ne revient jamais en stock ; on décide de son sort
alter table public.kitchen_orders drop constraint if exists kitchen_orders_status_check;
alter table public.kitchen_orders add constraint kitchen_orders_status_check
  check (status in ('attente', 'prep', 'pret', 'servi', 'annule', 'a_decider', 'revente', 'reutilise', 'personnel', 'perte'));
alter table public.kitchen_orders add column if not exists note text, add column if not exists decided_at timestamptz, add column if not exists decided_by uuid;

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
    if o.status = 'attente' then
      perform gb_private.kitchen_release(o.id, o.qty, p_staff);
      update public.kitchen_orders set status = 'annule' where id = o.id;
    else
      update public.kitchen_orders set status = 'a_decider', note = 'Table annulée' where id = o.id;
    end if;
  end loop;
  update public.vouchers set status = 'void' where ticket_id = p_ticket and status = 'active';
  update public.tickets set status = 'cancelled', cancel_requested = false, updated_at = now() where id = p_ticket;
  perform gb_private.log(t.bar_id, p_staff, 'ticket_supprime',
    jsonb_build_object('ticket', t.number, 'client', t.client_label, 'total', t.total, 'statut_avant', t.status));
end $$;

-- Un plat mis en revente (moins de 6 h) sert d'abord la commande suivante du même plat : prêt tout de suite, sans ingrédients
create or replace function gb_private.kitchen_take(p_ticket uuid, p_product uuid, p_qty int, p_sid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tickets; n int; r record; q int; left_q int := coalesce(p_qty, 0); rv record; k int;
begin
  if left_q <= 0 then return; end if;
  select * into t from public.tickets where id = p_ticket;
  for rv in select * from public.kitchen_orders where bar_id = t.bar_id and product_id = p_product and status = 'revente'
              and decided_at > now() - interval '6 hours' order by decided_at for update loop
    exit when left_q <= 0;
    k := least(rv.qty, left_q);
    if k = rv.qty then update public.kitchen_orders set status = 'reutilise' where id = rv.id;
    else update public.kitchen_orders set qty = qty - k where id = rv.id; end if;
    update public.bars set next_bon = next_bon + 1 where id = t.bar_id returning next_bon - 1 into n;
    insert into public.kitchen_orders(bar_id, ticket_id, product_id, waitress_id, label, ticket_no, bon, qty, status, started_at, ready_at, note)
    values (t.bar_id, t.id, p_product, t.waitress_id, t.client_label, t.number, n, k, 'pret', now(), now(), 'Plat déjà prêt (revente du bon ' || rv.bon || ')');
    left_q := left_q - k;
  end loop;
  if left_q <= 0 then return; end if;
  update public.bars set next_bon = next_bon + 1 where id = t.bar_id returning next_bon - 1 into n;
  insert into public.kitchen_orders(bar_id, ticket_id, product_id, waitress_id, label, ticket_no, bon, qty)
  values (t.bar_id, t.id, p_product, t.waitress_id, t.client_label, t.number, n, left_q);
  for r in select ingredient_id, qty from public.recipes where dish_id = p_product loop
    q := ceil(r.qty * left_q)::int;
    update public.products set stock = stock - q where id = r.ingredient_id;
    insert into public.stock_moves(bar_id, product_id, qty, kind, created_by) values (t.bar_id, r.ingredient_id, -q, 'cuisine', p_sid);
  end loop;
end $$;

create or replace function public.gb_kitchen_step(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; o public.kitchen_orders;
begin
  select * into c from gb_private.ctx();
  select * into o from public.kitchen_orders where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Bon cuisine introuvable.'; end if;
  if o.status not in ('attente', 'prep', 'pret') then raise exception 'Ce bon n''est plus en cours.'; end if;
  if p_status = 'servi' then
    if o.waitress_id <> c.sid and c.srole not in ('caisse', 'pdg', 'directeur') and not gb_private.is_head() then raise exception 'Seule la serveuse de la table récupère ce plat.'; end if;
    if o.status <> 'pret' then raise exception 'Le plat n''est pas encore prêt.'; end if;
    update public.kitchen_orders set status = 'servi', served_at = now() where id = p_id;
  elsif p_status in ('prep', 'pret', 'attente') then
    if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine.'; end if;
    update public.kitchen_orders set status = p_status,
      started_at = case when p_status in ('prep', 'pret') then coalesce(started_at, now()) else null end,
      ready_at = case when p_status = 'pret' then now() else null end, cook_id = c.sid where id = p_id;
  else raise exception 'Étape inconnue.'; end if;
end $$;

create or replace function public.gb_kitchen_decide(p_id uuid, p_choice text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; o public.kitchen_orders; p public.products;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine et à la caisse.'; end if;
  select * into o from public.kitchen_orders where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Bon cuisine introuvable.'; end if;
  if o.status not in ('a_decider', 'revente') then raise exception 'Ce plat n''attend pas de décision.'; end if;
  if p_choice not in ('revente', 'personnel', 'perte') then raise exception 'Choix inconnu.'; end if;
  select * into p from public.products where id = o.product_id;
  update public.kitchen_orders set status = p_choice, decided_at = now(), decided_by = c.sid,
    note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note) where id = p_id;
  perform gb_private.log(c.bid, c.sid, 'plat_' || p_choice, jsonb_build_object('plat', p.name, 'qte', o.qty, 'bon', o.bon, 'valeur', o.qty * coalesce(p.cost, 0), 'motif', p_note));
end $$;

-- ───────── Courses du marché (achats en gros : dépenses de la compta, sans déduction au gramme)
create or replace function public.gb_market_add(p_items jsonb, p_method text default 'cash') returns int
language plpgsql security definer set search_path = '' as $$
declare c record; it jsonb; n int := 0; tot int := 0; a text; m int;
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine, la caisse et la direction.'; end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 60 then raise exception 'Ajoutez au moins un article.'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    a := left(trim(coalesce(it->>'a', '')), 60); m := (it->>'m')::int;
    if a = '' then raise exception 'Indiquez l''article acheté.'; end if;
    if m is null or m <= 0 then raise exception 'Indiquez le montant de « % ».', a; end if;
    insert into public.expenses(bar_id, day, category, label, amount, method, created_by)
    values (c.bid, gb_private.biz_date(), 'Courses du marché', a || coalesce(' · ' || nullif(left(trim(coalesce(it->>'q', '')), 40), ''), ''), m,
            case when p_method in ('cash', 'momo') then p_method else 'cash' end, c.sid);
    n := n + 1; tot := tot + m;
  end loop;
  perform gb_private.log(c.bid, c.sid, 'courses_marche', jsonb_build_object('articles', n, 'total', tot));
  return n;
end $$;

create or replace function public.gb_market_list(p_day date default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; dd date := coalesce(p_day, gb_private.biz_date());
begin
  select * into c from gb_private.ctx();
  if c.srole not in ('cuisine', 'caisse', 'pdg', 'directeur') then raise exception 'Action réservée à la cuisine, la caisse et la direction.'; end if;
  return jsonb_build_object('day', dd, 'items', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'label', e.label, 'amount', e.amount, 'method', e.method,
      'by', (select name from public.staff where id = e.created_by), 'at', e.created_at) order by e.created_at)
    from public.expenses e where e.bar_id = c.bid and e.category = 'Courses du marché' and e.day = dd), '[]'::jsonb),
    'week', (select coalesce(sum(amount), 0) from public.expenses where bar_id = c.bid and category = 'Courses du marché' and day > dd - 7 and day <= dd));
end $$;

create or replace function public.gb_market_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; e public.expenses;
begin
  select * into c from gb_private.ctx();
  select * into e from public.expenses where id = p_id and bar_id = c.bid and category = 'Courses du marché';
  if not found then raise exception 'Achat introuvable.'; end if;
  if not (c.srole in ('caisse', 'pdg') or e.created_by = c.sid) then raise exception 'Seule la personne qui l''a saisi ou la caisse peut le retirer.'; end if;
  if e.day < gb_private.biz_date() and c.srole <> 'pdg' then raise exception 'Seul le PDG corrige les achats des jours passés.'; end if;
  delete from public.expenses where id = p_id;
  perform gb_private.log(c.bid, c.sid, 'courses_retirees', jsonb_build_object('article', e.label, 'montant', e.amount));
end $$;

revoke all on function public.gb_staff_head(uuid, boolean), public.gb_ticket_transfer(uuid, uuid), public.gb_handover(integer, text), public.gb_handover_confirm(uuid),
  public.gb_kitchen_decide(uuid, text, text), public.gb_market_add(jsonb, text), public.gb_market_list(date), public.gb_market_delete(uuid) from public, anon;
grant execute on function public.gb_staff_head(uuid, boolean), public.gb_ticket_transfer(uuid, uuid), public.gb_handover(integer, text), public.gb_handover_confirm(uuid),
  public.gb_kitchen_decide(uuid, text, text), public.gb_market_add(jsonb, text), public.gb_market_list(date), public.gb_market_delete(uuid) to authenticated;
