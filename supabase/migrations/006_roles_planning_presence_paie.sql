-- GesCo Bar · v3 : PDG, Directeur, Caissière, Serveuse ; planning, présences, permissions, paie, suivi du service

-- ───────── 1. Rôles ─────────
alter table public.staff drop constraint staff_role_check;
alter table public.staff add constraint staff_role_check check (role in ('pdg','directeur','caisse','serveuse'));
alter table public.staff add column phone text;
update public.staff s set role = 'pdg' from public.bars b where b.id = s.bar_id and s.user_id = b.owner_user;
create unique index staff_one_pdg on public.staff(bar_id) where role = 'pdg' and active;

create or replace function gb_private.role() returns text
language sql stable security definer set search_path = '' as $$
  select s.role from public.staff s where s.user_id = (select auth.uid()) and s.active
$$;
-- « voit toutes les opérations du bar » : caisse, directeur, PDG
create or replace function gb_private.is_caisse() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.role in ('caisse','directeur','pdg') from public.staff s where s.user_id = (select auth.uid()) and s.active), false)
$$;
create or replace function gb_private.is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.role in ('directeur','pdg') from public.staff s where s.user_id = (select auth.uid()) and s.active), false)
$$;
create or replace function gb_private.is_pdg() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.role = 'pdg' from public.staff s where s.user_id = (select auth.uid()) and s.active), false)
$$;
grant execute on function gb_private.role(), gb_private.is_manager(), gb_private.is_pdg() to authenticated;

create or replace function gb_private.need_caisse(r text) returns void
language plpgsql set search_path = '' as $$
begin
  if r is null or r not in ('caisse','pdg') then raise exception 'Action réservée à la caisse.' using errcode = '42501'; end if;
end $$;
create or replace function gb_private.need_pdg(r text) returns void
language plpgsql set search_path = '' as $$
begin
  if r is distinct from 'pdg' then raise exception 'Action réservée au PDG.' using errcode = '42501'; end if;
end $$;
create or replace function gb_private.need_manager(r text) returns void
language plpgsql set search_path = '' as $$
begin
  if r is null or r not in ('directeur','pdg') then raise exception 'Action réservée au directeur ou au PDG.' using errcode = '42501'; end if;
end $$;

-- Compta, revenus, réglages et identité : PDG uniquement
do $$
declare r record; d text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('gb_accounting','gb_bar_identity','gb_bar_update','gb_expense_add','gb_expense_delete','gb_revenue') loop
    d := replace(pg_get_functiondef(r.oid), 'gb_private.need_caisse(c.srole)', 'gb_private.need_pdg(c.srole)');
    execute d;
  end loop;
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'gb_ticket_delete';
  execute replace(d, 'if c.srole = ''caisse'' then', 'if c.srole in (''caisse'',''pdg'') then');
end $$;

-- Équipe : le directeur gère caissières et serveuses, le PDG gère tout le monde
create or replace function public.gb_staff_update(p_staff uuid, p_name text, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; s public.staff; busy int; nr text;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into s from public.staff where id = p_staff and bar_id = c.bid for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  nr := coalesce(p_role, s.role);
  if p_staff = c.sid and (coalesce(p_active, true) = false or nr <> s.role) then
    raise exception 'Vous ne pouvez ni changer votre propre rôle ni vous désactiver.';
  end if;
  if c.srole = 'directeur' and p_staff <> c.sid and (s.role in ('pdg','directeur') or nr in ('pdg','directeur')) then
    raise exception 'Seul le PDG peut gérer un directeur.';
  end if;
  if s.role = 'pdg' and p_staff <> c.sid then raise exception 'Le compte du PDG ne peut être modifié que par lui-même.'; end if;
  if nr = 'pdg' and s.role <> 'pdg' then raise exception 'Il ne peut y avoir qu''un seul PDG.'; end if;
  if coalesce(p_active, true) = false and s.active then
    select count(*) into busy from public.tickets where waitress_id = p_staff and status in ('draft','sent','cashed');
    if busy > 0 then raise exception '% a encore % ticket(s) non soldé(s).', s.name, busy; end if;
    if exists (select 1 from public.holdings where waitress_id = p_staff and qty <> 0) then
      raise exception 'Reprenez d''abord les bouteilles en main de %.', s.name;
    end if;
  end if;
  update public.staff set name = coalesce(nullif(trim(p_name), ''), name), role = nr, active = coalesce(p_active, active) where id = p_staff;
  perform gb_private.log(c.bid, c.sid, 'equipe_modifiee', jsonb_build_object('membre', s.name, 'nom', coalesce(nullif(trim(p_name), ''), s.name), 'role', nr, 'actif', coalesce(p_active, s.active)));
exception when unique_violation then
  raise exception 'Ce nom est déjà utilisé dans l''équipe.';
end $$;

create or replace function public.gb_staff_set_pin(p_staff uuid, p_pin text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; s public.staff;
begin
  select * into c from gb_private.ctx();
  select * into s from public.staff where id = p_staff and bar_id = c.bid;
  if not found then raise exception 'Membre introuvable.'; end if;
  if p_staff <> c.sid then
    perform gb_private.need_manager(c.srole);
    if c.srole = 'directeur' and s.role in ('pdg','directeur') then raise exception 'Seul le PDG peut changer le PIN d''un directeur.'; end if;
    if s.role = 'pdg' then raise exception 'Le PIN du PDG ne peut être changé que par lui-même.'; end if;
  end if;
  perform gb_private.check_pin_format(p_pin);
  insert into gb_private.staff_pins(staff_id, pin_hash) values (p_staff, extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null;
  perform gb_private.log(c.bid, c.sid, 'pin_change', jsonb_build_object('membre', s.name));
end $$;

-- Création du bar : le créateur est PDG
create or replace function public.gb_admin_create_bar(p_user uuid, p_bar_name text, p_city text, p_owner_name text, p_pin text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b uuid; s uuid; k text;
begin
  perform gb_private.check_pin_format(p_pin);
  if nullif(trim(p_bar_name), '') is null then raise exception 'Indiquez le nom du bar.'; end if;
  if nullif(trim(p_owner_name), '') is null then raise exception 'Indiquez votre nom.'; end if;
  loop
    k := gb_private.rand_code(6);
    exit when not exists (select 1 from public.bars where code = k);
  end loop;
  insert into public.bars(name, code, city, owner_user) values (trim(p_bar_name), k, nullif(trim(p_city), ''), p_user) returning id into b;
  insert into public.staff(bar_id, user_id, name, role) values (b, p_user, trim(p_owner_name), 'pdg') returning id into s;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (s, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  perform gb_private.seed_products(b);
  perform gb_private.log(b, s, 'bar_cree', jsonb_build_object('nom', trim(p_bar_name)));
  return jsonb_build_object('bar_id', b, 'code', k, 'staff_id', s);
end $$;

create or replace function public.gb_admin_add_staff(p_caller uuid, p_user uuid, p_name text, p_role text, p_pin text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.staff; s uuid;
begin
  select * into c from public.staff where user_id = p_caller and active and role in ('pdg','directeur');
  if not found then raise exception 'Seuls le directeur et le PDG ajoutent des membres.'; end if;
  perform gb_private.check_pin_format(p_pin);
  if nullif(trim(p_name), '') is null then raise exception 'Indiquez un nom.'; end if;
  if p_role not in ('directeur','caisse','serveuse') then raise exception 'Rôle inconnu.'; end if;
  if p_role = 'directeur' and c.role <> 'pdg' then raise exception 'Seul le PDG peut ajouter un directeur.'; end if;
  insert into public.staff(bar_id, user_id, name, role) values (c.bar_id, p_user, trim(p_name), p_role) returning id into s;
  insert into gb_private.staff_pins(staff_id, pin_hash) values (s, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  perform gb_private.log(c.bar_id, c.id, 'membre_ajoute', jsonb_build_object('membre', trim(p_name), 'role', p_role));
  return s;
exception when unique_violation then
  raise exception 'Ce nom est déjà utilisé dans l''équipe.';
end $$;

-- ───────── 2. Suivi du service : commande servie ─────────
alter table public.tickets add column served_at timestamptz;
create or replace function public.gb_ticket_served(p_ticket uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; t public.tickets;
begin
  select * into c from gb_private.ctx();
  select * into t from public.tickets where id = p_ticket and bar_id = c.bid for update;
  if not found then raise exception 'Ticket introuvable.'; end if;
  if t.waitress_id <> c.sid then raise exception 'Seule la serveuse du ticket confirme le service.'; end if;
  if t.status not in ('sent','cashed','paid') then raise exception 'Envoyez d''abord la commande à la caisse.'; end if;
  update public.tickets set served_at = coalesce(served_at, now()), updated_at = now() where id = p_ticket;
end $$;

-- ───────── 3. Planning ─────────
create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  day date not null,
  kind text not null default 'travail' check (kind in ('travail','repos')),
  start_time time, end_time time,
  note text,
  updated_by uuid references public.staff(id),
  updated_at timestamptz not null default now(),
  unique (staff_id, day),
  check (kind = 'repos' or (start_time is not null and end_time is not null))
);
create index shifts_bar_day on public.shifts(bar_id, day);
create index shifts_updated_by on public.shifts(updated_by);

create or replace function public.gb_shift_set(p_staff uuid, p_day date, p_kind text, p_start time, p_end time, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; s public.staff;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into s from public.staff where id = p_staff and bar_id = c.bid and active;
  if not found then raise exception 'Membre introuvable.'; end if;
  if p_kind = 'aucun' then delete from public.shifts where staff_id = p_staff and day = p_day; return; end if;
  if p_kind not in ('travail','repos') then raise exception 'Type de planning inconnu.'; end if;
  if p_kind = 'travail' and (p_start is null or p_end is null) then raise exception 'Indiquez l''heure de début et de fin.'; end if;
  insert into public.shifts(bar_id, staff_id, day, kind, start_time, end_time, note, updated_by)
  values (c.bid, p_staff, p_day, p_kind, case when p_kind = 'travail' then p_start end, case when p_kind = 'travail' then p_end end, nullif(trim(coalesce(p_note, '')), ''), c.sid)
  on conflict (staff_id, day) do update set kind = excluded.kind, start_time = excluded.start_time, end_time = excluded.end_time,
    note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
end $$;

create or replace function public.gb_shift_copy_week(p_from date, p_to date) returns int
language plpgsql security definer set search_path = '' as $$
declare c record; n int;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  delete from public.shifts where bar_id = c.bid and day >= p_to and day < p_to + 7;
  insert into public.shifts(bar_id, staff_id, day, kind, start_time, end_time, note, updated_by)
  select bar_id, staff_id, day + (p_to - p_from), kind, start_time, end_time, note, c.sid
  from public.shifts sh where sh.bar_id = c.bid and sh.day >= p_from and sh.day < p_from + 7
    and exists (select 1 from public.staff st where st.id = sh.staff_id and st.active);
  get diagnostics n = row_count;
  perform gb_private.log(c.bid, c.sid, 'planning_copie', jsonb_build_object('de', p_from, 'vers', p_to, 'creneaux', n));
  return n;
end $$;

-- ───────── 4. Présences, retards, absences, permissions ─────────
create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  day date not null,
  status text not null check (status in ('present','retard','absent','permission','repos')),
  arrived_at timestamptz, left_at timestamptz,
  late_minutes integer not null default 0,
  note text,
  recorded_by uuid references public.staff(id),
  updated_at timestamptz not null default now(),
  unique (staff_id, day)
);
create index attendance_bar_day on public.attendance(bar_id, day);
create index attendance_recorded_by on public.attendance(recorded_by);

create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  day_from date not null, day_to date not null,
  reason text not null,
  status text not null default 'en_attente' check (status in ('en_attente','acceptee','refusee')),
  decided_by uuid references public.staff(id), decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (day_to >= day_from)
);
create index leave_bar_status on public.leave_requests(bar_id, status);
create index leave_staff on public.leave_requests(staff_id);
create index leave_decided_by on public.leave_requests(decided_by);

-- Pointage d'arrivée : présent ou en retard selon le planning (10 minutes de tolérance)
create or replace function public.gb_clock_in() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; d date := gb_private.biz_date(); sh public.shifts; nowl timestamp := now() at time zone 'Africa/Douala';
  start_ts timestamp; late int := 0; st text := 'present'; a public.attendance;
begin
  select * into c from gb_private.ctx();
  select * into a from public.attendance where staff_id = c.sid and day = d;
  if found and a.arrived_at is not null then return jsonb_build_object('status', a.status, 'late', a.late_minutes, 'deja', true); end if;
  select * into sh from public.shifts where staff_id = c.sid and day = d and kind = 'travail';
  if found then
    start_ts := d + sh.start_time + case when sh.start_time < time '06:00' then interval '1 day' else interval '0' end;
    late := greatest(0, floor(extract(epoch from (nowl - start_ts)) / 60))::int;
    if late > 10 then st := 'retard'; else late := 0; end if;
  end if;
  insert into public.attendance(bar_id, staff_id, day, status, arrived_at, late_minutes, recorded_by)
  values (c.bid, c.sid, d, st, now(), late, c.sid)
  on conflict (staff_id, day) do update set status = excluded.status, arrived_at = excluded.arrived_at, late_minutes = excluded.late_minutes, updated_at = now();
  return jsonb_build_object('status', st, 'late', late, 'planifie', sh.id is not null);
end $$;

create or replace function public.gb_clock_out() returns void
language plpgsql security definer set search_path = '' as $$
declare c record; d date := gb_private.biz_date();
begin
  select * into c from gb_private.ctx();
  update public.attendance set left_at = now(), updated_at = now() where staff_id = c.sid and day = d and arrived_at is not null;
  if not found then raise exception 'Pointez d''abord votre arrivée.'; end if;
end $$;

create or replace function public.gb_attendance_set(p_staff uuid, p_day date, p_status text, p_late int, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; s public.staff;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into s from public.staff where id = p_staff and bar_id = c.bid;
  if not found then raise exception 'Membre introuvable.'; end if;
  if p_status = 'aucun' then delete from public.attendance where staff_id = p_staff and day = p_day; return; end if;
  if p_status not in ('present','retard','absent','permission','repos') then raise exception 'Statut inconnu.'; end if;
  insert into public.attendance(bar_id, staff_id, day, status, late_minutes, note, recorded_by, arrived_at)
  values (c.bid, p_staff, p_day, p_status, case when p_status = 'retard' then greatest(coalesce(p_late, 0), 1) else 0 end,
          nullif(trim(coalesce(p_note, '')), ''), c.sid, case when p_status in ('present','retard') then now() end)
  on conflict (staff_id, day) do update set status = excluded.status, late_minutes = excluded.late_minutes,
    note = coalesce(excluded.note, public.attendance.note), recorded_by = excluded.recorded_by,
    arrived_at = coalesce(public.attendance.arrived_at, excluded.arrived_at), updated_at = now();
  perform gb_private.log(c.bid, c.sid, 'presence', jsonb_build_object('membre', s.name, 'date', p_day, 'statut', p_status, 'retard_min', p_late));
end $$;

create or replace function public.gb_leave_request(p_from date, p_to date, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c record; nid uuid;
begin
  select * into c from gb_private.ctx();
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choisissez des dates valides.'; end if;
  if p_to - p_from > 31 then raise exception 'Une permission ne peut pas dépasser 31 jours.'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Indiquez le motif de la permission.'; end if;
  insert into public.leave_requests(bar_id, staff_id, day_from, day_to, reason) values (c.bid, c.sid, p_from, p_to, trim(p_reason)) returning id into nid;
  perform gb_private.log(c.bid, c.sid, 'permission_demandee', jsonb_build_object('du', p_from, 'au', p_to));
  return nid;
end $$;

create or replace function public.gb_leave_decide(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; l public.leave_requests; d date; n text;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into l from public.leave_requests where id = p_id and bar_id = c.bid for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if l.status <> 'en_attente' then raise exception 'Cette demande a déjà été traitée.'; end if;
  update public.leave_requests set status = case when p_accept then 'acceptee' else 'refusee' end, decided_by = c.sid, decided_at = now() where id = p_id;
  if p_accept then
    for d in select generate_series(l.day_from, l.day_to, interval '1 day')::date loop
      insert into public.attendance(bar_id, staff_id, day, status, note, recorded_by) values (c.bid, l.staff_id, d, 'permission', l.reason, c.sid)
      on conflict (staff_id, day) do update set status = 'permission', note = excluded.note, recorded_by = excluded.recorded_by, updated_at = now();
    end loop;
  end if;
  select name into n from public.staff where id = l.staff_id;
  perform gb_private.log(c.bid, c.sid, case when p_accept then 'permission_acceptee' else 'permission_refusee' end, jsonb_build_object('membre', n, 'du', l.day_from, 'au', l.day_to));
end $$;

-- ───────── 5. Paie (PDG) ─────────
create table public.staff_salaries (
  staff_id uuid primary key references public.staff(id) on delete cascade,
  bar_id uuid not null references public.bars(id) on delete cascade,
  salary integer not null default 0 check (salary >= 0),
  updated_at timestamptz not null default now()
);
create index staff_salaries_bar on public.staff_salaries(bar_id);

create table public.payroll (
  id uuid primary key default gen_random_uuid(),
  bar_id uuid not null references public.bars(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  month text not null check (month ~ '^[0-9]{4}-[0-9]{2}$'),
  base integer not null, bonus integer not null default 0, deduction integer not null default 0,
  net integer not null check (net >= 0),
  method text not null default 'cash' check (method in ('cash','momo','banque')),
  note text,
  expense_id uuid references public.expenses(id) on delete set null,
  paid_by uuid references public.staff(id),
  paid_at timestamptz not null default now(),
  unique (staff_id, month)
);
create index payroll_bar_month on public.payroll(bar_id, month);
create index payroll_expense on public.payroll(expense_id);
create index payroll_paid_by on public.payroll(paid_by);

create or replace function public.gb_salary_set(p_staff uuid, p_salary int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pdg(c.srole);
  if coalesce(p_salary, -1) < 0 then raise exception 'Indiquez un salaire valide.'; end if;
  if not exists (select 1 from public.staff where id = p_staff and bar_id = c.bid) then raise exception 'Membre introuvable.'; end if;
  insert into public.staff_salaries(staff_id, bar_id, salary) values (p_staff, c.bid, p_salary)
  on conflict (staff_id) do update set salary = excluded.salary, updated_at = now();
end $$;

create or replace function public.gb_pay(p_staff uuid, p_month text, p_bonus int, p_deduction int, p_method text, p_note text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; s public.staff; base int; net int; e uuid; pid uuid;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pdg(c.srole);
  select * into s from public.staff where id = p_staff and bar_id = c.bid;
  if not found then raise exception 'Membre introuvable.'; end if;
  if exists (select 1 from public.payroll where staff_id = p_staff and month = p_month) then raise exception '% a déjà été payé(e) pour ce mois.', s.name; end if;
  select salary into base from public.staff_salaries where staff_id = p_staff; base := coalesce(base, 0);
  net := base + greatest(coalesce(p_bonus, 0), 0) - greatest(coalesce(p_deduction, 0), 0);
  if net < 0 then raise exception 'La retenue dépasse le salaire.'; end if;
  if net = 0 then raise exception 'Le montant à payer est nul : indiquez d''abord le salaire.'; end if;
  insert into public.expenses(bar_id, day, category, label, amount, method, created_by)
  values (c.bid, gb_private.biz_date(), 'Salaires', 'Salaire ' || s.name || ' (' || p_month || ')', net, coalesce(p_method, 'cash'), c.sid) returning id into e;
  insert into public.payroll(bar_id, staff_id, month, base, bonus, deduction, net, method, note, expense_id, paid_by)
  values (c.bid, p_staff, p_month, base, greatest(coalesce(p_bonus, 0), 0), greatest(coalesce(p_deduction, 0), 0), net, coalesce(p_method, 'cash'),
          nullif(trim(coalesce(p_note, '')), ''), e, c.sid) returning id into pid;
  perform gb_private.log(c.bid, c.sid, 'salaire_paye', jsonb_build_object('membre', s.name, 'mois', p_month, 'montant', net));
  return jsonb_build_object('id', pid, 'net', net);
end $$;

create or replace function public.gb_pay_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; p public.payroll;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_pdg(c.srole);
  delete from public.payroll where id = p_id and bar_id = c.bid returning * into p;
  if p.id is null then raise exception 'Paiement introuvable.'; end if;
  delete from public.expenses where id = p.expense_id;
  perform gb_private.log(c.bid, c.sid, 'salaire_annule', jsonb_build_object('mois', p.month, 'montant', p.net));
end $$;

-- Bilan du personnel sur un mois (présences, retards, ventes) : directeur et PDG
create or replace function public.gb_staff_stats(p_month text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; m0 date; m1 date;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  m0 := to_date(coalesce(p_month, to_char(gb_private.biz_date(), 'YYYY-MM')) || '-01', 'YYYY-MM-DD'); m1 := (m0 + interval '1 month')::date;
  return coalesce((select jsonb_agg(x order by x.role, x.name) from (
    select s.id, s.name, s.role, s.active,
      (select count(*) from public.shifts sh where sh.staff_id = s.id and sh.kind = 'travail' and sh.day >= m0 and sh.day < m1) as jours_prevus,
      (select count(*) from public.attendance a where a.staff_id = s.id and a.day >= m0 and a.day < m1 and a.status in ('present','retard')) as presents,
      (select count(*) from public.attendance a where a.staff_id = s.id and a.day >= m0 and a.day < m1 and a.status = 'retard') as retards,
      (select coalesce(sum(late_minutes), 0) from public.attendance a where a.staff_id = s.id and a.day >= m0 and a.day < m1) as minutes_retard,
      (select count(*) from public.attendance a where a.staff_id = s.id and a.day >= m0 and a.day < m1 and a.status = 'absent') as absences,
      (select count(*) from public.attendance a where a.staff_id = s.id and a.day >= m0 and a.day < m1 and a.status = 'permission') as permissions,
      (select count(*) from public.tickets t join public.service_days d on d.id = t.day_id where t.waitress_id = s.id and t.status in ('cashed','paid') and d.business_date >= m0 and d.business_date < m1) as tickets,
      (select coalesce(sum(t.total), 0) from public.tickets t join public.service_days d on d.id = t.day_id where t.waitress_id = s.id and t.status in ('cashed','paid') and d.business_date >= m0 and d.business_date < m1) as ventes,
      (select coalesce(sum(r.diff), 0) from public.remittances r join public.service_days d on d.id = r.day_id where r.waitress_id = s.id and d.business_date >= m0 and d.business_date < m1) as ecart_caisse
    from public.staff s where s.bar_id = c.bid) x), '[]'::jsonb);
end $$;

-- ───────── 6. Droits de lecture ─────────
alter table public.shifts enable row level security;
alter table public.attendance enable row level security;
alter table public.leave_requests enable row level security;
alter table public.staff_salaries enable row level security;
alter table public.payroll enable row level security;
create policy shifts_read on public.shifts for select to authenticated using (bar_id = (select gb_private.bar()));
create policy attendance_read on public.attendance for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_manager()) or staff_id = (select gb_private.me())));
create policy leave_read on public.leave_requests for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_manager()) or staff_id = (select gb_private.me())));
create policy salaries_read on public.staff_salaries for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_pdg()) or staff_id = (select gb_private.me())));
create policy payroll_read on public.payroll for select to authenticated
  using (bar_id = (select gb_private.bar()) and ((select gb_private.is_pdg()) or staff_id = (select gb_private.me())));

drop policy expenses_read on public.expenses;
create policy expenses_read on public.expenses for select to authenticated using (bar_id = (select gb_private.bar()) and (select gb_private.is_pdg()));
drop policy kyc_insert on storage.objects; drop policy kyc_read on storage.objects; drop policy kyc_delete on storage.objects;
create policy kyc_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'kyc' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_pdg()));
create policy kyc_read on storage.objects for select to authenticated
  using (bucket_id = 'kyc' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_pdg()));
create policy kyc_delete on storage.objects for delete to authenticated
  using (bucket_id = 'kyc' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_pdg()));

revoke all on public.shifts, public.attendance, public.leave_requests, public.staff_salaries, public.payroll from anon;
revoke insert, update, delete, truncate on public.shifts, public.attendance, public.leave_requests, public.staff_salaries, public.payroll from authenticated;
grant select on public.shifts, public.attendance, public.leave_requests, public.staff_salaries, public.payroll to authenticated;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'gb\_%' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname like 'gb\_admin\_%' then
      execute format('revoke execute on function %s from authenticated', f.sig);
      execute format('grant execute on function %s to service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
revoke execute on function gb_private.need_pdg(text), gb_private.need_manager(text) from public, anon, authenticated;

alter publication supabase_realtime add table public.shifts, public.attendance, public.leave_requests;
