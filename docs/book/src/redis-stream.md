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

```text id="m55y4k"
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

```text id="n3g9tm"
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

```text id="z8n6kr"
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

```text id="kbyl9h"
1 message
↓
1 consommateur
↓
message supprimé
```

Exemple :

```text id="e8xtkg"
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

```text id="0s3f8u"
1 événement
↓
plusieurs réactions indépendantes
```

---

## Event stream

Un stream fonctionne différemment :

```text id="4k7txg"
1 événement
↓
N consommateurs
```

Par exemple :

```text id="mj0srm"
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

```text id="9lm3c4"
bitcoin.blocks
```

Sa responsabilité :

```text id="r7t3pk"
publier les nouveaux blocs Bitcoin
```

---

## Première publication

Le premier événement réel ressemblait à ceci :

```text id="r9sh9u"
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

C’était un moment important.

Parce que ce n’était plus :

```text id="q8ckxj"
un job Rails
```

C’était :

```text id="j7q13f"
un événement blockchain vivant
```

circulant dans l’infrastructure.

---

## Le premier producteur

Un nouveau service apparaît :

```text id="gr93wy"
Realtime::BlockEventProducer
```

Son rôle :

```text id="x5u2hv"
écrire dans Redis Stream
```

Exemple :

```ruby id="vx4x7q"
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

```text id="g6hvsy"
le traitement
```

Le stream est :

```text id="r0f9nd"
la source d’événements
```

C’est une distinction fondamentale.

Le stream représente :

* ce qui s’est produit,
* indépendamment de ce qui va le consommer.

Autrement dit :

```text id="nh1g7l"
événement
≠
traitement
```

---

## Le découplage devient réel

Avant :

```text id="sy8fob"
watcher
↓
job spécifique
↓
traitement spécifique
```

Après Redis Streams :

```text id="4hjc0m"
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

```text id="trhrsm"
Realtime::ProcessLatestBlockJob
```

Son rôle :

```text id="vr2vxg"
traiter le dernier bloc
```

Puis déclencher :

```text id="ktt57n"
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

```text id="k1fslg"
une application Rails batch
```

Après Redis Streams, le projet commence à ressembler à :

```text id="7b7w2f"
une plateforme événementielle blockchain
```

Le changement est énorme.

---

# Les futurs streams

Très vite, l’idée apparaît :

```text id="xv0mwb"
un stream par type d’événement
```

Architecture cible :

| Stream                   | Rôle               |
| ------------------------ | ------------------ |
| `bitcoin.blocks`         | nouveaux blocs     |
| `bitcoin.transactions`   | transactions       |
| `bitcoin.whales`         | whales détectées   |
| `bitcoin.exchange_flows` | inflow/outflow     |
| `bitcoin.alerts`         | alertes            |
| `bitcoin.metrics`        | analytics          |
| `bitcoin.system`         | monitoring interne |

Bitcoin Monitor commence alors à se transformer en :

```text id="jz3p34"
système événementiel modulaire
```

---

## La naissance des micro pipelines

L’introduction des streams change aussi la façon de penser les modules.

Avant :

```text id="20jlwm"
gros jobs monolithiques
```

Après :

```text id="ckqkfa"
petits pipelines spécialisés
```

Exemple :

```text id="4z4v26"
bitcoin.blocks
↓
ClusterConsumer
↓
scan incrémental
```

ou :

```text id="n2z72m"
bitcoin.blocks
↓
ExchangeFlowConsumer
↓
analyse inflow/outflow
```

ou encore :

```text id="q92hvy"
bitcoin.transactions
↓
WhaleConsumer
↓
détection gros transferts
```

---

## L’architecture cible

Progressivement, l’architecture devient :

```text id="5x0df6"
Bitcoin Core
↓
ZMQ
↓
Redis Streams
↓
Workers spécialisés
↓
DB + cache + WebSocket
↓
UI live
```

Cette architecture possède plusieurs avantages majeurs :

* temps réel,
* découplage,
* extensibilité,
* supervision,
* parallélisation,
* observabilité.

---

## Redis Streams et Turbo Streams

Une autre conséquence importante apparaît rapidement :

```text id="u4l4xt"
les événements backend peuvent maintenant alimenter directement l’UI
```

Architecture :

```text id="avfqj3"
Redis Stream
↓
Broadcaster
↓
Turbo Stream
↓
WebSocket
↓
Dashboard live
```

Le dashboard `/system` devient alors :

```text id="uhj8jx"
vivant
```

sans refresh navigateur.

---

## Ce que Redis Streams change réellement

Redis Streams change la manière de penser l’application.

Avant :

```text id="2r00b5"
“quel cron lance quel job ?”
```

Après :

```text id="mjlwm2"
“quel événement produit quelle réaction ?”
```

C’est exactement le modèle des systèmes modernes :

* plateformes de trading,
* exchanges,
* systèmes blockchain,
* monitoring temps réel,
* pipelines analytiques.

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

### Le découplage simplifie énormément l’architecture

Chaque module peut évoluer indépendamment.

---

### Redis Streams est une étape intermédiaire extrêmement puissante

Kafka viendra peut-être un jour.

Mais Redis Streams permet déjà :

* une architecture moderne,
* avec une complexité minimale.

---

## Conclusion

L’introduction de Redis Streams représente l’un des plus grands tournants techniques de Bitcoin Monitor.

Le projet est passé :

```text id="d3m6ec"
d’une application pilotée par des jobs
```

à :

```text id="0opk3w"
une plateforme pilotée par des événements
```

Bitcoin Monitor ne se contente plus d’exécuter des traitements.

L’application possède désormais :

* un flux,
* des événements,
* des producteurs,
* des consommateurs,
* des pipelines,
* une architecture temps réel.

Et ce changement ouvre la voie à tout le reste.
