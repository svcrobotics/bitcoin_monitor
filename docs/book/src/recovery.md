# Recovery

Bitcoin Monitor ne traite pas seulement des données blockchain.

L’application doit aussi survivre :

* à un redémarrage serveur,
* à une coupure électrique,
* à un crash Sidekiq,
* à une désynchronisation de `bitcoind`,
* à une interruption réseau,
* à un arrêt prolongé des workers,
* ou à un backlog massif de jobs.

À mesure que le projet est devenu plus temps réel et plus asynchrone, une nouvelle question est apparue :

> Comment garantir que le système puisse reprendre automatiquement sans corruption de données ?

Ce problème est devenu central lorsque l’architecture Cluster est passée :

```text
cron simple
↓
scan massif
↓
temps réel
↓
Sidekiq
↓
pipeline incrémental
↓
watchers ZMQ
↓
refresh async
```

À partir de ce moment-là, le système ne pouvait plus simplement “redémarrer”.

Il fallait concevoir une vraie stratégie de recovery.

---

## Pourquoi le recovery est devenu critique

Au début, Bitcoin Monitor fonctionnait principalement avec des cron jobs :

```text
cron
↓
scan blockchain
↓
mise à jour SQL
```

Le modèle était simple :

* un cron échoue,
* il sera relancé plus tard.

Mais avec l’arrivée du temps réel, plusieurs composants sont devenus dépendants :

```text
bitcoind
↓
ZMQ watcher
↓
Realtime::ProcessLatestBlockJob
↓
Sidekiq
↓
ClusterScanner
↓
Cluster refresh
↓
Signals
↓
Dashboard
```

Un arrêt d’un seul maillon pouvait créer :

* du retard,
* des données incohérentes,
* un backlog Redis,
* des clusters non rafraîchis,
* des signaux obsolètes,
* une fausse impression de temps réel.

Le recovery n’était plus un “bonus”.

C’était devenu une nécessité d’architecture.

---

## Le principe fondamental

Le système devait devenir :

```text
résilient
```

C’est-à-dire capable de :

* détecter son état,
* détecter les retards,
* mesurer la fraîcheur,
* reprendre automatiquement,
* éviter les doubles traitements,
* continuer même après panne.

---

## Les curseurs comme fondation du recovery

La base du recovery dans Bitcoin Monitor repose sur un élément extrêmement simple :

```ruby
ScannerCursor
```

Chaque pipeline possède un curseur :

```text
cluster_scan
exchange_observed_scan
exchange_address_builder
realtime_block_watcher
realtime_block_stream
```

Chaque curseur stocke :

```text
last_blockheight
last_blockhash
updated_at
```

Cela permet au système de savoir :

* ce qui a déjà été traité,
* où reprendre,
* si un module est bloqué,
* si les données sont fraîches,
* si un service est en retard.

---

## Exemple : protection contre le double traitement

Le temps réel a rapidement révélé un problème :

```text
même bloc traité plusieurs fois
```

Les logs montraient :

```text
latest_block_processed height=946547
```

puis immédiatement :

```text
already_linked_txs=100
links_created=0
```

Le système retraitait donc le même bloc.

La solution a été d’ajouter un verrou basé sur le curseur :

```ruby
if cursor.last_blockheight.to_i >= height &&
   cursor.last_blockhash == blockhash

  Rails.logger.info(
    "[realtime] skip_already_processed"
  )

  return
end
```

Ce mécanisme simple est devenu une brique majeure du recovery.

---

## Reprendre après interruption

Lorsqu’un watcher redémarre, il ne repart pas “à zéro”.

Il lit son curseur :

```ruby
ScannerCursor.find_by(
  name: "realtime_block_stream"
)
```

Puis reprend automatiquement :

```text
dernier bloc connu
↓
nouveau best height
↓
scan incrémental
↓
rattrapage
```

Cela permet :

* de redémarrer après panne,
* de reprendre après maintenance,
* d’éviter les rescans complets,
* de limiter la charge CPU,
* de préserver Redis et PostgreSQL.

---

## Sidekiq et la reprise automatique

Le passage à Sidekiq a profondément changé la stratégie de recovery.

Avant :

```text
cron
↓
traitement synchrone
```

Après :

```text
watcher
↓
enqueue Sidekiq
↓
worker async
↓
retry
↓
dead queue
```

Cela a apporté plusieurs mécanismes essentiels :

### Retry automatique

Un job échoue :

```text
réessai automatique
```

sans intervention manuelle.

---

### Backlog observable

Le système peut mesurer :

```text
queue_size
latency
retry_size
dead_size
```

et afficher cela dans `/system`.

---

### Reprise après reboot

Si Redis et Sidekiq redémarrent :

```text
les jobs reprennent
```

au lieu d’être perdus.

---

## Le rôle de systemd

Les watchers temps réel ne pouvaient pas dépendre d’un terminal ouvert.

Ils ont donc été transformés en services systemd user :

```text
zmq-block-watcher.service
sidekiq-bitcoin-monitor.service
```

Exemple :

```text
systemctl --user status zmq-block-watcher
```

Le watcher devient alors :

* supervisé,
* relancé automatiquement,
* observable,
* intégré au système Linux.

---

## La supervision dans `/system`

Une étape importante a été la création d’un vrai dashboard de recovery.

Le système expose maintenant :

```text
watcher status
processor status
lag
freshness
queues
retry
dead jobs
disk usage
bitcoind RPC
```

Exemple :

```text
Watcher
OK

Processor
OK

Last height
946567
```

ou :

```text
STALE
```

si un composant ne bouge plus.

Le dashboard `/system` est devenu un outil opérationnel central.

---

## Recovery readiness

Une idée importante est apparue progressivement :

```text
le système doit expliquer lui-même
comment il peut redémarrer
```

C’est la naissance du concept :

```text
Recovery readiness
```

Le système affiche :

* les problèmes critiques,
* les jobs bloqués,
* l’ordre de reprise,
* les modules en retard,
* les dépendances critiques.

Exemple :

```text
btc_price_daily
↓
market_snapshot
↓
exchange_observed_scan
↓
cluster_scan
↓
cluster_signals
```

Cela transforme le dashboard en véritable centre de supervision.

---

## Le temps réel a changé la philosophie du projet

Le passage au temps réel a obligé Bitcoin Monitor à évoluer :

Avant :

```text
application Rails
```

Après :

```text
système distribué de traitement blockchain
```

Le recovery n’est plus une fonctionnalité secondaire.

C’est devenu :

* une discipline,
* une architecture,
* une philosophie de conception.

---

## Ce que cette évolution a apporté

Le système est maintenant capable de :

* reprendre automatiquement après panne,
* éviter les doubles traitements,
* détecter les retards,
* mesurer la fraîcheur,
* superviser Sidekiq,
* superviser Redis,
* superviser bitcoind,
* surveiller les pipelines,
* afficher l’état réel de la plateforme.

---

## Une leçon importante

Le vrai défi n’était pas :

```text
traiter les blocs
```

Le vrai défi était :

```text
continuer à traiter correctement
même après interruption
```

C’est cette réflexion qui a progressivement transformé Bitcoin Monitor en une architecture beaucoup plus professionnelle. 
