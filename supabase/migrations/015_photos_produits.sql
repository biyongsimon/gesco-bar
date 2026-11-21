-- 015 · Photos des produits : image de la photothèque GesCo (« c:castel ») ou photo prise par le bar (stockage « produits »)
alter table public.products add column if not exists image text;

-- Dossier public des photos de produits (une photo de bouteille n'est pas une donnée sensible) ; écriture réservée à la caisse, au directeur et au PDG du bar
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('produits', 'produits', true, 2097152, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/webp', 'image/jpeg', 'image/png'];
drop policy if exists produits_insert on storage.objects;
drop policy if exists produits_delete on storage.objects;
create policy produits_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'produits' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_caisse()));
create policy produits_delete on storage.objects for delete to authenticated
  using (bucket_id = 'produits' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_caisse()));

create or replace function public.gb_product_image(p_id uuid, p_image text) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; p public.products;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  p_image := nullif(trim(coalesce(p_image, '')), '');
  if p_image is not null and not (p_image ~ '^c:[a-z0-9-]{1,40}$'
      or (p_image ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,80}\.(webp|jpe?g|png)$' and split_part(p_image, '/', 1) = c.bid::text)) then
    raise exception 'Photo invalide.';
  end if;
  update public.products set image = p_image where id = p_id and bar_id = c.bid returning * into p;
  if not found then raise exception 'Produit introuvable.'; end if;
  perform gb_private.log(c.bid, c.sid, 'produit_photo', jsonb_build_object('produit', p.name));
end $$;
revoke all on function public.gb_product_image(uuid, text) from public, anon;
grant execute on function public.gb_product_image(uuid, text) to authenticated;
