-- 017 · Règles de réapprovisionnement par produit : stock minimum à garder et taille du casier/pack
-- (appliquée en ligne ; gb_reappro réécrite pour tenir compte du minimum — voir le texte complet dans l'historique Supabase)
alter table public.products add column if not exists reorder_min int, add column if not exists pack int;
-- gb_product_rule(p_id, p_min, p_pack) : réservée caisse/PDG, journalisée (« regle_reappro »)
-- gb_reappro : conseil = rythme × jours + minimum − disponible ; renvoie aussi « min »
