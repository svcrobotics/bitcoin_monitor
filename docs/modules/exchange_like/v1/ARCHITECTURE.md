
# Exchange Like — V1 — Architecture

Ce document décrit l’architecture interne du module `exchange_like`.

Le module a pour objectif :

identifier et observer les adresses susceptibles d'appartenir à des exchanges
directement depuis la blockchain Bitcoin.

Le module ne dépend pas d’API externes.

---

# Vue générale

Le module fonctionne en deux étapes :

1. découverte des adresses exchange-like
2. observation de leur activité on-chain

Pipeline :

```

Blockchain
↓
ExchangeAddressBuilder
↓
exchange_addresses
↓
ExchangeObservedScanner
↓
exchange_observed_utxos

```

---

# Composants

Le module repose sur deux services principaux.

| composant | rôle |
|-----------|------|
| ExchangeAddressBuilder | découvre les adresses exchange-like |
| ExchangeObservedScanner | observe l'activité de ces adresses |

---

# ExchangeAddressBuilder

Service :

```

app/services/exchange_address_builder.rb

```

Objectif :

construire un ensemble d'adresses susceptibles d'appartenir à des exchanges.

Le builder analyse les blocs Bitcoin et apprend les adresses à partir des outputs.

---

## Scan blockchain

Le builder :

1. récupère le best block

```

getblockcount

```

2. parcourt les blocs

```

getblockhash
getblock

```

avec :

```

verbosity = 2

```

---

## Apprentissage des adresses

Le builder apprend depuis les outputs :

```

tx.vout

```

Chaque output est analysé.

Les outputs ignorés :

- coinbase
- nulldata
- montants trop petits
- montants trop grands

Les adresses extraites sont agrégées.

---

## Agrégation

Pour chaque adresse :

le builder maintient en mémoire :

| donnée | description |
|------|-------------|
| occurrences | nombre d'apparitions |
| total_received_btc | volume reçu |
| txids | transactions uniques |
| first_seen_at | première apparition |
| last_seen_at | dernière apparition |
| seen_days | jours actifs |

Ces données servent à calculer un score heuristique.

---

## Filtrage

Avant persistance, un filtrage réduit le bruit.

Une adresse est conservée si :

- occurrences >= seuil
- ou nombre de tx >= seuil
- ou activité sur plusieurs jours

Les seuils sont configurables via ENV.

---

## Persistance

Les adresses conservées sont stockées dans :

```

exchange_addresses

```

Colonnes principales :

| colonne | rôle |
|-------|------|
| address | adresse bitcoin |
| occurrences | nombre d'apparitions |
| confidence | score heuristique |
| first_seen_at | première apparition |
| last_seen_at | dernière apparition |
| source | origine |

---

## Optimisations builder

Plusieurs optimisations sont utilisées :

### Flush intermédiaire

Les agrégats mémoire sont flushés périodiquement
pour éviter une croissance excessive de la mémoire.

### Batch SQL

Les écritures utilisent :

```

upsert_all

```

avec index unique sur :

```

exchange_addresses.address

```

### Mode incrémental

Le builder peut fonctionner en mode incrémental.

Un curseur est stocké dans :

```

scanner_cursors

```

avec :

```

name = exchange_address_builder

```

Chaque exécution reprend au dernier bloc traité.

---

# ExchangeObservedScanner

Service :

```

app/services/exchange_observed_scanner.rb

```

Objectif :

observer les UTXO appartenant aux adresses exchange-like.

---

## Sélection des adresses

Le scanner ne surveille pas toutes les adresses.

Deux ensembles existent :

### operational

```

ExchangeAddress.operational

```

utilisé pour l'analyse.

### scannable

```

ExchangeAddress.scannable

```

utilisé pour le scanner.

Ce sous-ensemble réduit la charge.

---

## Scan blockchain

Le scanner parcourt les blocs :

```

getblock
verbosity = 2

```

Pour chaque transaction :

1. analyse des inputs
2. analyse des outputs

---

## Détection des UTXO

### Outputs

Si une adresse appartient au set exchange-like :

un UTXO est enregistré dans :

```

exchange_observed_utxos

```

---

### Inputs

Lorsqu'un UTXO est dépensé :

le scanner met à jour :

```

spent_by_txid
spent_day

```

---

## Persistance

Les écritures utilisent :

```

upsert_all

```

avec index unique :

```

(txid, vout)

```

---

# Table exchange_observed_utxos

Chaque ligne représente un UTXO observé.

| colonne | description |
|-------|-------------|
| txid | transaction |
| vout | index output |
| value_btc | valeur |
| address | adresse exchange |
| seen_day | jour d'apparition |
| spent_day | jour de dépense |
| spent_by_txid | tx de dépense |

---

# Index

Les index principaux sont :

| index | rôle |
|------|------|
| txid + vout | unicité UTXO |
| address | requêtes par adresse |
| seen_day | agrégation journalière |
| spent_day | analyse des dépenses |

---

# Mode incrémental

Le scanner fonctionne en mode incrémental.

Le curseur est stocké dans :

```

scanner_cursors

```

avec :

```

name = exchange_observed_scan

```

Chaque run reprend au dernier bloc traité.

---

# Cron

Le module est exécuté automatiquement.

## Builder

```

cron_exchange_address_builder.sh

```

exécution quotidienne.

---

## Scanner

```

cron_exchange_observed_scan.sh

```

exécution :

toutes les 10 minutes.

---

# Résilience

Grâce aux curseurs :

- reprise automatique après crash
- reprise après redémarrage machine
- reprise après coupure électrique

---

# Limites V1

Cette version reste volontairement simple.

Limitations :

- heuristiques simples
- faux positifs possibles
- pas de clustering d'adresses
- pas de distinction hot/cold wallets

Ces améliorations sont prévues dans les versions suivantes.
