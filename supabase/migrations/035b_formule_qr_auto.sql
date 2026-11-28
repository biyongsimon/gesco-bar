-- 035b : le QR automatique Notch Pay (paiement confirmé tout seul) suit la même règle que le paiement par numéro : Snack-Restaurant et plus.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.gb_admin_momo_link_start(uuid,uuid)'::regprocedure);
  if position('need_tier' in d) = 0 then
    n := regexp_replace(d, '(if not found then raise exception ''Session invalide\.''; end if;)', '\1 perform gb_private.need_tier(s.bar_id, 2, ''Le paiement Mobile Money automatique'');');
    if n = d then raise exception 'Injection impossible dans gb_admin_momo_link_start'; end if;
    execute n;
  end if;
end $mig$;
