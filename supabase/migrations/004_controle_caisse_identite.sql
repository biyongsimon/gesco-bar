-- GesCo Bar · v2.2 (appliquée dans Supabase sous le nom « controle_caisse_identite_bar »)
-- 1. gb_ticket_set_qty : la caisse ne modifie plus jamais la commande d'une serveuse
--    (seule la serveuse propriétaire du ticket change les quantités ; la caisse peut annuler ou rouvrir).
-- 2. gb_voucher_check : un bon se retrouve par son code (XXXX-XXXX) ou par son numéro (B-0001).
-- 3. gb_inventory(p_counts jsonb) : inventaire du frigo / de la réserve, écarts tracés (stock_moves.kind = 'inventaire').
-- 4. bars.legal_name, bars.niu (format DGI : P|M + 12 chiffres + lettre), bars.id_doc_path, bars.kyc_status
--    + gb_bar_identity(p_legal_name, p_niu, p_doc_path)
--    + compartiment de stockage privé « kyc » : lecture/écriture réservées à la caisse du bar (dossier = id du bar).
-- Le SQL exact est celui de la migration appliquée ; il est reproduit ci-dessous.

alter table public.stock_moves drop constraint stock_moves_kind_check;
alter table public.stock_moves add constraint stock_moves_kind_check
  check (kind in ('appro','dotation','reprise','ajustement','ouverture','vente_comptoir','inventaire'));

alter table public.bars
  add column legal_name text check (legal_name is null or length(trim(legal_name)) between 2 and 120),
  add column niu text check (niu is null or niu ~ '^[PM][0-9]{12}[A-Z]$'),
  add column id_doc_path text,
  add column kyc_status text not null default 'non_renseigne' check (kyc_status in ('non_renseigne','a_verifier','verifie','refuse'));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kyc', 'kyc', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy kyc_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'kyc' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_caisse()));
create policy kyc_read on storage.objects for select to authenticated
  using (bucket_id = 'kyc' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_caisse()));
create policy kyc_delete on storage.objects for delete to authenticated
  using (bucket_id = 'kyc' and (storage.foldername(name))[1] = (select gb_private.bar())::text and (select gb_private.is_caisse()));

-- Les fonctions gb_ticket_set_qty, gb_voucher_check, gb_inventory et gb_bar_identity :
-- voir `select pg_get_functiondef('public.<nom>'::regproc)` dans Supabase.
