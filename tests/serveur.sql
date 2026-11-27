-- Tests des règles du serveur GesCo Bar, sur la vraie base, dans une transaction ANNULÉE à la fin :
-- un bar d'essai complet est créé, testé, puis tout disparaît (rien n'est envoyé, aucune donnée ne reste).
-- Lancement : psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f tests/serveur.sql   → doit finir par « TESTS_SERVEUR_OK ».
begin;

create function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$
begin if c is not true then raise exception 'ECHEC : %', m; end if; raise notice '  ✔ %', m; end $$;
-- Exécute une requête et renvoie le message d'erreur (ou 'OK')
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return 'OK'; exception when others then return sqlerrm; end $$;
create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true); end $$;

do $$
declare
  u_pdg uuid := gen_random_uuid(); u_srv uuid := gen_random_uuid(); u_cai uuid := gen_random_uuid(); u_cui uuid := gen_random_uuid();
  bar uuid; s_srv uuid; s_cai uuid; s_cui uuid; biere uuid; plat uuid; t1 uuid := gen_random_uuid(); t2 uuid := gen_random_uuid(); t3 uuid := gen_random_uuid();
  st text; total int; ko uuid; r jsonb; e text;
begin
  -- Bar d'essai : PDG, serveuse, caissière, cuisinier
  insert into auth.users(id, email, aud, role) values
    (u_pdg, u_pdg || '@test.gesco', 'authenticated', 'authenticated'), (u_srv, u_srv || '@test.gesco', 'authenticated', 'authenticated'),
    (u_cai, u_cai || '@test.gesco', 'authenticated', 'authenticated'), (u_cui, u_cui || '@test.gesco', 'authenticated', 'authenticated');
  perform public.gb_admin_create_bar(u_pdg, 'Bar des tests', 'Yaoundé', 'PDG Test', '1234');
  select s.bar_id into bar from public.staff s where s.user_id = u_pdg;
  perform pg_temp.ok(bar is not null, 'création d''un bar avec son PDG');
  update public.bars set plan = 'gold', plan_until = current_date + 30, kitchen_on = true, suspended = false where id = bar;
  s_srv := public.gb_admin_add_staff(u_pdg, u_srv, 'Serveuse Test', 'serveuse', '1111');
  s_cai := public.gb_admin_add_staff(u_pdg, u_cai, 'Caisse Test', 'caisse', '2222');
  s_cui := public.gb_admin_add_staff(u_pdg, u_cui, 'Cuisine Test', 'cuisine', '3333');
  insert into public.products(bar_id, name, category, price, stock) values (bar, 'Bière test', 'Bières', 600, 100) returning id into biere;
  insert into public.products(bar_id, name, category, price, stock, unit) values (bar, 'Plat test', 'Cuisine', 3000, 50, 'plat') returning id into plat;

  -- Ticket : la serveuse envoie, encaisse en espèces, la caisse reçoit le versement
  perform pg_temp.as_user(u_srv);
  perform public.gb_ticket_create(t1, 'Table test');
  perform public.gb_ticket_set_qty(t1, biere, 2);
  perform public.gb_ticket_send(t1);
  select status, tickets.total into st, total from public.tickets where id = t1;
  perform pg_temp.ok(st = 'sent' and total = 1200, 'la serveuse envoie la commande (2 × 600 = 1 200 FCFA)');
  perform public.gb_ticket_cash(t1, 'cash', 2000);
  perform pg_temp.ok((select status from public.tickets where id = t1) = 'cashed', 'la serveuse encaisse en espèces');
  perform pg_temp.as_user(u_cai);
  perform public.gb_remit(s_srv, 1200);
  perform pg_temp.ok((select status from public.tickets where id = t1) = 'paid', 'la caisse reçoit le versement : ticket payé');

  -- Commande payée = close
  e := pg_temp.err(format('select public.gb_ticket_reopen(%L)', t1));
  perform pg_temp.ok(e like 'Commande déjà payée%', 'une commande payée ne se rouvre pas');
  perform pg_temp.as_user(u_srv);
  e := pg_temp.err(format('select public.gb_ticket_set_qty(%L, %L, 3)', t1, biere));
  perform pg_temp.ok(e <> 'OK', 'on ne peut rien ajouter à une commande payée');

  -- La serveuse ne voit pas l'argent des autres : la caisse ne modifie pas la commande d'une serveuse
  perform pg_temp.as_user(u_cai);
  e := pg_temp.err(format('select public.gb_ticket_set_qty(%L, %L, 1)', t1, biere));
  perform pg_temp.ok(e <> 'OK', 'la caisse ne modifie jamais la commande d''une serveuse');

  -- Cuisine : seul le cuisinier fait avancer les bons
  perform pg_temp.as_user(u_srv);
  perform public.gb_ticket_create(t2, 'Table cuisine');
  perform public.gb_ticket_set_qty(t2, plat, 1);
  perform public.gb_ticket_send(t2);
  select id into ko from public.kitchen_orders where ticket_id = t2;
  perform pg_temp.ok(ko is not null, 'un plat envoyé crée un bon en cuisine');
  perform pg_temp.as_user(u_cai);
  e := pg_temp.err(format('select public.gb_kitchen_step(%L, %L)', ko, 'pret'));
  perform pg_temp.ok(e like 'Seule la cuisine%', 'la caisse ne peut pas marquer un plat prêt');
  perform pg_temp.as_user(u_pdg);
  e := pg_temp.err(format('select public.gb_kitchen_step(%L, %L)', ko, 'prep'));
  perform pg_temp.ok(e like 'Seule la cuisine%', 'le PDG ne peut pas faire avancer un bon');
  perform pg_temp.as_user(u_cui);
  perform public.gb_kitchen_step(ko, 'prep'); perform public.gb_kitchen_step(ko, 'pret');
  perform pg_temp.ok((select status from public.kitchen_orders where id = ko) = 'pret', 'le cuisinier commence puis termine le plat');
  e := pg_temp.err(format('select public.gb_kitchen_step(%L, %L)', ko, 'servi'));
  perform pg_temp.ok(e <> 'OK', 'le cuisinier ne confirme pas le retrait à la place de la serveuse');
  perform pg_temp.as_user(u_srv);
  perform public.gb_kitchen_step(ko, 'servi');
  perform pg_temp.ok((select status from public.kitchen_orders where id = ko) = 'servi', 'la serveuse de la table confirme le retrait');

  -- Plats payés et courses payées avec le tiroir : la clôture retire les courses des espèces attendues
  perform public.gb_ticket_cash(t2, 'cash', 3000);
  perform pg_temp.as_user(u_cai);
  perform public.gb_remit(s_srv, 3000);
  perform pg_temp.as_user(u_cui);
  e := pg_temp.err('select public.gb_market_add(''[{"a":"Tomates","m":1500}]''::jsonb, ''tiroir'')');
  perform pg_temp.ok(e like 'Seule la caisse%', 'le cuisinier ne peut pas prendre l''argent du tiroir');
  perform pg_temp.as_user(u_cai);
  perform public.gb_market_add('[{"a":"Tomates","q":"1 seau","m":1500}]'::jsonb, 'tiroir');
  perform pg_temp.ok((public.gb_market_list()->>'tiroir_jour')::int = 1500, 'les courses payées avec le tiroir sont comptées (1 500 FCFA)');
  r := public.gb_day_close(2700, false);
  perform pg_temp.ok((r->>'attendu')::int = 2700 and (r->>'ecart')::int = 0, 'espèces attendues = versements 4 200 − courses 1 500 = 2 700 FCFA');
  perform pg_temp.ok((r->'plats'->>'montant')::int = 3000 and (r->'plats'->>'qte')::int = 1 and (r->>'boissons')::int = 1200 and (r->>'depenses_caisse')::int = 1500,
    'le rapport de clôture sépare plats (3 000) et boissons (1 200)');

  -- Rappel de versement : 1er rappel à 20 min, caisse à 45, directeur à 90 (sans doublon)
  perform pg_temp.as_user(u_srv);
  perform public.gb_ticket_create(t3, 'Table rappel'); perform public.gb_ticket_set_qty(t3, biere, 1); perform public.gb_ticket_send(t3); perform public.gb_ticket_cash(t3, 'cash', 600);
  perform set_config('request.jwt.claims', '', true);
  update public.tickets set cashed_at = now() - interval '10 min' where id = t3; perform gb_private.remit_reminders();
  perform pg_temp.ok(not exists (select 1 from gb_private.remit_alerts where staff_id = s_srv), 'pas de rappel avant 20 minutes');
  update public.tickets set cashed_at = now() - interval '25 min' where id = t3; perform gb_private.remit_reminders(); perform gb_private.remit_reminders();
  perform pg_temp.ok((select level from gb_private.remit_alerts where staff_id = s_srv) = 1, 'rappel à la serveuse après 20 minutes');
  update public.tickets set cashed_at = now() - interval '95 min' where id = t3; perform gb_private.remit_reminders();
  perform pg_temp.ok((select level from gb_private.remit_alerts where staff_id = s_srv) = 3, 'directeur prévenu après 90 minutes');
  perform pg_temp.as_user(u_cai); perform public.gb_remit(s_srv, 600); perform gb_private.remit_reminders();
  perform pg_temp.ok(not exists (select 1 from gb_private.remit_alerts where staff_id = s_srv), 'le rappel s''arrête dès le versement');
  e := pg_temp.err('select public.gb_bar_opts(''{"remit_r1":5}'')');
  perform pg_temp.ok(e like 'Seul le PDG%', 'seul le PDG règle les rappels');
  perform pg_temp.as_user(u_pdg);
  e := pg_temp.err('select public.gb_bar_opts(''{"remit_r2":10}'')');
  perform pg_temp.ok(e like 'Les délais%', 'les délais doivent aller croissant');

  -- Abonnement : prix de test caché (1 mois, petit montant) puis effacé après paiement
  update public.bars set sub_test_price = 200 where id = bar;
  r := public.gb_admin_sub_push_start(u_pdg, 'gold', 12, 'mtn', '670000000');
  perform pg_temp.ok((r->>'amount')::int = 200, 'le prix de test remplace le prix normal (200 FCFA)');
  perform pg_temp.ok((select months from public.subscriptions where id = (r->>'id')::uuid) = 1, 'le prix de test donne 1 mois seulement');
  perform public.gb_admin_sub_push_done((r->>'id')::uuid, true, 'REF-TEST', null);
  perform pg_temp.ok((select sub_test_price is null and plan = 'gold' from public.bars where id = bar), 'après paiement réussi, le prix de test disparaît');

  -- Suspension : tout est bloqué, sauf la demande de réactivation du PDG
  update public.bars set suspended = true, suspend_reason = 'Test de suspension' where id = bar;
  perform pg_temp.as_user(u_srv);
  e := pg_temp.err(format('select public.gb_ticket_create(%L, %L)', gen_random_uuid(), 'Bloqué'));
  perform pg_temp.ok(e like 'ACCES_BLOQUE%', 'un bar suspendu ne peut plus créer de ticket');
  e := pg_temp.err('select public.gb_reactivation_send(''Svp'')');
  perform pg_temp.ok(e <> 'OK', 'une serveuse ne peut pas demander la réactivation');
  perform pg_temp.as_user(u_pdg);
  perform public.gb_reactivation_send('Nous avons payé', array[bar || '/reactivation-1-0.jpg'], '690000000');
  r := public.gb_reactivation_state();
  perform pg_temp.ok(r->>'reason' = 'Test de suspension' and r->'thread'->>'status' = 'transmis', 'le PDG envoie la demande de réactivation avec une preuve');
  e := pg_temp.err('select public.gb_reactivation_send(''x'', array[''autre-bar/reactivation-1-0.jpg''])');
  perform pg_temp.ok(e = 'Fichier non valide.', 'une preuve d''un autre bar est refusée');

  -- Isolation : un membre ne voit que son bar
  perform pg_temp.as_user(u_srv);
  execute 'set local role authenticated';
  select count(*) into total from public.bars;
  execute 'reset role';
  perform pg_temp.ok(total = 1, 'chaque compte ne voit que son propre bar (règles d''accès de la base)');
end $$;

-- Tout est annulé : aucune donnée de test ne reste
do $$ begin raise exception 'TESTS_SERVEUR_OK'; end $$;
