

## Fun

Imagine que tu donnes :
- la **clé de ta maison**
- ou simplement que tu **montres ta carte d’identité**

Dans les deux cas, on sait que c’est toi.

Mais :
- avec la clé → on peut **entrer chez toi**
- avec la carte → on peut juste **vérifier ton identité**

👉 En Bitcoin, c’est exactement pareil.

- une **clé privée** = la clé de ta maison
- une **signature** = ta carte d’identité cryptographique

Confondre les deux,  
c’est ouvrir la porte au pire.

---

## Didactique

### 1) Une signature ne donne jamais accès aux fonds

Quand tu signes un message Bitcoin :
- tu **prouves** que tu contrôles une clé
- tu **ne révèles jamais** cette clé

La signature sert uniquement à :
- s’authentifier
- prouver une propriété
- valider une action hors transaction

👉 Aucune signature ne permet de voler des bitcoins.

---

### 2) Ce qui permet réellement de voler des bitcoins

Pour déplacer des fonds, il faut :
- la **clé privée**
- ou la **seed phrase**

Ces informations permettent :
- de signer **des transactions**
- de dépenser **sans limite**

👉 Toute personne qui possède la seed  
👉 possède les bitcoins.

---

### 3) Pourquoi une app sérieuse ne demande jamais la seed

Une application sécurisée :
- n’a **pas besoin** de ta clé privée
- n’a **pas besoin** de ta seed
- ne voit jamais tes fonds

Elle se contente de :
- messages signés
- preuves cryptographiques
- données publiques (blockchain)

👉 Bitcoin Monitor fonctionne ainsi.

---

## Technique

### A) Ce qu’il ne faut JAMAIS divulguer

❌ À ne jamais partager :
- seed phrase (12 / 18 / 24 mots)
- clé privée (WIF, hex, fichier)
- QR code de seed
- sauvegarde cloud / photo / email

Même à :
- un développeur
- un support
- un “admin”
- un proche

---

### B) Ce qui peut être partagé sans risque

✅ Peut être partagé :
- une **adresse publique**
- une **signature de message**
- un **xpub** (dans certains contextes maîtrisés)

Mais attention :
- une adresse révèle ton activité
- un xpub révèle toute ta structure

👉 Partager ≠ sans conséquence.

---

### C) Multisig : la sécurité repose sur la séparation

Dans un wallet A + B :

- Clé A compromise → rien ne se passe
- Clé B compromise → rien ne se passe
- A + B ensemble → fonds accessibles

❌ Mauvaise pratique :
- stocker A et B au même endroit
- transporter les deux Ledger ensemble
- utiliser A + B pour des actions triviales

✅ Bonne pratique :
- A pour login / usage courant
- B stockée ailleurs, hors ligne
- A + B uniquement pour dépenser

---

### D) Messages à signer : vigilance absolue

Avant de signer :
- lis **intégralement** le message
- comprends le contexte
- vérifie le domaine / l’application

Ne signe jamais :
- un message flou
- un message reçu par DM
- un message “urgent”
- un message hors interface connue

👉 Signer, c’est **s’engager cryptographiquement**.

---

### E) Sécurité physique (souvent oubliée)

Les attaques réelles sont souvent :
- physiques
- psychologiques
- basées sur la pression

Bonnes pratiques :
- ne pas divulguer ses avoirs
- ne pas centraliser infos + accès
- prévoir des clés séparées
- éviter triggering / urgence

👉 La meilleure attaque n’est pas technique.

---

## 🧠 À retenir

- Une signature ≠ une clé privée
- Une seed = accès total aux fonds
- Une app sérieuse ne demande jamais la seed
- Multisig = séparation physique et logique
- La sécurité est **opérationnelle**, pas théorique

👉 Comprendre, c’est déjà se protéger.
