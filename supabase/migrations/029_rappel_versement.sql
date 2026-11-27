-- 029 : rappel automatique de versement des espèces (application fermée comprise).
-- Une serveuse qui a encaissé en espèces sans verser à la caisse reçoit un rappel ; si ça dure, la caisse puis le directeur sont prévenus.
-- Délais réglables par le PDG (bars.opts : remit_r1 / remit_r2 / remit_r3 en minutes, 20 / 45 / 90 par défaut, 0 = rappels coupés).
create extension if not exists pg_cron;

alter table public.bars add column if not exists opts jsonb not null default '{}'::jsonb;

-- Dernier niveau de rappel envoyé, par serveuse, pour le plus ancien encaissement non versé
create table if not exists gb_private.remit_alerts (
  staff_id uuid primary key references public.staff(id) on delete cascade,
  oldest timestamptz not null, level int not null, sent_at timestamptz not null default now());

create or replace function gb_private.remit_reminders() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; r1 int; r2 int; r3 int; lvl int; prev gb_private.remit_alerts; age int; n int := 0; amt text; ids uuid[];
begin
  -- encaissements versés entre-temps : on oublie le rappel
  delete from gb_private.remit_alerts a where not exists (select 1 from public.tickets t where t.waitress_id = a.staff_id and t.status = 'cashed' and t.pay_method = 'cash');
  for r in
    select t.bar_id, t.waitress_id, s.name, count(*) k, sum(coalesce(t.received, t.total))::int owed, min(coalesce(t.cashed_at, t.updated_at)) oldest, b.opts
    from public.tickets t join public.staff s on s.id = t.waitress_id join public.bars b on b.id = t.bar_id
    where t.status = 'cashed' and t.pay_method = 'cash' and s.role <> 'caisse' and not b.suspended
    group by t.bar_id, t.waitress_id, s.name, b.opts
  loop
    if gb_private.bar_block(r.bar_id) is not null then continue; end if;
    r1 := coalesce((r.opts->>'remit_r1')::int, 20); r2 := coalesce((r.opts->>'remit_r2')::int, 45); r3 := coalesce((r.opts->>'remit_r3')::int, 90);
    if r1 <= 0 then continue; end if;
    age := floor(extract(epoch from now() - r.oldest) / 60);
    lvl := case when r3 > 0 and age >= r3 then 3 when r2 > 0 and age >= r2 then 2 when age >= r1 then 1 else 0 end;
    if lvl = 0 then continue; end if;
    select * into prev from gb_private.remit_alerts where staff_id = r.waitress_id;
    if found and prev.oldest = r.oldest and prev.level >= lvl then continue; end if;
    amt := gb_private.fcfa(r.owed);
    perform gb_private.push(r.bar_id, array[r.waitress_id], '💵 Pensez à verser à la caisse',
      r.k || case when r.k > 1 then ' encaissements' else ' encaissement' end || ' en espèces non versé' || case when r.k > 1 then 's' else '' end || ' : ' || amt || ', depuis ' || age || ' min.', './?tab=service', 'verser');
    if lvl >= 2 then
      select array_agg(id) into ids from public.staff where bar_id = r.bar_id and active and role = 'caisse';
      perform gb_private.push(r.bar_id, ids, '⏳ Versement en retard', r.name || ' garde ' || amt || ' en espèces depuis ' || age || ' min.', './?tab=direct', 'retard-' || r.waitress_id);
    end if;
    if lvl >= 3 then
      select array_agg(id) into ids from public.staff where bar_id = r.bar_id and active and role = 'directeur';
      if ids is null then select array_agg(id) into ids from public.staff where bar_id = r.bar_id and active and role = 'pdg'; end if;
      perform gb_private.push(r.bar_id, ids, '⚠ Espèces non versées', r.name || ' n''a pas versé ' || amt || ' à la caisse depuis ' || age || ' min.', './', 'retard-' || r.waitress_id);
    end if;
    insert into gb_private.remit_alerts(staff_id, oldest, level, sent_at) values (r.waitress_id, r.oldest, lvl, now())
    on conflict (staff_id) do update set oldest = excluded.oldest, level = excluded.level, sent_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function gb_private.remit_reminders() from public, anon, authenticated;

-- Réglages du bar (PDG) : options regroupées ; seules les clés connues sont acceptées
create or replace function public.gb_bar_opts(p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; k text; v jsonb; o jsonb;
begin
  select * into c from gb_private.ctx();
  if c.srole <> 'pdg' then raise exception 'Seul le PDG modifie ces réglages.'; end if;
  if jsonb_typeof(coalesce(p_patch, '{}')) <> 'object' then raise exception 'Réglages invalides.'; end if;
  select opts into o from public.bars where id = c.bid;
  for k, v in select * from jsonb_each(p_patch) loop
    if k in ('remit_r1', 'remit_r2', 'remit_r3') then
      if jsonb_typeof(v) <> 'number' or (v::text)::int < 0 or (v::text)::int > 600 then raise exception 'Délai invalide (0 à 600 minutes).'; end if;
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
revoke all on function public.gb_bar_opts(jsonb) from public, anon;
grant execute on function public.gb_bar_opts(jsonb) to authenticated;

select cron.schedule('gesco-rappel-versement', '*/5 * * * *', 'select gb_private.remit_reminders()');
