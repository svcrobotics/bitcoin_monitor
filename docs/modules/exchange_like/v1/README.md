
# Exchange Like — V1

Module de détection et d'observation des adresses "exchange-like" dans Bitcoin Monitor.

Ce module reconstruit l'activité des exchanges directement depuis la blockchain Bitcoin.

Il ne dépend pas d’API externes.

---

# Objectif

Identifier et observer les adresses susceptibles d'appartenir à des exchanges afin de reconstruire :

- les flux entrants (inflow)
- les flux sortants (outflow)
- les mouvements de liquidité

Ces informations servent ensuite à produire des indicateurs de marché.

---

# Pipeline

Le module fonctionne en plusieurs étapes.

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

## ExchangeAddressBuilder

Service :

```

app/services/exchange_address_builder.rb

```

Objectif :

Découvrir automatiquement des adresses exchange-like.

Le builder :

- scanne les blocs Bitcoin
- analyse les outputs (`vout`)
- applique des heuristiques
- agrège les adresses observées
- met à jour la table `exchange_addresses`

---

## ExchangeObservedScanner

Service :

```

app/services/exchange_observed_scanner.rb

```

Objectif :

Observer l'activité des adresses exchange-like.

Le scanner :

- surveille les nouvelles transactions
- détecte les UTXO reçus
- détecte les UTXO dépensés
- met à jour `exchange_observed_utxos`

Le scanner fonctionne **en mode incrémental**.

---

# Tables principales

## exchange_addresses

Adresses détectées comme exchange-like.

Colonnes principales :

| colonne | description |
|-------|-------------|
| address | adresse bitcoin |
| occurrences | nombre d'apparitions |
| confidence | score heuristique |
| first_seen_at | première apparition |
| last_seen_at | dernière apparition |
| source | origine de la détection |

---

## exchange_observed_utxos

UTXO observés appartenant aux adresses exchange-like.

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

# Fonctionnement incrémental

Le module utilise des curseurs stockés dans :

```

scanner_cursors

```

Deux curseurs sont utilisés :

```

exchange_address_builder
exchange_observed_scan

```

Chaque exécution reprend automatiquement au dernier bloc traité.

Cela permet :

- reprise après crash
- reprise après reboot
- scans rapides

---

# Sélection des adresses

Deux ensembles d'adresses sont définis :

## operational

```

ExchangeAddress.operational

```

Ensemble large utilisé pour l'analyse.

---

## scannable

```

ExchangeAddress.scannable

```

Sous-ensemble utilisé par le scanner.

Cela réduit la charge du scan.

---

# Cron jobs

Les tâches sont automatisées.

## Builder

```

cron_exchange_address_builder.sh

```

Exécution quotidienne.

---

## Observed scanner

```

cron_exchange_observed_scan.sh

```

Exécution :

```

toutes les 10 minutes

```

---


# Performance

Plusieurs optimisations sont utilisées :

- scan incrémental
- batch SQL
- flush intermédiaire mémoire
- index base de données
- réduction du set scanné (`scannable`)

---

# Limitations V1

Cette version est volontairement simple.

Limitations :

- heuristiques simples
- faux positifs possibles
- pas de clustering d'adresses
- pas de distinction hot / cold wallet

Ces améliorations sont prévues dans les versions suivantes.

---

# Documentation du module

Documentation complète dans :

```

docs/modules/exchange_like/v1/

```

- ARCHITECTURE.md
- DECISIONS.md
- TASKS.md
- TESTS.md
- AMELIORATION.md
```

---

