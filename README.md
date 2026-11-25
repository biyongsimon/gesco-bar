# GesCo Bar · version bêta

SaaS B2B de gestion de bar : tickets par serveuse, envoi à la caisse, encaissement espèces / Mobile Money, reliquats et bons vérifiables, stock général et bouteilles en main, revenus, clôture de journée. Plusieurs bars, données séparées par établissement.

**Application en ligne : https://gescobar-cm.netlify.app** (Netlify, compte biyongsimon). Code : https://github.com/biyongsimon/gesco-bar

Mettre à jour le site : `python3 app/build.py`, compresser le contenu de `dist/web/` en zip, puis Netlify → gescobar-cm → Deploys → déposer le zip.

## Ce qui est déjà en place

| Élément | État |
|---|---|
| Base de données Supabase `gesco-bar` (région Paris, `tkiuepleshsvptranoik`) | Créée, testée |
| Sécurité : chaque bar ne voit que ses données, la serveuse ne voit que ses tickets, les PIN sont illisibles | Testée |
| Fonction serveur `gesco-admin` (inscription d'un bar, connexion par PIN, ajout du personnel) | Déployée, testée |
| Application web installable (PWA) | `dist/web/`, prête à mettre en ligne |
| Démo autonome (données locales) | `dist/demo.html`, ou `index.html?demo` |

## Mettre l'application en ligne

**Option A, Netlify par glisser-déposer (depuis un ordinateur)**
1. Créez un compte gratuit sur netlify.com.
2. Ouvrez app.netlify.com/drop et glissez le dossier `dist/web/`. Le site est en ligne en 30 secondes.
3. Renommez le site (Site configuration → Change site name), par exemple `gescobar` → `gescobar.netlify.app`.

**Option B, Netlify relié à GitHub (mises à jour automatiques)**
1. Mettez ce dossier dans un dépôt GitHub.
2. Netlify → Add new site → Import from GitHub. Le fichier `netlify.toml` règle tout (dossier publié `dist/web`).

**Option C, GitHub Pages** : publiez le contenu de `dist/web/` sur la branche `gh-pages`.

Ensuite : ouvrez le site, onglet **Créer mon bar** ; vous recevez un code bar à donner aux serveuses. HTTPS est obligatoire pour installer l'appli sur téléphone et pour le hors ligne (Netlify et GitHub Pages le fournissent).

Aucune variable d'environnement : l'URL Supabase et la clé publique sont dans `app/build.py` (la clé `sb_publishable_…` est faite pour le navigateur ; la sécurité repose sur les règles de la base).

## Structure

```
supabase/migrations/001…006            Schéma, règles de sécurité, fonctions métier (toutes appliquées ; 006 = rôles, planning, présences, paie)
supabase/functions/gesco-admin/index.ts Fonction serveur (déjà déployée, verify_jwt = false, contrôle interne)
app/src/app.html                        Code source unique de l'application
app/public/                             Manifeste PWA, service worker, icône
app/build.py                            Génère dist/web (en ligne) et dist/demo.html (démo)
```

Modifier l'application : éditez `app/src/app.html`, puis `python3 app/build.py`, puis redéployez `dist/web/`.

## Rôles (v3)

| Rôle | Ce qu'il fait |
|---|---|
| **PDG** (créateur du bar) | Accueil d'ensemble, paie (salaires, primes, retenues, fiches de paie), compta, revenus, réglages et identité légale ; contrôle toute l'équipe, nomme le directeur |
| **Directeur** | Supervision des commandes (prises et servies, retards de service), présences, retards, absences, permissions, planning (téléchargeable en image et partageable sur WhatsApp), ajout des caissières et serveuses. Ne valide aucun paiement |
| **Caisse** | Commandes en direct, versements, Mobile Money, reliquats, bons, stock, inventaire, approvisionnement, vente au comptoir, clôture de journée |
| **Serveuse** | Ses tickets, « commande servie », son planning, pointage, demandes de permission, ses fiches de paie |
| **Cuisine** (module Cuisine, Snack Gold et plus) | Écran des bons de cuisine : à préparer, en préparation, prêts ; son planning, pointage |

Chaque espace a une barre de navigation en bas, un menu complet et une recherche (clients, tickets, boissons, employés, bons). Le planning est visible par tout le monde.

Démo : code DEMO ; PIN serveuses 1111 / 2222 / 3333, caisse 0000, directeur 5555, PDG 9999, cuisinier (Paul) 4444.

## Carte des produits

Chaque bar construit sa propre carte (onglet Stock) : bières, vins rouges, blancs et rosés, champagnes, spiritueux, liqueurs, sucreries, cuisine… La catégorie est libre.
- **Unité de vente** : bouteille, verre, canette, demi-bouteille, carafe, plat, portion, pièce.
- **Vente au verre** : un verre est rattaché à une bouteille (ex. 1 bouteille de J&B = 15 verres). Le bouton « Ouvrir une bouteille » retire 1 bouteille du stock et ajoute les verres.
- **Seuil d'alerte par produit** : 2 bouteilles pour un whisky, 12 pour une bière, etc.

## Règles métier appliquées par le serveur

- Toutes les écritures passent par des fonctions `gb_*` qui vérifient le rôle ; les tables sont en lecture seule pour l'application.
- Ticket : brouillon → envoyé → encaissé (serveuse) → payé (validé par la caisse). Un ticket encaissé est verrouillé ; seule la caisse peut le rouvrir.
- Suppression : la serveuse supprime un brouillon ; après envoi, elle demande l'annulation et la caisse accepte ou refuse.
- Toute correction après envoi, suppression, réouverture, versement, bon et réglage est écrite dans le journal d'audit.
- Journée de service : les ventes après minuit comptent sur la veille jusqu'à 6 h (heure de Douala).
- Connexion PIN : 5 erreurs bloquent le compte 5 minutes.
- Vente au comptoir : la caisse peut servir un client elle-même ; le stock général et la caisse sont mis à jour tout de suite, sans versement.
- Hors ligne : l'application s'ouvre avec les dernières données connues ; les gestes de la serveuse (ticket, quantités, envoi, encaissement) sont mis en file et envoyés au retour du réseau, sans doublon.

## À faire avant l'ouverture commerciale

1. **Paiement Mobile Money automatique** : brancher un agrégateur (CinetPay, Notch Pay ou API MTN MoMo / Orange Money) qui confirme le paiement par ticket. Aujourd'hui la caisse confirme à la main.
2. **E-mails** : configurer un SMTP (Brevo, Resend…) dans Supabase > Authentication pour la réinitialisation du mot de passe propriétaire. Le PIN se réinitialise déjà depuis l'espace caisse.
3. **Protection de l'inscription** : ajouter un captcha (Cloudflare Turnstile) sur « Créer mon bar » avant la promotion publique.
4. **Abonnement** : la colonne `bars.plan` vaut `beta` ; à relier à une offre payante.
5. **Imprimante thermique Bluetooth 58 mm** pour les bons (le bouton Imprimer utilise déjà un format ticket).
6. **Consignes (casiers et emballages vides)** et prix d'achat pour calculer la marge.
8. Application installable : icônes PNG fournies ; tester l'installation sur un Android d'entrée de gamme.
7. Passer Supabase en offre payante avant le lancement (l'offre gratuite met le projet en pause après une semaine sans activité).

## v3.2 · Paiements et abonnement

- **QR de paiement (serveuse)** : le PDG saisit ses codes marchands Orange Money / MTN MoMo (Réglages → Paiements). Le QR, animé, contient le code USSD avec le montant du ticket (`tel:` + USSD). Les modèles USSD sont modifiables : vérifiez-les auprès de l'opérateur.
- **Paiement par numéro** : via un compte marchand Notch Pay (clé publique saisie par le PDG, gardée côté serveur dans `gb_private.pay_keys`). La fonction `gesco-admin` (actions `momo_push`, `momo_status`) envoie la demande ; le client valide sur son téléphone ; le ticket passe « payé » automatiquement.
- **Permissions** : serveuses et caisse → directeur ; directeur → PDG ; personne ne valide sa propre demande.
- **Abonnement** (directeur et PDG) : Snack Simple 10 000, Snack Premium 15 000, Snack Gold 20 000, Lounge 30 000 FCFA/mois ; 12 mois = 10 payés. Le codes marchands de BISMO Agency se règlent dans `public.platform_config`. Validation d'un paiement : `select public.gb_admin_sub_validate('<id>', true);` (service role).

## v4 · Console éditeur (BISMO Agency)

- Adresse : `/console.html` sur le site. Première connexion : e-mail, mot de passe choisi et code d'installation à usage unique (table `gb_private.platform_setup`).
- Vue d'ensemble (revenu mensuel récurrent, encaissements, bars actifs, inscriptions), validation des paiements avec la capture du SMS, fiche de chaque bar (formule, date de fin, mois offerts, suspension, identité légale), réglages des numéros de réception, journal.
- Blocage automatique 3 jours après la fin de l'abonnement (sauf activation provisoire de 72 h) ; le PDG et le directeur gardent l'accès à « Abonnement » pour renouveler. Suspension manuelle possible.
- Limites des formules appliquées par le serveur : Simple (1 caisse, 3 serveuses, pas de directeur), Premium (2 caisses, 6 serveuses, pas de directeur), Gold (12 employés), Lounge et bêta illimités.

## v4.2 · Assistant IA d'assistance
- Bouton « Aide » (en-tête, menu, écran de connexion, écran bloqué) : fenêtre de discussion avec suggestions selon le rôle.
- Réponses par Claude (modèle `claude-haiku-5-5`) via l'action `assist` de la fonction `gesco-admin`, avec la base de connaissances `kb.ts` et le contexte du bar (formule, blocage, paiement en vérification…).
- L'assistant ne fait aucune action et ne demande jamais de PIN ni de code secret. S'il ne peut pas régler le problème, il transmet à BISMO Agency (outil `transmettre_a_bismo`) : la discussion apparaît dans la console, rubrique **Assistance**, avec un résumé et l'urgence. La réponse de BISMO s'affiche dans la fenêtre d'aide du client.
- Quotas journaliers par utilisateur et par visiteur ; migration `010_assistance_ia.sql`.
- Activation : ajouter le secret `ANTHROPIC_API_KEY` dans Supabase → Edge Functions → Secrets. Sans clé, la fenêtre indique que l'assistant n'est pas encore activé.

## v4.3 · Essai gratuit et avis
- Formule **Essai gratuit** (`essai`) : toutes les fonctions jusqu'à la date de fin, puis blocage automatique (3 jours de grâce) tant qu'aucune formule n'est payée. Un paiement pendant l'essai démarre à la fin de l'essai.
- Console → Bars → fiche : boutons « Essai gratuit 14 / 30 jours dès aujourd'hui ». Console → Réglages → « Nouveaux bars » : essai automatique de N jours à l'inscription (sinon bêta illimitée).
- **Avis** : invitation automatique après 2 semaines d’utilisation (« Plus tard » = 3 jours, « Non merci » = 2 mois, puis tous les 2 mois). Menu de l'application → « Donner mon avis » (étoiles, sujets, message ; possible même bloqué ; 5 par jour et par personne). Console → rubrique **Avis** : note moyenne, répartition, sujets, filtres.
- Migrations `011_essai_gratuit.sql`, `012_avis.sql` (+ message de blocage spécifique à l'essai).
- À déployer avec l'activation de l'assistant : `kb.ts` mis à jour (essai, avis).

## v4.4 · Abonnement payé en direct (Notch Pay de l'éditeur)
- Rubrique Abonnement → « Sur mon téléphone » : le PDG saisit son numéro, reçoit la demande Mobile Money, tape son code secret ; la formule s'active automatiquement (vérification du statut et du montant chez Notch Pay). Le transfert avec preuve reste disponible.
- Activation : secret Supabase `NOTCHPAY_SUB_KEY` (clé publique Notch Pay, sandbox pour tester puis production) + console → Réglages → « Paiement direct des abonnements ».
- Migration `013_abonnement_notchpay.sql`. Une demande non validée expire après 15 minutes.

## v4.5 · QR de paiement vivant
- Paiement QR : anneau animé et « En attente de validation » tant que le paiement n'est pas confirmé ; à la confirmation, feux d'artifice et « Commande payée ! » clignotant, vibration et son.
- Bar avec clé Notch Pay : le QR encode un lien de paiement Notch Pay (action `momo_link`), le statut est vérifié toutes les 3,5 s et le ticket passe payé tout seul (montant contrôlé). Sans clé : QR USSD marchand, la célébration s'affiche quand la caisse confirme.
- Migration `014_qr_paiement_automatique.sql`.

## v4.6 — Console éditeur modernisée et installable
- Nouveau design sombre (thème clair au choix) : accueil avec revenu mensuel, liste « À traiter », indicateurs à icônes, graphiques, classement des bars.
- Sur téléphone : barre d’onglets en bas (Accueil, Paiements, Assistance, Bars, Plus), tableaux affichés en fiches, journal en fil chronologique.
- Application installable « GesCo Console » (manifeste `console.webmanifest`, icônes `console-*.png`, portée `/console`).
- Connexion rapide propre à l’appareil : code à 4 chiffres (haché PBKDF2 en local) et empreinte (WebAuthn), demandés à l’ouverture et après 1 minute d’inactivité ; 5 erreurs → déconnexion et mot de passe obligatoire.

## v4.7 — Cartes visuelles des boissons
- Prise de commande en cartes : photo de la bouteille, catégories défilantes, recherche, toucher = +1 avec animation (rebond, badge, « +1 », vibration), bouton − sur la carte, résumé du ticket en pastilles.
- Photothèque GesCo (`app/public/produits/*.webp`, 19 photos détourées et améliorées) + bouteilles dessinées (Beaufort, Isenbeck, Tangui, Supermont, Opur, Fanta…) ; reconnaissance automatique d'après le nom du produit.
- Stock → vignette du produit : choisir une photo de la photothèque ou prendre une photo (réduite en WebP 480 px sur le téléphone, stockage public `produits/<bar>/…`).
- Migration 015 : `products.image`, `gb_product_image`, compartiment `produits`.

## v4.8 — Réapprovisionnement intelligent et bons de commande
- Stock (caisse, PDG) : rythme de vente réel des 14 derniers jours (verres convertis en bouteilles), stock comptoir + bouteilles chez les serveuses → jours restants, niveau (Urgent / Bientôt / À prévoir), quantité conseillée arrondie au casier ou au pack, pour tenir 3, 7 ou 14 jours.
- Bon de commande : enregistré (`purchase_orders`), envoyé au dépôt sur WhatsApp ; « Livraison reçue » met le stock et le prix d'achat à jour automatiquement (mouvements « appro »).
- Pastille « Urgent » sur l'onglet Stock, recalcul toutes les 10 minutes. Migration 016 : `gb_reappro`, `gb_po_create`, `gb_po_receive`, `gb_po_cancel`.
- Règles par produit (migration 017) : stock minimum et taille du casier/pack, alerte rouge sous la moitié du minimum.

## v4.9 — Module Cuisine (inclus à partir de Snack Gold)
- Activation par le PDG (Réglages). Plats = catégorie « Cuisine » ou unité plat/portion. Rôle « Cuisine » (Équipe), écran Cuisine en 3 colonnes (À préparer / En préparation / Prêts), bon numéroté, bande à la couleur de la serveuse, minuteur (rouge après 15 min). Caisse, directeur et PDG voient aussi l'écran.
- « Prêt » ne prévient que la serveuse de la table ; elle confirme « Je l'ai récupéré » sur son ticket.
- Recettes (Stock → plat → Recette) : ingrédients (catégorie « Ingrédients », unités g / ml / pièce) déduits à l'envoi, rendus si le plat est annulé avant d'être commencé ; un plat commencé ne peut plus être retiré par la serveuse. Le prix d'achat du plat = coût de la recette (marge affichée).
- Réapprovisionnement : les plats en sont exclus ; les ingrédients y entrent avec la consommation de la cuisine.
- Migrations 018 (`kitchen_orders`, `recipes`, `gb_kitchen_step`, `gb_kitchen_toggle`, `gb_recipe_set`, tickets réécrits) et 019.

## v4.10 — Planning intelligent
- Planning → « Générer la semaine automatiquement » (directeur, PDG) : horaires d'ouverture par jour (ou fermé), serveuses par jour proposées selon l'affluence réelle des 8 dernières semaines (`gb_plan_load`), 1 ou 2 repos par employé, équipe d'ouverture / de fermeture pour les soirées de plus de 9 h.
- Repos tournants et équitables (pas le même jour que la semaine d'avant, de préférence les jours calmes, directeur / caisse / cuisine pas de repos le même jour), permissions accordées respectées, une personne à la caisse et en cuisine chaque jour d'ouverture ; points à surveiller affichés.
- Aperçu avant d'appliquer ; enregistrement en une fois (`gb_shift_bulk`, réglages gardés dans `bars.plan_cfg`) ; chaque case reste modifiable.
- Mise à jour automatique de l'application et ouverture sur le premier onglet de chaque rôle.

## v4.11 — Salle, relève jour / nuit, cuisine réaliste, poste caisse
- Cheffe de salle (`staff.head`, `gb_staff_head`) : voit toutes les tables (RLS élargie), prend ou confie une table (`gb_ticket_transfer`, les bons cuisine suivent). Badge ★ partout, bandeau « Cheffe de salle » côté caisse, direction et serveuses.
- Relève de caisse (`cash_handovers`, `gb_handover`, `gb_handover_confirm`) : bilan par service dans la même journée, confirmation par la caissière suivante, services repris dans la clôture. Départ d'une serveuse bloqué tant qu'il reste une table ouverte ou de l'argent non versé (`gb_clock_out`).
- Planning automatique : mode deux équipes (heure de relève, serveuses de jour / de nuit, alternance hebdomadaire).
- Cuisine : un plat commencé puis annulé passe « à décider » → revendre (repris automatiquement par la commande suivante du même plat, 6 h max), repas du personnel ou perte (`gb_kitchen_decide`) ; pertes dans la clôture. Courses du marché (`gb_market_add/list/delete`, dépenses « Courses du marché »), recette facultative, prix de revient estimé, catalogue de 35 plats.
- Poste caisse (écran ≥ 1200 px) : menu latéral, Commandes en 3 colonnes avec la cuisine en direct, raccourcis clavier.
- Migration 020.

## v4.12 — Écran mural cuisine, plat gardé au choix, tablettes et Windows
- Plat gardé : plus de reprise automatique ; la nouvelle commande arrive en « À préparer » avec l'alerte ♻ et le bouton « Servir le plat gardé » (`gb_kitchen_reuse`, migration 021) ; notification au cuisinier et à la caisse.
- Écran mural (KDS) : plein écran, gros caractères, horloge, son, jamais verrouillé, verrou d'écran (Wake Lock), mémorisé sur l'appareil (`?kds=1`). Téléphone du cuisinier : onglets À préparer / En cours / Prêts.
- Responsive : poste caisse dès 900 px (tablette paysage, 2 colonnes), ordinateur et grand écran (3 colonnes) ; vérifié de 360 à 1920 px pour les 5 rôles.
- Windows : application installable (PWA) via Edge / Chrome, bouton « Installer GesCo sur cet appareil » dans le menu, manifeste sans blocage en portrait, raccourcis (Commandes, Écran mural cuisine, Planning).

## v4.13 — Notifications push (application fermée)
- Abonnement Web Push par appareil (`push_subscriptions`, `gb_push_register` / `gb_push_unregister`), clés VAPID créées et gardées côté serveur (`gb_private.push_config`), fonction `gesco-push`.
- Déclencheurs en base (pg_net) : nouvelle commande, annulation demandée, Mobile Money à vérifier, commande validée, table confiée, bon cuisine, plat gardé disponible, plat prêt, plat à décider, demande de permission, relève de caisse, journée clôturée. Jamais à la personne qui fait l'action.
- Toucher la notification ouvre la bonne rubrique ; application rouverte après plus d'une minute : PIN ou empreinte. Déconnexion = désabonnement de l'appareil. Migration 022.


## v4.14 — Commande close après paiement, chacun son rôle en cuisine
- Une commande payée est close : plus de réouverture (même client ou même table → nouveau ticket). Erreur de saisie : la caisse supprime le ticket (trace au journal).
- Après l'envoi, le ticket n'affiche que les articles choisis ; « + Ajouter ou corriger un article » rouvre le catalogue tant que la commande n'est pas payée.
- Seul le cuisinier fait avancer les bons (Commencer, Prêt, plat gardé, décision sur un plat annulé). Caisse et direction voient la cuisine en direct, sans agir. La serveuse (ou la cheffe de salle) confirme le retrait.
- La caisse confirme toujours les paiements Mobile Money par QR des serveuses.
- Migration `023_roles_cuisine_commande_close.sql`.

## v4.15 — Formule test cachée
- `bars.sub_test_price` (réglé par l'éditeur en SQL uniquement, 100 à 5 000 FCFA) : le paiement sur téléphone facture ce montant pour 1 mois de la formule choisie ; le transfert et les autres durées sont masqués.
- Après un paiement réussi, le prix de test s'efface tout seul. Les paiements test sont marqués « test » dans l'historique et le journal de l'éditeur.
- Activé pour Bring win (200 FCFA). Migration `024_formule_test_cachee.sql`.

## v4.16 — Suspension : motif, demande de réactivation avec preuves
- Console éditeur : motif de suspension affiché au bar (la « Note interne » reste privée) ; réactiver clôt la demande et prévient le bar ; pièces jointes visibles dans Assistance ; contact téléphone / WhatsApp affiché aux bars (Réglages).
- Écran « Accès suspendu » : motif, date ; PDG et directeur envoient la demande de réactivation (message, jusqu'à 5 photos ou PDF dans le stockage privé `preuves`, numéro WhatsApp), suivent la réponse de BISMO Agency sur le même écran ; boutons Appeler / WhatsApp. L'application se rouvre seule après réactivation.
- Notifications bloquées : bouton « Débloquer les notifications » avec les étapes selon l'appareil.
- Migration `025_reactivation_suspension.sql`.

## v4.17 — Fiabilité : sauvegardes, tests, remontée des erreurs, confidentialité
- **Sauvegardes** (`.github/workflows/sauvegarde.yml`) : chaque nuit, copie complète (rôles, structure, données) chiffrée AES-256, gardée 30 jours comme artefact, puis restaurée dans une base vide pour la vérifier. À activer avec les secrets `SUPABASE_DB_URL` (Session pooler) et `BACKUP_PASSPHRASE`.
  Restaurer : télécharger l'artefact, `gpg -d gesco-sauvegarde.tar.gz.gpg > copie.tar.gz && tar -xzf copie.tar.gz`, puis
  `psql "<base cible>" --single-transaction -v ON_ERROR_STOP=1 -f copie/roles.sql -f copie/schema.sql -c "SET session_replication_role = replica" -f copie/data.sql`.
  Les fichiers du stockage (photos, preuves, pièces d'identité) ne sont pas dans cette copie.
- **Tests** (`.github/workflows/tests.yml`) : `node tests/ui.cjs` (15 scénarios sur la démo, chaque rôle, téléphone et ordinateur) et `tests/serveur.sql` (règles du serveur sur la vraie base, transaction annulée). Le CI vérifie aussi que `dist/` est à jour.
- **Erreurs** : les plantages de l'application et de la console remontent dans la console éditeur (onglet Erreurs), regroupés, effacés après 30 jours. Migration `026_remontee_erreurs.sql`.
- **Légal** : page `/confidentialite`, conditions générales mises à jour (paiement sur téléphone, suspension et réactivation).

## v4.18 — Alertes et écran blanc
- **Erreurs hors réseau** : gardées sur l'appareil (20 au plus) et envoyées au retour du réseau.
- **Alertes de l'éditeur** : console → Réglages → « Alertes sur cet appareil ». Notification à chaque nouvelle erreur (ou erreur revenue après correction), application qui ne démarre pas, site en panne. 12 alertes par heure au plus. Abonnements séparés de ceux du personnel (`gb_private.admin_push`). Migration `027_alertes_editeur.sql`, fonction `gesco-push` (option `admins`).
- **Écran blanc** : une garde indépendante du code principal détecte un démarrage raté (bibliothèque non chargée, erreur au lancement, 25 s sans affichage), prévient l'éditeur et propose « Réessayer » / « Réparer l'application » (vide le cache et le service worker, garde les données locales).
- **Surveillance** (`.github/workflows/surveillance.yml`, `tests/surveillance.cjs`) : après chaque envoi, attend que la nouvelle version soit en ligne et vérifie qu'elle démarre ; toutes les 2 h, vérifie application, console, fonctions serveur et base. Panne → erreur « Surveillance du site » dans la console + alerte.
