---
app_label: "Voir le wallet A/B (ex: #10)"
app_path: "/vaults/10"
---

## Fun

Imagine que ton wallet Bitcoin est **un carnet de reçus**, pas un compte bancaire.

À chaque fois que tu donnes une adresse Bitcoin, c’est comme si tu donnais :
> “Tiens, écris-moi à cette page précise.”

Mais si tu donnais **toujours la même page**, n’importe qui pourrait :
- voir tout ce que tu reçois
- faire le total
- suivre ton activité

👉 Solution : **une nouvelle adresse à chaque fois**.

Ton wallet ne contient pas “une adresse”,  
il contient **une machine à fabriquer des adresses**.

### 🧠 À retenir
> Beaucoup d’adresses = plus de confidentialité, pas plus de clés.

---

## Didactique

### 1) Un wallet, ce n’est pas une adresse
Un wallet moderne est basé sur une **seed** (12/24 mots).  
Cette seed permet de dériver **une infinité** de clés/adresses.

Dans Sparrow, quand tu crées ton multisig 2-of-2 (Ledger A + Ledger B), Sparrow construit un “moteur” qui sait dériver les adresses.

### 2) Deux familles d’adresses : Receive et Change
Ton wallet a **2 branches** :

- **Receive** : `/0/*` → adresses à donner aux gens (réception)
- **Change** : `/1/*` → adresses internes (la “monnaie” rendue)

Quand tu dépenses un UTXO, souvent tu n’envoies pas “pile” le montant exact.
Donc :
- une sortie va vers le destinataire
- une sortie revient dans ton wallet sur une **adresse de change** (branch `/1/*`)

### 3) Pourquoi Sparrow affiche ~20 et toi 200 ?
Sparrow te montre souvent un **aperçu** (ex : 20 adresses) pour l’UI.

Mais pour “observer” un wallet en watch-only, tu dois choisir une profondeur de dérivation :
- si tu dérives trop peu : tu risques de **rater** des fonds (si tu as utilisé plus loin dans l’index)
- si tu dérives beaucoup : tu es plus robuste, mais tu stockes plus d’adresses

Dans Bitcoin Monitor, `scan_range = 200` veut dire :
- on dérive et stocke `0..200` pour `/0/*`
- et `0..200` pour `/1/*`

Ça reste raisonnable (201 receive + 201 change ≈ 402 total, selon ton implémentation exacte).

### 4) Lien direct avec Bitcoin Monitor
Dans l’app :
- tu importes les **descriptors** `/0/*` et `/1/*` (watch-only)
- tu dérives un set d’adresses (VaultAddress)
- tu scannes les UTXOs via Bitcoin Core sur **ces adresses**

:::app
Dans l’app : Wallet → “Import watch-only” puis “Rescanner”
:::

---

## Technique

### A) Descriptors : la source de vérité
Ton multisig P2WSH 2-of-2 est représenté par des descriptors du style :

- Receive : `wsh(sortedmulti(2,[FPR/path]xpub.../0/*,[FPR/path]xpub.../0/*))#checksum`
- Change  : `wsh(sortedmulti(2,[FPR/path]xpub.../1/*,[FPR/path]xpub.../1/*))#checksum`

Le `#checksum` sert à éviter les erreurs de copie.

### B) Pourquoi un “range” est nécessaire
Un descriptor avec `*` est **ranged**.  
Bitcoin Core veut un `range: [0, N]` à l’import (même en watch-only).

Dans ton code tu fais :
- `importdescriptors` avec `range`
- puis tu dérives les adresses et tu les stockes en DB

### C) “Gap limit” (l’idée derrière le range)
Le “gap limit” est le nombre d’adresses “vides d’affilée” qu’un wallet explore avant de considérer qu’il n’y a plus rien.

Ton `scan_range=200` joue ce rôle côté Bitcoin Monitor :
- robuste si l’utilisateur a généré beaucoup d’adresses dans Sparrow
- mais **coûte plus** (DB + listunspent sur plus d’adresses)

### D) Perf : pourquoi batcher
Tu fais bien de batcher `listunspent` par tranches (`DEFAULT_BATCH_SIZE = 100`).
Ça évite :
- des payloads trop gros
- des timeouts
- et ça garde le scan stable

### E) Validation terrain (ton wallet réel)
Dans ton wallet A/B (#10), tu as :
- UTXOs: 1
- total: 13 239 sats
- confirmations: 413

C’est parfait pour valider le pipeline de scan.

:::cmd
bin/rails runner 'v=Vault.find(10); r=VaultUtxoScanner.new(v).scan_and_persist!; puts [r.total_sats, r.utxos.size].inspect'
:::
