// Base de connaissances de l'assistant GesCo Bar. À enrichir avec les questions réelles des clients.
export const KB = `# GesCo Bar : guide complet (référence de l'assistant)

GesCo Bar est une application de gestion de bars et snacks au Cameroun, éditée par BISMO Agency (Ngousso, Yaoundé).
Adresse : https://gescobar-cm.pages.dev (l'ancienne adresse gescobar-cm.netlify.app redirige vers elle). Elle s'utilise dans le navigateur du téléphone et s'installe comme une application (« Ajouter à l'écran d'accueil »).
Elle fonctionne aussi sans réseau pour les gestes de la serveuse (tickets, quantités, envoi, encaissement) : tout est envoyé au retour du réseau.

## Les 4 rôles
- PDG : créateur du bar. Supervise sans opérer : Accueil (vue d'ensemble), Paie, Compta, Équipe, Ventes, Revenus, Présences, Planning, Journée (rapports), Journal, Abonnement, Réglages. Il ne valide pas les paiements des tickets et ne clôture pas la journée.
- Directeur : supervise le service. Supervision (commandes envoyées, servies ou en retard de plus de 10 min), Présences (présent, retard, absent, permission, repos), Planning, Équipe (ajoute caissières et serveuses), Ventes, Journal, Abonnement, Mon espace. Il ne valide aucun paiement.
- Caisse (caissière) : Commandes (commandes envoyées, versements des serveuses, Mobile Money à vérifier, reliquats, annulations, vente au comptoir, dotations de bouteilles), Stock (inventaire, approvisionnement, carte des produits, prix), Bons, Ventes, Journée (clôture), Planning, Mon espace.
- Serveuse : Service (ses tickets), Paiement QR, Planning, Mon espace (pointage, permissions, fiches de paie).

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
- Stock : Approvisionner (quantité + prix d'achat), Inventaire (compter et corriger les écarts), carte libre (bières, vins, whisky, sucreries, cuisine...). Vente au verre : « Ouvrir une bouteille » transforme une bouteille en verres.

## Planning, présences, permissions, paie
- Planning : fait par le directeur (ou le PDG), visible par tous. Toucher une case pour fixer l'horaire ou le repos ; « Copier la semaine d'avant » ; « Partager sur WhatsApp » (image ou texte).
- Pointage : chacun pointe son arrivée et son départ (Mon espace ou bandeau du jour). Retard compté au-delà de 10 minutes. Le directeur est notifié.
- Permissions : serveuses et caisse demandent au directeur ; le directeur demande au PDG. Personne ne valide sa propre demande.
- Paie (PDG) : fixer le salaire de base, prime, retenue (une retenue est suggérée selon les absences), payer ; la dépense entre dans la compta ; l'employé voit sa fiche de paie.
- Compta (PDG) : rapport du mois automatique (PDF imprimable et CSV), dépenses, indications fiscales (IGS en dessous de 50 millions de FCFA de chiffre d'affaires annuel). Ce n'est pas un conseil fiscal : consulter un comptable.

## Donner son avis
- Menu de l'application → « Donner mon avis » : note de 1 à 5 étoiles, sujets (facile, rapide, il manque une fonction, bug…) et message libre. L'avis est lu par BISMO Agency, pas par le patron du bar. Possible même si l'abonnement est expiré.

## Notifications
- Caisse : nouvelle commande, annulation demandée, Mobile Money à vérifier, paiement reçu. Serveuse : commande validée, monnaie prête, bon émis. Directeur : pointages, demandes de permission. PDG : journée clôturée, demande du directeur.
- Son : toucher l'écran une fois après l'ouverture (le téléphone bloque le son sinon) ; « Tester le son » dans le menu ; activer les notifications quand l'application le propose ; vérifier que le téléphone n'est pas en silencieux.
- Limite actuelle : les notifications arrivent quand l'application est ouverte ou en arrière-plan, pas quand elle est complètement fermée.

## Abonnement (PDG et directeur, rubrique Abonnement)
- Formules mensuelles : Snack Simple 10 000 FCFA (1 caisse, 3 serveuses, pas de directeur) ; Snack Premium 15 000 FCFA (2 caisses, 6 serveuses, pas de directeur ; planning, présences, QR) ; Snack Gold 20 000 FCFA (12 employés avec directeur ; paie, compta, paiement par numéro) ; Lounge 30 000 FCFA (illimité, assistance prioritaire). 12 mois = 10 mois payés. Les bars créés pendant la bêta sont gratuits.
- Payer : choisir formule et durée, envoyer le montant par transfert Orange Money ou MTN MoMo au numéro affiché, avec le motif GB-<code du bar>, puis coller la référence du SMS ou envoyer la capture du SMS et toucher « Activer mon abonnement ». La formule s'active tout de suite pendant 72 h, le temps que BISMO Agency vérifie la réception.
- Paiement direct (« Sur mon téléphone », quand il est proposé) : choisir formule et durée, saisir son numéro Orange Money ou MTN MoMo, toucher « Recevoir la demande » ; une demande de paiement s'affiche sur le téléphone, taper son code secret ; la formule s'active automatiquement dès la confirmation, sans capture à envoyer. Si rien ne s'affiche : téléphone déverrouillé, solde suffisant, ou ouvrir le menu Orange Money / MTN MoMo (paiements en attente). Bouton « J'ai validé : vérifier maintenant ». Une demande non validée expire après 15 minutes.
- Limite d'employés atteinte : passer à la formule supérieure.
- Fin d'abonnement : rappel 7 jours avant ; 3 jours de grâce après la date de fin ; ensuite l'application est bloquée pour l'équipe, mais le PDG et le directeur peuvent toujours payer dans Abonnement : tout se rouvre dès l'envoi de la preuve. Les données ne sont jamais effacées.
- Bar suspendu : seul BISMO Agency peut le rétablir.
- Essai gratuit (formule « Essai gratuit ») : toutes les fonctions sont offertes jusqu'à la date indiquée dans Abonnement. Rappel les 7 derniers jours. À la fin (+3 jours de grâce), l'application se bloque pour l'équipe tant qu'aucune formule n'est payée. On peut payer avant la fin : les jours d'essai restants sont conservés, l'abonnement commence à la fin de l'essai.
- Reçu d'abonnement : dans Abonnement → Historique, bouton Reçu (imprimable ou WhatsApp).

## Installation sur le téléphone
- Android (Chrome) : ouvrir le lien, menu ⋮ → « Ajouter à l'écran d'accueil » ou « Installer l'application ».
- iPhone (Safari) : bouton Partager → « Sur l'écran d'accueil ».
- Le PDG ou le directeur peut montrer le QR d'installation (Équipe) : scanner avec l'appareil photo ouvre l'application avec le code du bar déjà rempli.
- Après une mise à jour, fermer complètement l'application puis la rouvrir.

## Problèmes fréquents
- « Session expirée » ou écran qui ne charge pas : vérifier le réseau, fermer et rouvrir l'application, se reconnecter.
- « Hors ligne » : les tickets sont gardés et envoyés au retour du réseau ; ne pas se déconnecter tant que l'envoi n'est pas terminé.
- Produit absent de la liste : la caisse l'ajoute dans Stock (carte des produits) ou le réactive.
- Stock en main insuffisant : demander une dotation à la caisse.
- Un employé ne peut pas être désactivé s'il a des tickets non soldés ou des bouteilles en main : régler d'abord.
- Écart de caisse : vérifier les versements des serveuses et les reliquats dans Commandes et Journée.
`;
