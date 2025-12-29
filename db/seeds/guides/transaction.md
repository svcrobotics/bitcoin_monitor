---
app_label: "Voir le wallet A/B (ex: #10)"
app_path: "/vaults/10"
---

## Fun

Imagine que tu paies un café à **3 €** avec un billet de **10 €**.

Tu ne peux pas :
- découper le billet
- donner exactement 3 €

👉 Le commerçant te rend **7 €**.

En Bitcoin, c’est **exactement pareil**.

Quand tu dépenses des bitcoins :
- tu consommes des “billets” entiers (UTXOs)
- si le montant est plus grand que ce que tu veux payer
- la différence te revient sous forme de **change**

🧠 **Bitcoin ne rend jamais la monnaie en pièces**,  
il crée **un nouveau billet**.

---

## Didactique

### 1) Un UTXO est indivisible

Un UTXO (*Unspent Transaction Output*) est :
- créé lors d’une réception
- dépensé **en entier** lors d’une transaction

Tu ne peux pas dire :
> “Je prends juste une partie de cet UTXO”

Quand tu dépenses :
- l’UTXO disparaît
- de nouveaux UTXOs sont créés

---

### 2) Une transaction = plusieurs sorties

Une transaction Bitcoin contient :
- **des entrées** (UTXOs consommés)
- **des sorties** (nouveaux UTXOs)

Dans une dépense classique, Sparrow crée au minimum :

1. Une sortie vers le destinataire
2. Une sortie de **change** vers ton wallet

Exemple conceptuel :

- Entrée : `0.01000000 BTC`
- Sortie 1 : `0.00300000 BTC` → destinataire
- Sortie 2 : `0.00690000 BTC` → change
- Différence : frais de transaction

👉 Le change n’est **pas une option**,  
👉 il est **obligatoire** dès que le montant n’est pas exact.

---

### 3) Pourquoi le change va sur une autre adresse ?

Pour la **confidentialité**.

Si le change revenait :
- sur la même adresse
- ou sur l’adresse d’origine

Alors n’importe qui pourrait :
- lier tes transactions entre elles
- estimer ton solde
- reconnaître ton wallet

👉 Sparrow utilise donc une branche dédiée au change.

---

## Technique

### A) Receive vs Change (branches HD)

Un wallet HD possède deux branches principales :

- `/0/*` → **Receive** (adresses à partager)
- `/1/*` → **Change** (adresses internes)

Quand tu envoies des fonds depuis Sparrow :
- la sortie principale va vers une adresse externe
- la sortie de change va vers `/1/N`

Cette adresse de change :
- est générée automatiquement
- n’est généralement jamais montrée à l’utilisateur
- fait pleinement partie de ton wallet

---

### B) Ce que fait Bitcoin Monitor

Bitcoin Monitor est un **wallet observer** (*watch-only*).

Il :
- dérive les adresses `/0/*` et `/1/*`
- scanne la blockchain
- observe les UTXOs associés

Après une dépense :
- certains UTXOs disparaissent
- un nouvel UTXO de change apparaît
- le solde est recalculé

👉 Si l’app ne surveille pas `/1/*`,  
👉 le solde devient faux après la première dépense.

---

### C) Test concret

1. Dans Sparrow :
   - effectue une **dépense partielle** (pour forcer le change)
2. Dans Bitcoin Monitor :
   - lance un **Rescan**
3. Observe :
   - disparition des anciens UTXOs
   - apparition d’un UTXO sur une adresse `/1/*`
   - mise à jour du solde

:::cmd
bin/rails runner \
'v=Vault.find(10);
 r=VaultUtxoScanner.new(v).scan_and_persist!;
 puts [r.total_sats, r.utxos.size].inspect'
:::

---

## 🧠 À retenir

- Bitcoin ne “soustrait” pas des montants  
- Il **détruit et recrée** des UTXOs
- Le change est **normal, automatique et indispensable**
- La branche `/1/*` est aussi importante que `/0/*`
- Un watch-only sérieux doit surveiller **les deux**

