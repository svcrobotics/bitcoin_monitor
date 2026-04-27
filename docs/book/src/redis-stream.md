# Redis Streams : quand Bitcoin Monitor est devenu événementiel

> Au début, Bitcoin Monitor exécutait des jobs.
>
> Puis l’application a commencé à faire circuler des événements.

Ce chapitre raconte l’introduction de Redis Streams dans Bitcoin Monitor et pourquoi ce changement représente un tournant architectural majeur.

Pendant longtemps, l’application fonctionnait principalement autour de :

* cron,
* jobs Sidekiq,
* PostgreSQL,
* traitements périodiques.

Puis un nouveau besoin est apparu :

> plusieurs modules devaient réagir au même événement blockchain.

C’est précisément là que Redis Streams est devenu indispensable.

---

## Avant Redis Streams

L’architecture initiale ressemblait à ceci :

```text
cron
↓
job Rails
↓
scan blockchain
↓
PostgreSQL
↓
dashboard
```

Le fonctionnement était :

* simple,
* robuste,
* facile à comprendre.

Mais le modèle restait essentiellement :

```text
batch
```

Les modules ne réagissaient pas immédiatement aux événements blockchain.

Ils attendaient :

* un cron,
* un scheduler,
* ou un nouveau scan périodique.

---

## Le vrai problème

Le problème n’était pas :

> “comment faire du temps réel ?”

Le vrai problème était :

> “comment permettre à plusieurs modules indépendants de réagir au même événement ?”

Prenons un nouveau bloc Bitcoin.

Ce bloc peut intéresser :

* Cluster,
* Exchange Flow,
* Whale Detection,
* Metrics,
* Alerts,
* Dashboard live,
* Analytics,
* futurs modules IA.

Avant Redis Streams, une approche naïve aurait été :

```text
nouveau bloc
↓
1 gros job
↓
tout recalculer
```

Mais cette architecture devient rapidement :

* difficile à maintenir,
* monolithique,
* peu scalable,
* fragile,
* difficile à superviser.

---

## Pourquoi Sidekiq ne suffisait plus

Une question importante est apparue :

> “pourquoi ne pas simplement utiliser une queue Sidekiq ?”

Parce qu’une queue classique n’est pas un bus d’événements.

C’est une différence fondamentale.

---

## Queue classique

Une queue fonctionne généralement comme ceci :

```text
1 message
↓
1 consommateur
↓
message supprimé
```

Exemple :

```text
job Sidekiq
↓
1 worker
↓
traitement
```

C’est parfait pour :

* des tâches asynchrones,
* des traitements unitaires,
* des pipelines simples.

Mais pas pour :

```text
1 événement
↓
plusieurs réactions indépendantes
```

---

## Event stream

Un stream fonctionne différemment :

```text
1 événement
↓
N consommateurs
```

Par exemple :

```text
nouveau bloc Bitcoin
├── Cluster worker
├── Exchange worker
├── Whale worker
├── Metrics worker
└── Live UI broadcaster
```

C’est exactement ce dont Bitcoin Monitor avait besoin.

---

## Pourquoi Redis Streams

Plusieurs solutions existaient :

* Kafka,
* RabbitMQ,
* NATS,
* Pulsar,
* Redis Streams.

Le choix retenu a été Redis Streams.

Pourquoi ?

Parce que Redis était déjà présent dans l’architecture via Sidekiq.

Redis Streams apportait immédiatement :

* faible latence,
* simplicité,
* persistance,
* multi-consommateurs,
* intégration Rails facile,
* overhead opérationnel minimal.

---

## Pourquoi Kafka n’a pas été choisi

Kafka est extrêmement puissant.

Mais Kafka implique aussi :

* une infrastructure plus lourde,
* davantage d’opérations système,
* plus de supervision,
* plus de complexité,
* plus de maintenance.

Pour Bitcoin Monitor, Redis Streams couvrait déjà largement les besoins :

* event bus,
* fan-out,
* replay,
* consommation parallèle,
* découplage,
* faible latence.

Le choix architectural était donc volontaire :

> simplicité maximale pour un gain architectural énorme.

---

## Le premier stream

Le premier stream créé :

```text
bitcoin.blocks
```

Sa responsabilité :

```text
publier les nouveaux blocs Bitcoin
```

---

## Première publication

Le premier événement réel ressemblait à ceci :

```text
1777243718434-0
type
new_block
height
946798
blockhash
000000000000000000017c51640fcc139c81c7cc1695f8600978d0d17f44955a
created_at
1777243718
```

Ce n’était plus :

```text
un job Rails
```

C’était :

```text
un événement blockchain vivant
```

circulant dans l’infrastructure.

---

## Le premier producteur

Un nouveau service apparaît :

```text
Realtime::BlockEventProducer
```

Son rôle :

```text
écrire dans Redis Stream
```

Exemple :

```ruby
redis.xadd(
  "bitcoin.blocks",
  {
    type: "new_block",
    height: height,
    blockhash: blockhash,
    created_at: Time.current.to_i
  }
)
```

Le système commence alors à produire des événements blockchain internes.

---

## Ce que le stream représente réellement

Le stream n’est pas :

```text
le traitement
```

Le stream est :

```text
la source d’événements
```

C’est une distinction fondamentale.

Le stream représente :

* ce qui s’est produit,
* indépendamment de ce qui va le consommer.

Autrement dit :

```text
événement
≠
traitement
```

---

## Le découplage devient réel

Avant :

```text
watcher
↓
job spécifique
↓
traitement spécifique
```

Après Redis Streams :

```text
watcher
↓
stream
↓
plusieurs consommateurs indépendants
```

Le système devient :

* découplé,
* extensible,
* modulaire,
* scalable.

---

## Le premier consommateur

Le premier consommateur réel du stream fut :

```text
Realtime::ProcessLatestBlockJob
```

Son rôle :

```text
traiter le dernier bloc
```

Puis déclencher :

```text
ClusterScanner
↓
dirty clusters
↓
refresh async
↓
metrics
↓
signals
```

---

## Pourquoi c’est un tournant majeur

Avant Redis Streams, Bitcoin Monitor ressemblait surtout à :

```text
une application Rails batch
```

Après Redis Streams, le projet commence à ressembler à :

```text
une plateforme événementielle blockchain
```

Le changement est énorme.

---

## Quand le temps réel rencontre la réalité

La première version fonctionnait.

Mais un vrai problème est rapidement apparu :

```text
les redémarrages serveur
```

et surtout :

```text
les backlogs blockchain
```

---

## Le vrai défi : le recovery

Après reboot :

* plusieurs blocs Bitcoin avaient été minés,
* les curseurs Rails étaient en retard,
* Sidekiq redémarrait,
* certains jobs étaient encore marqués RUNNING,
* plusieurs pipelines tentaient de rattraper le retard simultanément.

C’est là que les vrais problèmes de systèmes distribués sont apparus.

---

## Les premiers symptômes

Le dashboard recovery montrait :

```text
Realtime lag: 18
Cluster lag: 18
Exchange lag: 18
```

Et surtout :

```text
cluster_scan RUNNING
exchange_observed_scan RUNNING
```

pendant des dizaines de minutes.

---

## Les deadlocks PostgreSQL

Le vrai problème venait des jobs concurrents.

Plusieurs `ClusterScanJob` tournaient simultanément.

Conséquences :

* contention PostgreSQL,
* verrous SQL,
* deadlocks,
* jobs bloqués,
* queues saturées.

Exemple réel :

```text
ClusterScanner::Error: scan_transaction failed
```

ou :

```text
deadlock detected
```

---

## Pourquoi le problème était difficile

Le problème n’était pas Redis Streams.

Le problème était :

```text
la concurrence incontrôlée
```

Redis Streams diffusait correctement les événements.

Mais plusieurs workers Sidekiq consommaient et enqueueaient trop de jobs simultanément.

---

## Le problème du over-enqueue

Le consumer déclenchait :

```ruby
Realtime::ProcessLatestBlockJob.perform_later
ExchangeObservedScanJob.perform_later
ClusterScanJob.perform_later
```

à chaque événement.

Résultat :

```text
realtime=6
p3_clusters=9
default=47
```

Les queues explosaient.

---

## La vraie solution : orchestration

Le système devait devenir :

```text
événementiel
+
orchestré
```

Ce fut une étape fondamentale.

---

## Introduction des locks Redis

Pour empêcher plusieurs pipelines identiques :

```text
lock:realtime_processor
lock:exchange_observed_scan
lock:cluster_scan
```

Chaque pipeline devient :

```text
single-flight
```

Un seul worker autorisé à la fois.

---

## Protection anti-concurrence

Avant lancement :

```ruby
SETNX lock:key
```

Si le lock existe déjà :

```text
skip lock_active
```

Le système évite alors :

* les doubles scans,
* les deadlocks,
* les traitements concurrents.

---

## Consumer Groups Redis

Un vrai Consumer Group Redis est ajouté :

```text
bitcoin_monitor
```

Consumer :

```text
block_consumer
```

Lecture :

```text
XREADGROUP
```

ACK :

```text
XACK
```

Le système devient alors :

* rejouable,
* robuste,
* traçable,
* résilient après reboot.

---

## XPENDING : la vraie puissance du stream

Redis Streams apporte une capacité extrêmement importante :

```text
voir les événements non ACK
```

Commande :

```bash
XPENDING bitcoin.blocks bitcoin_monitor
```

Cela permet :

* recovery,
* replay,
* debugging,
* supervision temps réel.

---

## Recovery automatique après reboot

Un problème subtil apparaissait :

```text
aucun nouvel événement Redis
mais
lags toujours présents
```

Donc :

```text
stream à jour
≠
pipelines à jour
```

Le consumer a alors été modifié pour vérifier :

```ruby
System::RecoveryStateBuilder.call
```

et relancer automatiquement :

```ruby
Realtime::ProcessLatestBlockJob
ExchangeObservedScanJob
ClusterScanJob
```

si un lag existe.

Le recovery devient autonome.

---

## Queues Sidekiq dédiées

Une autre amélioration majeure :

```yml
:queues:
  - [realtime, 8]
  - [p1_exchange, 4]
  - [p2_flows, 3]
  - [p3_clusters, 2]
  - [p4_analytics, 1]
  - [default, 1]
```

Chaque pipeline possède désormais sa propre priorité.

---

## La surprise : concurrency=2 était meilleur

Initialement :

```yml
:concurrency: 6
```

Mais les performances étaient mauvaises :

* trop de concurrence,
* trop de contention PostgreSQL,
* trop de locks SQL.

Après tests :

```yml
:concurrency: 2
```

le recovery est devenu :

* plus rapide,
* plus stable,
* beaucoup plus propre.

C’était une leçon importante :

> plus de parallélisme ≠ plus de performance.

---

## Le Recovery Center

Une nouvelle page apparaît :

```text
/system/recovery
```

Elle expose :

* lags blockchain,
* pipelines,
* ETA,
* queues,
* workers,
* locks Redis,
* jobs RUNNING,
* jobs FAIL,
* progression recovery.

Le système devient observable.

---

## Architecture finale

```text
Bitcoin Core
↓
ZMQ hashblock
↓
zmq_block_watcher
↓
Redis Streams (bitcoin.blocks)
↓
BlockStreamConsumer
↓
Sidekiq queues dédiées
├── realtime
├── p1_exchange
├── p2_flows
├── p3_clusters
└── p4_analytics
↓
Pipelines spécialisés
↓
PostgreSQL
↓
Recovery Center
↓
Dashboard live
```

---

## Ce que Redis Streams change réellement

Avant :

```text
“quel cron lance quel job ?”
```

Après :

```text
“quel événement produit quelle réaction ?”
```

Puis finalement :

```text
“comment garantir que chaque événement
soit traité exactement comme prévu,
même après panne ou reboot ?”
```

C’est là que Bitcoin Monitor commence réellement à devenir :

```text
une plateforme événementielle blockchain résiliente
```

---

## Les leçons apprises

### Un stream n’est pas une queue

Une queue distribue du travail.

Un stream diffuse des événements.

---

### Les événements doivent être indépendants

Le producteur ne doit pas connaître les consommateurs.

Il doit seulement publier.

---

### Le temps réel crée des problèmes systèmes

Les vrais défis deviennent :

* recovery,
* orchestration,
* locks,
* concurrence,
* supervision,
* replay,
* résilience.

---

### Plus de parallélisme n’est pas toujours meilleur

La contention PostgreSQL peut ralentir tout le système.

---

### Redis Streams a transformé l’architecture

Bitcoin Monitor est passé :

```text
d’une application batch Rails
```

à :

```text
une infrastructure événementielle temps réel
```

---

## Futures évolutions

Architecture cible long terme :

```text
ZMQ
↓
Redis Streams
↓
Consumers spécialisés
↓
Workers dédiés
↓
PostgreSQL
↓
ClickHouse / Elasticsearch
↓
WebSocket / UI live
```

Futures améliorations possibles :

* multi-consumers,
* replay intelligent,
* DLQ,
* monitoring Prometheus,
* Grafana,
* scaling multi-machine,
* analytics temps réel,
* pipelines IA.

---

## Conclusion

L’introduction de Redis Streams représente l’un des plus grands tournants techniques de Bitcoin Monitor.

Le projet est passé :

```text
d’une application pilotée par des jobs
```

à :

```text
une plateforme pilotée par des événements
```

Mais surtout :

```text
une plateforme capable de survivre
à un reboot,
un backlog blockchain,
et un recovery complet.
```

C’est ce moment où une application Rails commence à devenir :

```text
un véritable système temps réel.
```
