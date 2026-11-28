-- 036d : un reçu ou une facture se conserve dix ans (pièce comptable), même si le bar ou le paiement est supprimé.
-- Le document garde toutes ses données figées (client, payeur, vendeur) ; seul le lien vers le bar ou le paiement disparaît.
alter table public.invoices alter column bar_id drop not null, alter column subscription_id drop not null;
alter table public.invoices drop constraint if exists invoices_bar_id_fkey, add constraint invoices_bar_id_fkey foreign key (bar_id) references public.bars(id) on delete set null;
alter table public.invoices drop constraint if exists invoices_subscription_id_fkey, add constraint invoices_subscription_id_fkey foreign key (subscription_id) references public.subscriptions(id) on delete set null;
