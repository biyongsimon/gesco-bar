-- 023 : chacun son rôle en cuisine (seul le cuisinier commence, termine, sert un plat gardé ou décide d'un plat annulé ;
--       la caisse et la direction voient tout), commande payée close (plus de réouverture)
create or replace function public.gb_kitchen_step(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; o public.kitchen_orders;
begin
  select * into c from gb_private.ctx();
  select * into o from public.kitchen_orders where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Bon cuisine introuvable.'; end if;
  if o.status not in ('attente', 'prep', 'pret') then raise exception 'Ce bon n''est plus en cours.'; end if;
  if p_status = 'servi' then
    if o.waitress_id <> c.sid and not gb_private.is_head() then raise exception 'Seule la serveuse de la table (ou la cheffe de salle) récupère ce plat.'; end if;
    if o.status <> 'pret' then raise exception 'Le plat n''est pas encore prêt.'; end if;
    update public.kitchen_orders set status = 'servi', served_at = now() where id = p_id;
  elsif p_status in ('prep', 'pret', 'attente') then
    if c.srole <> 'cuisine' then raise exception 'Seule la cuisine indique qu''un plat est commencé ou prêt.'; end if;
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
  if c.srole <> 'cuisine' then raise exception 'C''est la cuisine qui décide du sort d''un plat annulé.'; end if;
  select * into o from public.kitchen_orders where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Bon cuisine introuvable.'; end if;
  if o.status not in ('a_decider', 'revente') then raise exception 'Ce plat n''attend pas de décision.'; end if;
  if p_choice not in ('revente', 'personnel', 'perte') then raise exception 'Choix inconnu.'; end if;
  select * into p from public.products where id = o.product_id;
  update public.kitchen_orders set status = p_choice, decided_at = now(), decided_by = c.sid,
    note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note) where id = p_id;
  perform gb_private.log(c.bid, c.sid, 'plat_' || p_choice, jsonb_build_object('plat', p.name, 'qte', o.qty, 'bon', o.bon, 'valeur', o.qty * coalesce(p.cost, 0), 'motif', p_note));
end $$;

create or replace function public.gb_kitchen_reuse(p_order uuid, p_kept uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; o public.kitchen_orders; k public.kitchen_orders; n int; pname text;
begin
  select * into c from gb_private.ctx();
  if c.srole <> 'cuisine' then raise exception 'Seule la cuisine sert un plat gardé.'; end if;
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

create or replace function gb_private.push_kitchen() returns trigger
language plpgsql security definer set search_path to '' as $$
declare p text; w text; cooks uuid[];
begin
  select name into p from public.products where id = new.product_id; select name into w from public.staff where id = new.waitress_id;
  cooks := gb_private.staff_of(new.bar_id, array['cuisine']);
  if tg_op = 'INSERT' and new.status = 'attente' then
    perform gb_private.push(new.bar_id, cooks, 'Nouvelle commande en cuisine', 'Bon ' || new.bon || ' · ' || new.qty || '× ' || p || ' · ' || coalesce(new.label, '') || ' · ' || coalesce(w, ''), './?tab=kitchen', 'k' || new.id);
    if exists (select 1 from public.kitchen_orders k where k.bar_id = new.bar_id and k.product_id = new.product_id and k.status = 'revente' and k.decided_at > now() - interval '6 hours') then
      perform gb_private.push(new.bar_id, cooks, '♻ Plat gardé disponible', new.qty || '× ' || p || ' pour ' || coalesce(new.label, 'une table') || ' : un plat identique est gardé.', './?tab=kitchen', 'g' || new.id);
    end if;
  elsif tg_op = 'UPDATE' and new.status = 'pret' and old.status <> 'pret' then
    perform gb_private.push(new.bar_id, array[new.waitress_id], 'Plat prêt en cuisine 🍽', new.qty || '× ' || p || ' · ' || coalesce(new.label, '') || ' · bon ' || new.bon || ' : allez le récupérer.', './?tab=service', 'r' || new.id);
  elsif tg_op = 'UPDATE' and new.status = 'a_decider' and old.status <> 'a_decider' then
    perform gb_private.push(new.bar_id, cooks, 'Plat annulé après préparation', new.qty || '× ' || p || ' · bon ' || new.bon || ' : revendre, repas du personnel ou perte ?', './?tab=kitchen', 'd' || new.id);
  end if;
  return null;
end $$;

create or replace function public.gb_ticket_reopen(p_ticket uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.status in ('cashed', 'paid') then raise exception 'Commande déjà payée : elle est close. Pour une nouvelle consommation, même à la même table, la serveuse ouvre un nouveau ticket. Erreur de saisie : supprimez le ticket (trace au journal) et refaites-le.'; end if;
  raise exception 'Seul un ticket encaissé pouvait être rouvert : cette fonction n''est plus utilisée.';
end $$;
