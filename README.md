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

Chaque espace a une barre de navigation en bas, un menu complet et une recherche (clients, tickets, boissons, employés, bons). Le planning est visible par tout le monde.

Démo : code DEMO ; PIN serveuses 1111 / 2222 / 3333, caisse 0000, directeur 5555, PDG 9999.

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
