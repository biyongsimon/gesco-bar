// Base de connaissances de l'assistant GesCo Bar. À enrichir avec les questions réelles des clients.
export const KB = `# GesCo Bar : guide complet (référence de l'assistant)

GesCo Bar est une application de gestion de bars et snacks au Cameroun, éditée par BISMO Agency (Ngousso, Yaoundé).
Adresse : https://gescobar-cm.pages.dev (l'ancienne adresse gescobar-cm.netlify.app redirige vers elle). Elle s'utilise dans le navigateur du téléphone et s'installe comme une application (« Ajouter à l'écran d'accueil »).
Elle fonctionne aussi sans réseau pour les gestes de la serveuse (tickets, quantités, envoi, encaissement) : tout est envoyé au retour du réseau.

## Les 5 rôles
- PDG : créateur du bar. Supervise sans opérer : Accueil (vue d'ensemble), Paie, Compta, Équipe, Ventes, Revenus, Présences, Planning, Journée (rapports), Journal, Abonnement, Réglages. Il ne valide pas les paiements des tickets et ne clôture pas la journée.
- Directeur : supervise le service. Supervision (commandes envoyées, servies ou en retard de plus de 10 min), Présences (présent, retard, absent, permission, repos), Planning, Équipe (ajoute caissières et serveuses), Ventes, Journal, Abonnement, Mon espace. Il ne valide aucun paiement.
- Caisse (caissière) : Commandes (commandes envoyées, versements des serveuses, Mobile Money à vérifier, reliquats, annulations, vente au comptoir, dotations de bouteilles), Stock (inventaire, approvisionnement, carte des produits, prix), Bons, Ventes, Journée (clôture), Planning, Mon espace.
- Serveuse : Service (ses tickets), Paiement QR, Planning, Mon espace (pointage, permissions, fiches de paie).
- Cheffe de salle : une serveuse nommée par le directeur ou le PDG (Équipe → « Nommer cheffe de salle »). Elle garde ses propres tables, voit toutes les tables de la salle (onglet « Salle » dans Service), peut « Prendre » une table ou la « Confier à… » une autre serveuse. Son nom s'affiche en haut des écrans de la caisse, de la direction et des serveuses (★ Cheffe). On peut en nommer plusieurs (une de jour, une de nuit).
- Cuisine (cuisinier) : Cuisine (écran des bons), Planning, Mon espace. Rôle disponible quand le module Cuisine est activé (formule Snack Gold et plus).
- À chaque ouverture de l'application, chacun arrive sur le premier onglet de son espace.

## Connexion
- Personnel : saisir le code du bar (6 caractères, ex. K7P2QM), toucher son nom, taper son PIN (4 à 6 chiffres).
- PDG : aussi avec son e-mail et son mot de passe (onglet « Propriétaire »).
- Le code du bar est visible dans le menu de l'application (PDG et directeur : rubrique Équipe, avec un QR code d'installation).
- 5 PIN faux bloquent le compte 5 minutes.
- PIN oublié : le PDG ou le directeur le change dans Équipe (champ « Nouveau PIN » puis Enregistrer). Le directeur gère les PIN des caissières et serveuses ; seul le PDG change le PIN d'un directeur ; le PDG change son propre PIN lui-même.
- Mot de passe du PDG oublié : la réinitialisation par e-mail n'est pas encore disponible ; il peut se connecter avec son PIN (onglet Personnel) ; sinon transmettre à BISMO Agency.
- Verrouillage : après 1 minute sans toucher l'écran, l'application se verrouille ; on retape son PIN. 5 PIN faux = déconnexion. « Ce n'est pas moi » permet de changer d'utilisateur.

## Ticket et service (serveuse)
1. « Nouveau ticket » : nom du client ou repère de table (ex. Table du manguier).
2. Ajouter les boissons et quantités (boutons + et −). On peut modifier ou supprimer un brouillon.
3. « Envoyer à la caisse » : la caissière reçoit la commande avec une alerte sonore.
4. Après le service : « Commande servie au client » (le directeur le voit).
5. Encaisser : espèces (indiquer le billet reçu ; la monnaie à rendre est calculée) ou Mobile Money.
6. Remettre l'argent à la caissière ; elle valide le versement. La serveuse est prévenue par une notification quand la caisse valide.
- Après l'envoi, la serveuse ne supprime plus : elle demande l'annulation, la caisse accepte ou refuse.
- La caisse ne peut jamais modifier la commande d'une serveuse.
- Reliquat : si la caisse n'a pas de monnaie, elle émet un bon de reliquat (code de vérification + QR). Le bon se vérifie dans Bons et ne peut servir qu'une fois.
- Stock en main : la caisse donne des bouteilles aux serveuses (dotation) ; chaque vente les décompte.

## Paiement Mobile Money
- QR code (rubrique Paiement QR de la serveuse) : le PDG saisit d'abord ses codes marchands Orange Money / MTN MoMo dans Réglages → Paiements. Le QR contient le code de paiement avec le montant du ticket ; le client le scanne avec l'appareil photo, son téléphone compose le code, il valide avec son code secret. Puis la serveuse touche « Le client a payé : prévenir la caisse » et la caisse confirme.
- QR automatique (quand le PDG a collé la clé Notch Pay du bar) : le QR ouvre une page de paiement ; le client choisit Orange Money ou MTN MoMo et valide avec son code secret ; l'écran de la serveuse affiche « En attente de validation » puis « Commande payée ! » avec des feux d'artifice, et le ticket passe payé tout seul, sans intervention de la caisse.
- Sur iPhone, le scan d'un code USSD peut ne pas composer automatiquement : le client tape le code affiché sous le QR.
- Paiement par numéro : la serveuse saisit le numéro du client ; il reçoit une demande sur son téléphone et la valide avec son code secret ; le ticket passe payé automatiquement. Nécessite que le PDG ait un compte marchand Notch Pay et colle sa clé dans Réglages → Paiements. La serveuse ne voit jamais le code secret du client.
- Les codes USSD marchands par défaut sont modifiables dans Réglages : vérifier auprès de l'opérateur.

## Caisse : journée et stock
- Clôture : rubrique Journée, saisir les espèces comptées, « Clôturer la journée ». Seule la caissière clôture. Le PDG reçoit le rapport et une notification. Une journée commence et se termine à 6 h du matin (heure de Douala) : les ventes après minuit comptent sur la veille.
- Tickets non soldés : la clôture les signale ; il faut les régler ou forcer.
- Photos des produits : toucher la vignette d'un produit dans Stock pour choisir une photo de la photothèque GesCo ou prendre/choisir sa propre photo. « Ajouter un produit à la carte » : toucher une bouteille de la photothèque remplit le nom, la catégorie et la photo.
- Réapprovisionnement intelligent (Stock, en haut) : GesCo calcule le rythme de vente de chaque produit (14 derniers jours), les jours restants avant rupture et la quantité à commander pour tenir N jours (7 par défaut), arrondie au casier. Alerte rouge quand le stock passe sous la moitié du minimum. « Règle » sur un produit : stock minimum et taille du casier/carton.
- Bons de commande : « Créer le bon de commande » regroupe les quantités conseillées ; l'envoyer au fournisseur sur WhatsApp ; à la livraison, « Réceptionner » ajoute les quantités reçues au stock et le prix d'achat entre dans la compta.
- Stock : Approvisionner (quantité + prix d'achat), Inventaire (compter et corriger les écarts), carte libre (bières, vins, whisky, sucreries, cuisine...). Vente au verre : « Ouvrir une bouteille » transforme une bouteille en verres.

## Planning, présences, permissions, paie
- Planning automatique (directeur, PDG) : bouton « Générer la semaine automatiquement » dans Planning. Régler les horaires d'ouverture de chaque jour (ou Fermé), le nombre de serveuses par jour (proposé selon l'affluence réelle des 8 dernières semaines, « Recalculer selon l'affluence »), 1 ou 2 jours de repos par employé, et l'option équipe d'ouverture / équipe de fermeture pour les soirées de plus de 9 h. « Voir la proposition » montre la semaine, les heures de chacun et les points à surveiller ; « Appliquer au planning » l'enregistre. Les permissions accordées sont respectées, les repos tournent d'une semaine à l'autre et tombent de préférence les jours calmes. Chaque case reste modifiable ensuite.
- Deux équipes (jour et nuit) : dans le planning automatique, activer « Deux équipes », choisir l'heure de relève (ex. 18 h) et le nombre de serveuses de jour et de nuit pour chaque jour ; option « Alterner jour et nuit chaque semaine ». Un rôle tenu par une seule personne (caissière, cuisinier) est placé sur l'équipe de nuit et un point à surveiller s'affiche.
- Relève entre équipes : la journée de caisse reste de 6 h à 6 h, découpée en services. La caissière qui part va dans Journée → « Relève de caisse », compte le tiroir et touche « Passer la main » : le bilan de son service s'affiche (ventes, versements, Mobile Money, écart de son service). La caissière qui arrive confirme « fond de caisse vérifié » (bandeau dans Commandes). Le rapport de clôture reprend chaque service.
- Départ d'une serveuse : elle ne peut pas pointer son départ en laissant une table ouverte ou de l'argent non versé. Elle confie ses tables (sur le ticket : « Confier cette table à une collègue », ou par la cheffe de salle), verse ses espèces et rend ses bouteilles. Le client ne voit rien ; les plats en cuisine suivent la table.
- Planning : fait par le directeur (ou le PDG), visible par tous. Toucher une case pour fixer l'horaire ou le repos ; « Copier la semaine d'avant » ; « Partager sur WhatsApp » (image ou texte).
- Pointage : chacun pointe son arrivée et son départ (Mon espace ou bandeau du jour). Retard compté au-delà de 10 minutes. Le directeur est notifié.
- Permissions : serveuses et caisse demandent au directeur ; le directeur demande au PDG. Personne ne valide sa propre demande.
- Paie (PDG) : fixer le salaire de base, prime, retenue (une retenue est suggérée selon les absences), payer ; la dépense entre dans la compta ; l'employé voit sa fiche de paie.
- Compta (PDG) : rapport du mois automatique (PDF imprimable et CSV), dépenses, indications fiscales (IGS en dessous de 50 millions de FCFA de chiffre d'affaires annuel). Ce n'est pas un conseil fiscal : consulter un comptable.

## Module Cuisine (Snack Gold et plus)
- Activation : le PDG, dans Réglages → Module Cuisine. Puis ajouter le cuisinier dans Équipe avec le rôle « Cuisine ».
- Les plats sont les produits de catégorie « Cuisine » (ou vendus au plat / à la portion). La serveuse les ajoute au ticket comme une boisson ; à l'envoi, chaque plat part sur l'écran Cuisine avec un numéro de bon, la table, la serveuse (bande de couleur à son nom) et le temps d'attente (rouge après 15 min).
- Écran mural de la cuisine : sur la TV ou la tablette fixée en cuisine, ouvrir Cuisine → « Ouvrir l'écran mural » (connecté avec le compte du cuisinier ou de la caisse). Tous les bons en très grand, horloge, son à chaque nouvelle commande ; l'écran ne se verrouille pas et ne se met pas en veille ; il se rouvre tout seul après un redémarrage. « Quitter l'écran mural » pour revenir. Le cuisinier valide « Commencer » / « Prêt ✓ » depuis son téléphone (onglets À préparer, En cours, Prêts) ou directement sur la tablette tactile.
- Le cuisinier touche « Commencer » puis « Prêt ✓ ». Seule la serveuse de la table est prévenue (son et notification) ; sur son ticket, elle touche « Je l'ai récupéré ». La caisse et la direction voient aussi l'écran Cuisine.
- Recettes : dans Stock, ouvrir un plat (Modifier) → Recette : ajouter les ingrédients (catégorie « Ingrédients », unité g, ml ou pièce) et la quantité pour 1 plat. À chaque plat envoyé, les ingrédients sortent du stock ; le prix d'achat du plat est calculé par la recette (marge affichée).
- Annulation : un plat annulé avant que la cuisine l'ait commencé est simplement annulé (ses ingrédients comptés reviennent). Un plat déjà commencé ne revient jamais en stock : il apparaît en haut de l'écran Cuisine (« Plats annulés après préparation ») et la cuisine ou la caisse choisit : Revendre (le plat est gardé au chaud pendant 6 h ; quand une serveuse commande le même plat, le bon arrive normalement mais le cuisinier est alerté « ♻ plat gardé » et peut toucher « Servir le plat gardé » : le bon passe aussitôt en « Prêt » ; sinon il cuisine un plat neuf), Repas du personnel, ou Perte (avec un motif ; son coût entre dans les pertes du jour et le rapport de clôture). Un plat déjà en préparation ne peut plus être retiré par la serveuse : la caisse annule.
- Courses du marché (écran Cuisine, pour la cuisine, la caisse et la direction) : on note les achats en gros du jour (article, quantité libre comme « 2 seaux », montant, espèces ou Mobile Money). Ils entrent dans les dépenses de la compta. Pas besoin de peser chaque plat : la recette est facultative et ne sert que pour ce qui se compte à la pièce (poisson, poulet, gigot, paquets de spaghetti). Pour chaque plat on peut saisir un « prix de revient estimé » : la marge s'affiche.
- Catalogue de plats (Stock → « Ajouter un plat à la carte ») : plats camerounais (poulet DG, ndolé, eru, mbongo tchobi, koki, okok, taro…), plats de restaurant (spaghetti bolognaise, tagliatelles carbonara, tranches de gigot d'agneau, steak frites…) et accompagnements ; on touche un plat, on met son prix et « Ajouter à la carte ».
- Les ingrédients n'apparaissent pas chez les serveuses ; ils sont dans le réapprovisionnement intelligent (consommation de la cuisine comprise).

## Donner son avis
- Menu de l'application → « Donner mon avis » : note de 1 à 5 étoiles, sujets (facile, rapide, il manque une fonction, bug…) et message libre. L'avis est lu par BISMO Agency, pas par le patron du bar. Possible même si l'abonnement est expiré.

## Notifications
- Caisse : nouvelle commande, annulation demandée, Mobile Money à vérifier, paiement reçu. Serveuse : commande validée, monnaie prête, bon émis. Cuisine : nouvelle commande de plat. Serveuse : plat prêt en cuisine (seulement pour ses tables). Directeur : pointages, demandes de permission. PDG : journée clôturée, demande du directeur.
- Son : toucher l'écran une fois après l'ouverture (le téléphone bloque le son sinon) ; « Tester le son » dans le menu ; activer les notifications quand l'application le propose ; vérifier que le téléphone n'est pas en silencieux.
- Notifications push : une fois les notifications autorisées (menu → « Activer les notifications »), elles arrivent dans la barre du téléphone même application fermée (Android, ordinateur Windows avec Chrome/Edge ; sur iPhone il faut d'abord installer GesCo sur l'écran d'accueil et l'ouvrir depuis l'icône). Toucher la notification ouvre GesCo sur la bonne rubrique ; si l'appareil n'a pas servi depuis plus d'une minute, le PIN (ou l'empreinte) est demandé. « Se déconnecter » arrête les notifications sur cet appareil ; fermer l'application les garde. Chaque appareil reçoit les notifications de la dernière personne qui s'y est connectée.

## Abonnement (PDG et directeur, rubrique Abonnement)
- Formules mensuelles : Snack Simple 10 000 FCFA (1 caisse, 3 serveuses, pas de directeur) ; Snack Premium 15 000 FCFA (2 caisses, 6 serveuses, pas de directeur ; planning, présences, QR) ; Snack Gold 20 000 FCFA (12 employés avec directeur ; paie, compta, paiement par numéro) ; Lounge 30 000 FCFA (illimité, assistance prioritaire). 12 mois = 10 mois payés. Les bars créés pendant la bêta sont gratuits.
- Payer : choisir formule et durée, envoyer le montant par transfert Orange Money ou MTN MoMo au numéro affiché, avec le motif GB-<code du bar>, puis coller la référence du SMS ou envoyer la capture du SMS et toucher « Activer mon abonnement ». La formule s'active tout de suite pendant 72 h, le temps que BISMO Agency vérifie la réception.
- Paiement direct (« Sur mon téléphone », quand il est proposé) : choisir formule et durée, saisir son numéro Orange Money ou MTN MoMo, toucher « Recevoir la demande » ; une demande de paiement s'affiche sur le téléphone, taper son code secret ; la formule s'active automatiquement dès la confirmation, sans capture à envoyer. Si rien ne s'affiche : téléphone déverrouillé, solde suffisant, ou ouvrir le menu Orange Money / MTN MoMo (paiements en attente). Bouton « J'ai validé : vérifier maintenant ». Une demande non validée expire après 15 minutes.
- Limite d'employés atteinte : passer à la formule supérieure.
- Fin d'abonnement : rappel 7 jours avant ; 3 jours de grâce après la date de fin ; ensuite l'application est bloquée pour l'équipe, mais le PDG et le directeur peuvent toujours payer dans Abonnement : tout se rouvre dès l'envoi de la preuve. Les données ne sont jamais effacées.
- Bar suspendu : seul BISMO Agency peut le rétablir.
- Essai gratuit (formule « Essai gratuit ») : toutes les fonctions sont offertes jusqu'à la date indiquée dans Abonnement. Rappel les 7 derniers jours. À la fin (+3 jours de grâce), l'application se bloque pour l'équipe tant qu'aucune formule n'est payée. On peut payer avant la fin : les jours d'essai restants sont conservés, l'abonnement commence à la fin de l'essai.
- Reçu d'abonnement : dans Abonnement → Historique, bouton Reçu (imprimable ou WhatsApp).

## Sur ordinateur (poste caisse)
- Sur un écran large (ordinateur portable ou de bureau), l'application passe en « poste caisse » : menu à gauche toujours visible ; Commandes sur 3 colonnes (à traiter et versements / commandes en cours / cuisine en direct et vente au comptoir) ; chiffres du jour en haut.
- Raccourcis clavier : / pour chercher, N pour une vente au comptoir, 1 à 9 pour changer de rubrique, Échap pour fermer une fenêtre.
- Le même affichage s'applique aux tablettes en paysage (à partir de 900 px de large, sur 2 colonnes).
- Le téléphone garde son affichage habituel.
- Installer sur un ordinateur Windows : ouvrir le lien dans Microsoft Edge ou Google Chrome, puis cliquer sur l'icône « Installer » dans la barre d'adresse (ou Menu de GesCo → « Installer GesCo sur cet appareil »). GesCo s'ouvre ensuite dans sa propre fenêtre, depuis le menu Démarrer et la barre des tâches, fonctionne sans réseau et se met à jour tout seul. Clic droit sur l'icône : raccourcis « Commandes (caisse) », « Écran mural cuisine », « Planning ».

## Installation sur le téléphone
- Android (Chrome) : ouvrir le lien, menu ⋮ → « Ajouter à l'écran d'accueil » ou « Installer l'application ».
- iPhone (Safari) : bouton Partager → « Sur l'écran d'accueil ».
- Le PDG ou le directeur peut montrer le QR d'installation (Équipe) : scanner avec l'appareil photo ouvre l'application avec le code du bar déjà rempli.
- Mises à jour : elles s'installent toutes seules, l'application se recharge d'elle-même (quand personne n'est en train de saisir). Si un écran semble ancien, fermer complètement l'application puis la rouvrir.

## Problèmes fréquents
- « Session expirée » ou écran qui ne charge pas : vérifier le réseau, fermer et rouvrir l'application, se reconnecter.
- « Hors ligne » : les tickets sont gardés et envoyés au retour du réseau ; ne pas se déconnecter tant que l'envoi n'est pas terminé.
- Produit absent de la liste : la caisse l'ajoute dans Stock (carte des produits) ou le réactive.
- Stock en main insuffisant : demander une dotation à la caisse.
- Un employé ne peut pas être désactivé s'il a des tickets non soldés ou des bouteilles en main : régler d'abord.
- Écart de caisse : vérifier les versements des serveuses et les reliquats dans Commandes et Journée.
`;
