# Exchange Like — V2 — Heuristics

## Objectif du module

Le module **exchange_like** vise à :

* détecter des **adresses Bitcoin présentant un comportement typique d’exchange**
* observer leur activité on-chain
* fournir un dataset exploitable pour :

  * inflow / outflow
  * analyse de pression marché
  * détection de comportements anormaux

---

# 1. Philosophie générale

Le module repose sur 2 moteurs :

## Builder

→ découvre des adresses candidates

## Scanner

→ observe leur activité réelle (UTXO)

---

# 2. Builder — Heuristiques

## Source des données

* RPC Bitcoin (`getblock(..., 2)`)
* analyse des **outputs uniquement**

👉 choix volontaire :

* compatible pruned node
* pas de dépendance aux tx historiques

---

## Filtrage des outputs

Un output est considéré seulement si :

* value > `MIN_OUTPUT_BTC` (default: 0.01 BTC)
* value < `MAX_OUTPUT_BTC` (default: 500 BTC)
* scriptPubKey non `nulldata`
* adresse extractible

---

## Agrégation

Par adresse, on stocke :

* `occurrences`
* `txids uniques`
* `total_received_btc`
* `first_seen_at`
* `last_seen_at`
* `active_days`

---

## Filtre final (keep)

Une adresse est gardée si :

* occurrences ≥ 3
  OU
* tx_count ≥ 2
  OU
* active_days ≥ 1 ET occurrences ≥ 2

👉 objectif :

* éliminer bruit / dust
* garder comportements répétitifs

---

## Scoring (confidence)

Score basé sur :

* occurrences
* tx_count
* active_days
* volume total reçu

### Bonus volume :

* ≥ 100 BTC → +20
* ≥ 20 BTC → +10
* ≥ 5 BTC → +5

Score final :

* min 1
* max 100

---

## Limites

* faux positifs possibles
* faux négatifs possibles
* pas de clustering
* pas de distinction hot/cold wallet

---

# 3. Sets d’adresses

## operational

Adresses :

* validées par heuristique
* utilisées pour affichage / analyse

## scannable

Sous-ensemble utilisé par le scanner :

* filtré pour performance
* souvent basé sur occurrences / confidence

---

# 4. Scanner — Heuristiques

## Objectif

Observer :

* UTXO entrants (seen)
* UTXO sortants (spent)

---

## Seen (entrées)

Un UTXO est enregistré si :

* address ∈ scannable set
* value > 0
* valeur normalisée valide

---

## Spent (sorties)

Un UTXO est marqué spent si :

* txid + vout correspond à un UTXO observé
* pas déjà marqué spent

---

## Normalisation des valeurs

Gestion des cas :

* satoshis vs BTC
* bugs d’unité
* valeurs anormalement élevées

Règles :

* tentative correction si valeur suspecte
* rejet si > `MAX_SINGLE_UTXO_BTC`

---

## Limites scanner

* dépend du set builder
* ne détecte pas tout le flux réel exchange
* ne distingue pas internal vs external

---

# 5. Données produites

## ExchangeAddress

* adresse candidate
* occurrences
* confidence
* first_seen_at / last_seen_at

## ExchangeObservedUtxo

* UTXO vus
* UTXO dépensés
* timestamps
* block metadata

---

# 6. Interprétation

## Ce que le module donne

* un **proxy du comportement exchange**
* un signal de flux agrégé

## Ce que le module NE donne PAS

* une liste officielle d’exchanges
* une vérité absolue des flux

---

# 7. Positionnement dans Bitcoin Monitor

exchange_like est un module :

* **fondationnel**
* utilisé par :

  * inflow/outflow
  * analyse marché
  * alerting futur

---

# 8. État V2

* builder refactoré
* scanner refactoré
* monitoring intégré (/system)
* vue dédiée (/exchange_like)

👉 module prêt pour exploitation et extension

---

## Redis

Le module utilise Redis pour mettre en cache le set `scannable` :

- clé : `exchange_like:scannable_addresses`
- rôle : éviter une requête DB répétée à chaque scan
- invalidation : après chaque run du builder
- fallback : rechargement depuis PostgreSQL si cache vide

## Performance — Redis cache

Le set des adresses scannables est mis en cache Redis.

Résultat mesuré :

- sans cache : ~175s
- avec cache : ~48s
- gain : ~72%

Conclusion :
le cache Redis est critique pour les performances du scanner.