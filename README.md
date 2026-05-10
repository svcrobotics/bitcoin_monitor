# Bitcoin Monitor

## Vue d’ensemble

Bitcoin Monitor est une plateforme modulaire d’analyse blockchain construite au-dessus de Bitcoin Core.

Le projet est conçu autour d’une architecture en couches séparant :

* l’ingestion blockchain
* la normalisation des données
* les traitements analytiques
* la génération de métriques et signaux
* le traitement temps réel
* la reprise après incident
* l’observabilité opérationnelle

L’objectif principal du système est de fournir une base robuste pour construire des pipelines analytiques Bitcoin temps réel tout en restant compatible avec les nœuds Bitcoin Core en mode pruned.

Contrairement aux explorateurs blockchain traditionnels principalement orientés consultation de transactions, Bitcoin Monitor se concentre sur :

* l’architecture des pipelines
* le traitement temps réel
* le calcul incrémental
* la résilience opérationnelle
* les modules analytiques Layer 2
* la visibilité système
* l’exécution autonome longue durée

Le projet est développé avec une forte priorité donnée à :

* la maintenabilité
* la modularité
* l’observabilité
* la récupération après panne
* la résilience opérationnelle
* la clarté architecturale

---

# Architecture du système

Bitcoin Monitor suit un modèle de traitement en couches.

```text id="c5jqx9"
bitcoind
  ↓
ZMQ / RPC
  ↓
Layer 1 ingestion
  ↓
Buffers Redis
  ↓
État blockchain normalisé
  ↓
Modules analytiques Layer 2
  ↓
Profils / métriques / signaux
  ↓
Dashboards temps réel & APIs
```

L’architecture sépare volontairement :

* l’ingestion
* la persistance
* le calcul
* l’orchestration
* la visualisation

Cette séparation permet aux modules analytiques d’évoluer indépendamment du pipeline d’ingestion blockchain.

---

# Modèle de traitement en couches

## Layer 1 — Ingestion Blockchain

Le Layer 1 est responsable de la collecte et de la normalisation des données blockchain.

Responsabilités :

* ingestion des blocs
* écoute temps réel via ZMQ
* backfill RPC
* normalisation des transactions
* suivi des UTXOs
* suivi des outputs dépensés
* buffering Redis
* orchestration de récupération

Principaux composants :

* `Blockchain::Ingest::ZmqListener`
* `Blockchain::Ingest::RpcBackfill`
* `Blockchain::Processing::BlockProcessor`
* `Blockchain::Flushers::*`
* `Layer1Orchestrator`
* `BlockBufferModel`

L’état blockchain normalisé est principalement stocké dans :

* `tx_outputs`
* block buffers
* scanner cursors
* buffers Redis

Le Layer 1 agit comme source canonique blockchain pour tous les modules analytiques supérieurs.

---

## Layer 2 — Traitements analytiques

Le Layer 2 consomme l’état blockchain normalisé produit par le Layer 1.

Responsabilités :

* analyse de clusters
* détection exchange-like
* détection whale
* calcul inflow/outflow
* métriques marché temps réel
* analyse comportementale

Les modules fonctionnent de manière incrémentale et indépendante.

Modules Layer 2 actuels :

| Module           | Description                                  |
| ---------------- | -------------------------------------------- |
| Cluster          | Clustering multi-input et analyse de graphes |
| Exchange Like    | Détection d’adresses exchange-like           |
| Whale            | Détection de transactions importantes        |
| Inflow / Outflow | Analyse des flux exchanges                   |
| BTC              | Métriques marché et chandeliers temps réel   |

Les modules Layer 2 évitent autant que possible toute dépendance directe au RPC blockchain brut.

Ils consomment l’état normalisé du Layer 1.

Cette approche réduit fortement la charge RPC et améliore la cohérence ainsi que les capacités de récupération.

---

## Layer 3 — Métriques & Signaux

Le Layer 3 génère l’intelligence analytique de haut niveau.

Responsabilités :

* profils de clusters
* agrégation de métriques
* scoring comportemental
* détection d’anomalies
* génération de signaux
* indicateurs de marché

Principales entités :

* `ClusterProfile`
* `ClusterMetric`
* `ClusterSignal`

Exemples de signaux :

* activité soudaine
* spikes de volume
* gros transferts
* activation de clusters
* divergence comportementale

---

## Layer 4 — Delivery & Opérations

Le Layer 4 est responsable :

* des dashboards
* de la visibilité opérationnelle
* des interfaces temps réel
* du monitoring système
* de la visualisation recovery
* de l’orchestration visible

Le dashboard `/system` expose l’état opérationnel global de la plateforme.

---

# Pipeline temps réel

Bitcoin Monitor supporte le traitement blockchain temps réel via ZMQ Bitcoin Core.

```text id="nlh7g6"
bitcoind ZMQ
  ↓
Realtime block watcher
  ↓
Ingestion bloc
  ↓
Normalisation Layer 1
  ↓
Traitements incrémentaux Layer 2
  ↓
Génération de signaux
  ↓
Mise à jour dashboards
```

L’architecture temps réel est conçue pour :

* tolérer les défaillances temporaires
* récupérer après redémarrage
* rejouer les blocs manquants
* éviter les doublons
* rester compatible avec les nœuds pruned

---

# Architecture Recovery

La récupération après incident est considérée comme une fonctionnalité centrale du système.

La plateforme intègre une orchestration recovery dédiée capable de :

* détecter les pipelines bloqués
* rejouer les blocs manquants
* réenfiler les traitements échoués
* reconstruire l’état analytique
* surveiller les backlogs
* suivre les retards de traitement

L’état recovery est exposé en permanence via les dashboards opérationnels.

Exemples d’états surveillés :

* ingestion lag
* processing lag
* realtime lag
* cluster lag
* exchange lag
* backlog Redis
* santé Sidekiq
* ownership des locks
* fraîcheur des heartbeats

---

# Pipeline Cluster Analytics

L’analyse de clusters est implémentée comme pipeline incrémental Layer 2 dédié.

```text id="1qpk7f"
Layer 1 tx_outputs
  ↓
ClusterScanner
  ↓
Address linking
  ↓
Cluster merging
  ↓
Dirty cluster queue
  ↓
Cluster refresh
  ↓
Profiles / metrics / signals
```

Le système cluster supporte actuellement :

* heuristique multi-input
* scan incrémental
* queues dirty clusters
* mise à jour temps réel
* profils de clusters
* génération de signaux

Le pipeline est conçu pour éviter le rescanning des transactions déjà liées.

---

# Détection Exchange-Like

Le module Exchange Like identifie les adresses et flux ayant un comportement opérationnel similaire aux exchanges.

Le module se concentre sur :

* réutilisation d’adresses
* fréquence transactionnelle
* activité UTXO
* comportements inflow/outflow
* clustering opérationnel

Le système évite autant que possible toute dépendance à des fournisseurs de labels externes.

---

# Détection Whale

Le monitoring whale est entièrement natif Layer 1.

Le système détecte les transactions importantes directement depuis les outputs blockchain normalisés plutôt qu’en rescannant les réponses RPC.

Avantages :

* réduction de charge RPC
* meilleures performances
* compatibilité pruned
* replay déterministe
* pipeline unifié

Les classifications whales incluent :

* retail probable
* desk probable
* whale probable
* institution probable

---

# Modèle opérationnel

## Queues Sidekiq

La plateforme utilise des queues dédiées par pipeline.

Exemples :

| Queue               | Responsabilité        |
| ------------------- | --------------------- |
| realtime            | Traitement temps réel |
| process             | Traitement Layer 1    |
| ingest              | Ingestion blockchain  |
| p3_clusters_scan    | Scan clusters         |
| p3_clusters_refresh | Refresh clusters      |
| p4_analytics        | Calcul analytique     |

---

## Buffers Redis

Redis est massivement utilisé pour :

* buffering temps réel
* dirty queues
* état temporaire ingestion
* coordination des traitements
* locks distribués

Exemples :

* output buffers
* spent output buffers
* dirty cluster queues
* orchestration locks

---

## Locks distribués

Les pipelines critiques utilisent des locks Redis afin d’éviter les exécutions concurrentes.

Exemples :

* cluster scan lock
* realtime processing lock
* orchestrator lock
* recovery lock

---

# Stratégie de performance

La plateforme est construite autour du traitement incrémental et de la scalabilité opérationnelle.

Principes clés :

* scans incrémentaux
* batch upserts
* buffering Redis
* réduction dépendance RPC
* traitements asynchrones
* refresh différé
* calcul replay-safe

L’architecture privilégie :

* récupération déterministe
* faible complexité opérationnelle
* mémoire bornée
* debugging orienté observabilité

---

# Compatibilité Pruned Node

Bitcoin Monitor est conçu pour fonctionner avec des nœuds Bitcoin Core en mode pruned.

Le système minimise la dépendance RPC historique en normalisant les données blockchain dans le Layer 1.

Cela réduit fortement les besoins infrastructurels par rapport aux systèmes analytiques nécessitant un full archive node.

---

# Observabilité

L’observabilité est intégrée directement dans l’architecture.

Le système suit notamment :

* pipeline lag
* profondeur des queues
* throughput
* heartbeats
* état recovery
* durée des jobs
* erreurs
* synchronisation temps réel

Les dashboards opérationnels sont considérés comme des composants cœur du système.

---

# Stack technique

| Composant            | Technologie         |
| -------------------- | ------------------- |
| Backend              | Ruby on Rails 8     |
| Langage              | Ruby 3.2            |
| Base de données      | PostgreSQL          |
| Cache / queues       | Redis               |
| Background jobs      | Sidekiq             |
| Nœud blockchain      | Bitcoin Core        |
| Transport temps réel | ZMQ                 |
| Frontend             | Rails + TailwindCSS |

---

# Exécution locale

## Pré-requis

* Ruby 3.2+
* PostgreSQL
* Redis
* Bitcoin Core
* ZMQ activé

---

## Configuration Bitcoin Core

Exemple :

```
txindex=0
prune=55000

rpcbind=127.0.0.1
rpcallowip=127.0.0.1

zmqpubhashblock=tcp://127.0.0.1:28332
zmqpubhashtx=tcp://127.0.0.1:28333
```

---

## Installation

```bash
bundle install
bin/rails db:prepare
```

Lancer les services :

```bash
redis-server
bitcoind
bundle exec sidekiq
bin/dev
```

---

# Philosophie de développement

Bitcoin Monitor est développé autour de plusieurs principes architecturaux :

* ingestion et calcul doivent rester séparés
* la récupération opérationnelle est obligatoire
* les pipelines doivent être observables
* les systèmes temps réel doivent se dégrader proprement
* les modules analytiques doivent rester modulaires
* l’état normalisé doit survivre à la dépendance RPC
* les systèmes doivent rester rejouables et déterministes

Le projet privilégie volontairement :

* la clarté plutôt que l’abstraction excessive
* la visibilité opérationnelle plutôt que la magie cachée
* le refactoring incrémental plutôt que les réécritures massives
* l’optimisation mesurable plutôt que l’optimisation prématurée

---

# Roadmap

Axes de développement prévus :

* intelligence cluster avancée
* streaming temps réel
* moteur d’intelligence marché
* système d’alertes
* couche API
* delivery WebSocket
* analyse blockchain assistée IA
* pipelines distribués
* détection avancée d’anomalies
* corrélation multi-modules

---

# Statut du projet

Bitcoin Monitor est un projet d’ingénierie blockchain long terme visant à construire une architecture analytique production-grade autour de Ruby on Rails et Bitcoin Core.
