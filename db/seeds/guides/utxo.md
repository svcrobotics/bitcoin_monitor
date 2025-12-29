---
app_label: "Voir le wallet A/B (ex: #10)"
app_path: "/vaults/10"
---

## Fun

Imagine que ton portefeuille contient :
- 1 billet de **100 €**
- ou bien **100 pièces de 1 €**

Dans les deux cas, tu as **100 €**.

Mais :
- payer un café avec 100 pièces prend du temps
- compter, transporter, sécuriser devient pénible

👉 En Bitcoin, c’est exactement pareil.

Un wallet peut avoir :
- peu d’UTXOs “gros”
- ou beaucoup d’UTXOs “petits”

Et même si le solde est identique,  
**le comportement du wallet change complètement**.

---

## Didactique

### 1) Un wallet n’a pas un solde, il a des UTXOs

Le “solde” affiché par Sparrow ou Bitcoin Monitor est :
> **la somme de tous les UTXOs**

Mais Bitcoin ne manipule jamais un solde global.

Il manipule uniquement :
- des **UTXOs indépendants**
- créés et détruits par les transactions

---

### 2) Pourquoi un wallet accumule des UTXOs

Ton wallet peut accumuler beaucoup d’UTXOs si :

- tu reçois souvent des paiements
- tu utilises Lightning / on-chain mixé
- tu fais des dons, rewards, faucets
- tu utilises un wallet longtemps sans consolider

Chaque réception crée :
- **un nouvel UTXO**
- sur une nouvelle adresse

👉 Plus tu reçois, plus tu accumules.

---

### 3) Beaucoup d’UTXOs = plus de données à dépenser

Quand tu dépenses un montant important :
- Sparrow doit sélectionner **plusieurs UTXOs**
- chacun devient une **entrée** de la transaction

Conséquence directe :
- plus d’entrées = transaction plus grosse
- transaction plus grosse = **frais plus élevés**

👉 Ce n’est pas le montant qui coûte cher,  
👉 c’est le **nombre d’UTXOs consommés**.

---

## Technique

### A) Taille d’une transaction

Une transaction Bitcoin contient :
- des **inputs** (UTXOs dépensés)
- des **outputs** (nouveaux UTXOs)

Chaque input ajoute :
- des données
- une signature
- du poids (vbytes)

Exemple simplifié :

- 1 input → ~68 vbytes
- 5 inputs → ~340 vbytes
- 10 inputs → ~680 vbytes

👉 Les frais = `vbytes × sat/vbyte`

---

### B) Sélection des UTXOs (coin selection)

Sparrow utilise des stratégies de sélection :
- éviter trop d’inputs
- préserver la confidentialité
- limiter le change excessif

Mais il ne peut pas :
- fusionner les UTXOs magiquement
- ignorer ceux nécessaires au montant

👉 Si ton wallet a 100 petits UTXOs,  
👉 il devra en consommer beaucoup.

---

### C) Ce que voit Bitcoin Monitor

Bitcoin Monitor observe :
- la disparition de nombreux UTXOs
- la création :
  - d’un UTXO vers le destinataire
  - d’un UTXO de change (souvent plus gros)

Après une grosse dépense :
- le nombre d’UTXOs diminue
- le wallet devient “plus propre”
- mais les frais ont été plus élevés

---

### D) Consolider des UTXOs

La **consolidation** consiste à :
- dépenser plusieurs petits UTXOs
- vers **une seule adresse de ton wallet**

Résultat :
- moins d’UTXOs
- transactions futures moins chères
- mais **une transaction payée maintenant**

👉 À faire :
- quand les frais sont bas
- pas dans l’urgence

---

### E) Test concret

1. Observe dans Bitcoin Monitor :
   - nombre d’UTXOs avant dépense
2. Fais une dépense importante dans Sparrow
3. Rescan dans l’app
4. Compare :
   - UTXOs avant / après
   - taille de la transaction
   - frais payés

:::cmd
bin/rails runner \
'v=Vault.find(10);
 r=VaultUtxoScanner.new(v).scan_and_persist!;
 puts "utxos=#{r.utxos.size} sats=#{r.total_sats}"'
:::

---

## 🧠 À retenir

- Un wallet = une collection d’UTXOs
- Le solde n’est qu’une somme
- Beaucoup d’UTXOs = transactions plus chères
- Consolider réduit les coûts futurs
- Un bon wallet se **gère dans le temps**

