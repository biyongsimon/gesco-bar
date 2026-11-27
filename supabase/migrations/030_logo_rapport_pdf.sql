-- 030 : logo du snack (en-tête des PDF : rapport de clôture, bon de commande), téléphone affiché sur les documents,
--       notification de clôture qui ouvre directement le rapport (directeur et PDG).
alter table public.bars add column if not exists logo_path text;

create or replace function public.gb_bar_logo(p_path text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx();
  if c.srole <> 'pdg' then raise exception 'Seul le PDG change le logo.'; end if;
  if p_path is not null and p_path !~ ('^' || c.bid || '/logo-[0-9]+\.png$') then raise exception 'Fichier non valide.'; end if;
  update public.bars set logo_path = p_path where id = c.bid;
  perform gb_private.log(c.bid, c.sid, 'reglages_modifies', jsonb_build_object('logo', p_path is not null));
end $$;
revoke all on function public.gb_bar_logo(text) from public, anon;
grant execute on function public.gb_bar_logo(text) to authenticated;

-- Options : délais de rappel + téléphone des documents
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
    elsif k = 'phone' then
      if jsonb_typeof(v) <> 'string' or length(v #>> '{}') > 40 then raise exception 'Téléphone invalide.'; end if;
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

create or replace function gb_private.push_dayclose() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'closed' and old.status <> 'closed' then
    perform gb_private.push(new.bar_id, gb_private.staff_of(new.bar_id, array['pdg', 'directeur']), 'Journée clôturée : rapport disponible',
      'Ventes ' || gb_private.fcfa((new.summary->>'ventes')::int) || ' · écart de caisse ' || gb_private.fcfa(coalesce(new.counted_cash, 0) - coalesce(new.expected_cash, 0)) || '. Touchez pour ouvrir le rapport.',
      './?tab=day&rapport=' || new.id, 'j' || new.id);
  end if;
  return null;
end $$;
