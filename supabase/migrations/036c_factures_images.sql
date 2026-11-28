-- 036c : la signature et le cachet de l'éditeur sont gardés dans le stockage privé « factures » (dossier _bismo), jamais sur le site public.
update storage.buckets set allowed_mime_types = array['application/pdf', 'image/png'] where id = 'factures';
