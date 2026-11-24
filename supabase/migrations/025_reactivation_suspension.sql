-- 025 : bar suspendu → motif visible, demande de réactivation à BISMO Agency avec preuves (photos, PDF),
--       échange dans l'application, contact direct (téléphone / WhatsApp) réglé dans la console éditeur.
alter table public.bars add column if not exists suspend_reason text check (suspend_reason is null or length(suspend_reason) <= 500),
  add column if not exists suspended_at timestamptz;
alter table public.support_threads add column if not exists kind text not null default 'aide' check (kind in ('aide', 'reactivation'));
alter table public.support_messages add column if not exists files text[];

-- Demande de réactivation (PDG ou directeur d'un bar suspendu) : un seul fil ouvert par bar, marqué urgent
create or replace function public.gb_reactivation_send(p_message text, p_files text[] default null, p_contact text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c record; b public.bars; th uuid; f text; msg text := left(trim(coalesce(p_message, '')), 2000);
begin
  perform set_config('gb.allow_blocked', '1', true);
  select * into c from gb_private.ctx(); perform gb_private.need_manager(c.srole);
  select * into b from public.bars where id = c.bid;
  if not b.suspended then raise exception 'Ce bar n''est pas suspendu.'; end if;
  if msg = '' and coalesce(array_length(p_files, 1), 0) = 0 then raise exception 'Écrivez un message ou ajoutez une preuve.'; end if;
  if coalesce(array_length(p_files, 1), 0) > 5 then raise exception '5 fichiers au maximum par envoi.'; end if;
  foreach f in array coalesce(p_files, '{}') loop
    if f !~ ('^' || c.bid::text || '/reactivation-[0-9]+-[0-9]+\.(jpg|jpeg|png|webp|pdf)$') then raise exception 'Fichier non valide.'; end if;
  end loop;
  select id into th from public.support_threads where bar_id = c.bid and kind = 'reactivation' and status <> 'resolu' order by created_at desc limit 1;
  if th is null then
    insert into public.support_threads(bar_id, staff_id, status, urgence, kind, summary, contact)
    values (c.bid, c.sid, 'transmis', 'urgente', 'reactivation', 'Demande de réactivation : bar suspendu' || coalesce(' (motif : ' || b.suspend_reason || ')', ''), nullif(trim(coalesce(p_contact, '')), ''))
    returning id into th;
  end if;
  insert into public.support_messages(thread_id, sender, body, files) values (th, 'client', coalesce(nullif(msg, ''), 'Preuves jointes.'), nullif(p_files, '{}'));
  update public.support_threads set status = 'transmis', urgence = 'urgente', last_msg_at = now(), admin_seen_at = null,
    contact = coalesce(nullif(trim(coalesce(p_contact, '')), ''), contact) where id = th;
  insert into public.platform_log(admin_id, action, bar_id, data) values (null, 'reactivation_demandee', c.bid, jsonb_build_object('par', c.sname, 'fichiers', coalesce(array_length(p_files, 1), 0)));
  return th;
end $$;

-- Écran de suspension : motif, date, contact BISMO, et le fil de la demande (PDG et directeur)
create or replace function public.gb_reactivation_state() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c record; b public.bars; t public.support_threads; mgr boolean;
begin
  perform set_config('gb.allow_blocked', '1', true);
  select * into c from gb_private.ctx(); select * into b from public.bars where id = c.bid;
  mgr := c.srole in ('pdg', 'directeur');
  if mgr then select * into t from public.support_threads where bar_id = c.bid and kind = 'reactivation' order by created_at desc limit 1; end if;
  return jsonb_build_object('suspended', b.suspended, 'reason', b.suspend_reason, 'since', b.suspended_at,
    'phone', (select phone from public.platform_config where id = 1), 'whatsapp', (select whatsapp from public.platform_config where id = 1),
    'thread', case when t.id is null then null else jsonb_build_object('id', t.id, 'status', t.status, 'created_at', t.created_at,
      'messages', (select coalesce(jsonb_agg(jsonb_build_object('sender', m.sender, 'body', m.body, 'files', m.files, 'at', m.created_at) order by m.id), '[]') from public.support_messages m where m.thread_id = t.id)) end);
end $$;
revoke all on function public.gb_reactivation_send(text, text[], text), public.gb_reactivation_state() from public, anon;
grant execute on function public.gb_reactivation_send(text, text[], text), public.gb_reactivation_state() to authenticated;

-- Console éditeur : suspendre avec un motif (visible par le bar) ; réactiver clôt la demande avec un message
create or replace function public.gb_pf_suspend(p_bar uuid, p_on boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare th uuid;
begin
  perform gb_private.need_admin();
  if p_on then
    update public.bars set suspended = true, suspended_at = now(), suspend_reason = nullif(left(trim(coalesce(p_reason, '')), 500), '') where id = p_bar;
  else
    update public.bars set suspended = false, suspended_at = null, suspend_reason = null where id = p_bar;
    for th in select id from public.support_threads where bar_id = p_bar and kind = 'reactivation' and status <> 'resolu' loop
      insert into public.support_messages(thread_id, sender, body) values (th, 'bismo', 'Votre accès est rétabli. Merci, et bon service !');
      update public.support_threads set status = 'resolu', last_msg_at = now(), admin_seen_at = now() where id = th;
    end loop;
  end if;
  insert into public.platform_log(admin_id, action, bar_id, data) values (auth.uid(), case when p_on then 'bar_suspendu' else 'bar_reactive' end, p_bar, jsonb_build_object('motif', p_reason));
end $$;
create or replace function public.gb_pf_contact(p_phone text, p_whatsapp text) returns void
language plpgsql security definer set search_path = '' as $$
declare ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'); wa text := regexp_replace(coalesce(p_whatsapp, ''), '[^0-9]', '', 'g');
begin
  perform gb_private.need_admin();
  if ph <> '' and ph !~ '^(237)?6[0-9]{8}$' then raise exception 'Numéro de téléphone invalide.'; end if;
  if wa <> '' and wa !~ '^[0-9]{8,15}$' then raise exception 'Numéro WhatsApp invalide (avec l''indicatif, ex. 2376XXXXXXXX).'; end if;
  update public.platform_config set phone = nullif(ph, ''), whatsapp = nullif(wa, '') where id = 1;
  insert into public.platform_log(admin_id, action, data) values (auth.uid(), 'reglages', jsonb_build_object('contact', true));
end $$;
revoke all on function public.gb_pf_suspend(uuid, boolean, text), public.gb_pf_contact(text, text) from public, anon;
grant execute on function public.gb_pf_suspend(uuid, boolean, text), public.gb_pf_contact(text, text) to authenticated;

-- 025b : la console éditeur reçoit le motif et la date de suspension ; les bars déjà suspendus prennent leur note comme motif visible
-- (gb_pf_bars : ajout de b.suspend_reason, b.suspended_at ; voir pg_get_functiondef('public.gb_pf_bars'::regproc))
update public.bars set suspend_reason = coalesce(suspend_reason, admin_note), suspended_at = coalesce(suspended_at, now()) where suspended;
