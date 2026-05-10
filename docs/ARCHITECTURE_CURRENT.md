# Bitcoin Monitor — Current Architecture

Dernière mise à jour : 2026-05-10

---

# CURRENT

## Layer 1 — Blockchain Data Engine

Source officielle des données blockchain.

### Responsabilités

- ingestion blockchain
- processing blocs/tx
- buffering Redis
- flush PostgreSQL
- orchestration
- recovery
- realtime infrastructure

### Dossiers

- app/services/blockchain/
- app/jobs/blockchain/

### Tables principales

- block_buffers
- tx_outputs
- events
- edges

---

## Modules connectés à Layer 1

### Cluster

Responsable de :
- clustering
- address links
- metrics
- signals

Dépend de :
- tx_outputs
- edges
- events

### Exchange-like

Responsable de :
- détection exchange-like
- observed UTXOs

Dépend de :
- tx_outputs

### Inflow / Outflow

Responsable de :
- flux exchange entrants/sortants
- comportements capital

Dépend de :
- exchange_observed_utxos

### Whale

Responsable de :
- whale alerts
- gros mouvements

Dépend de :
- Layer 1

---

## Market Data

### BTC

Source séparée.

Ne dépend PAS de Layer 1.

Sources :
- Coinbase
- Binance
- CoinGecko

Tables :
- btc_price_days
- btc_candles
- market_snapshots

---

# CURRENT SYSTEM PAGES

## /system

Cockpit global.

Contient :
- global status
- infrastructure
- layer 1
- modules
- market data
- jobs critiques

---

## /system/recovery

Centre de reprise après panne.

Contient :
- lags
- recovery pipelines
- jobs bloqués
- redis backlog
- état realtime

---

# LEGACY

## À supprimer après validation

- app/services/OLD_cluster_scanner.rb
- app/services/OLD_exchange_observed_scanner.rb

---

# TO REMOVE FROM /system

- tests
- QA
- anciennes vues realtime séparées
- live block stream séparé
- cluster realtime séparé

---

# TO MERGE

## Infrastructure realtime

Fusionner :
- realtime block stream
- cluster realtime
- live block stream

Nouvelle section :

Infrastructure → Realtime / ZMQ / Streams

---

# ARCHITECTURE RULES

## Règle principale

Layer 1 est la source officielle blockchain.

Aucun module métier ne doit rescanner la blockchain directement
si les données existent déjà dans Layer 1.

---

## Flux officiel

bitcoind
↓
Layer 1
↓
Modules métier
↓
Analytics / dashboards

---

## Séparation des responsabilités

Layer 1 :
- collecte
- parsing
- buffering
- persistence

Modules :
- analyse métier
- scoring
- signaux
- intelligence

UI :
- visualisation
- monitoring
- recovery