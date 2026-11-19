-- GesCo Bar · v2.1 : seuil d'alerte de stock par produit (une cave à vin n'a pas le même rythme qu'un casier de bière)
alter table public.products add column low_at integer check (low_at is null or low_at >= 0);
update public.products set low_at = 2 where category in ('Vins rouges','Vins blancs','Vins rosés','Champagnes','Spiritueux','Liqueurs') and parent_id is null;

create or replace function public.gb_product_set_alert(p_product uuid, p_low int) returns void
language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into c from gb_private.ctx(); perform gb_private.need_caisse(c.srole);
  if p_low is not null and p_low < 0 then raise exception 'Le seuil doit être positif.'; end if;
  update public.products set low_at = p_low where id = p_product and bar_id = c.bid;
end $$;
revoke execute on function public.gb_product_set_alert(uuid, int) from public, anon;
grant execute on function public.gb_product_set_alert(uuid, int) to authenticated;
-- (seed_products mis à jour avec low_at : voir la version appliquée dans Supabase, migration « seuil_stock_par_produit »)
