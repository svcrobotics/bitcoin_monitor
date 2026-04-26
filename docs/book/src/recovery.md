# Recovery

Bitcoin Monitor ne traite pas uniquement des données blockchain.

L’application doit aussi survivre :

* à un redémarrage serveur,
* à une coupure électrique,
* à un crash Sidekiq,
* à une désynchronisation de `bitcoind`,
* à une interruption réseau,
* à un arrêt prolongé des workers,
* à un backlog massif de jobs,
* ou à une perte temporaire du temps réel.

À mesure que l’architecture est devenue plus temps réel, plus incrémentale et plus asynchrone, une nouvelle problématique est apparue :

> Comment garantir que le système puisse reprendre automatiquement sans corruption, sans double traitement et sans rescan massif ?

Ce problème est devenu central lorsque l’architecture Cluster a progressivement évolué :

```text
cron simple
↓
scan massif
↓
pipeline incrémental
↓
Sidekiq
↓
temps réel
↓
watchers ZMQ
↓
refresh async
↓
recovery orchestration
```

À partir de ce moment-là, le système ne pouvait plus simplement “redémarrer”.

Il fallait concevoir une véritable architecture de recovery.

---

## Pourquoi le recovery est devenu critique

Au début, Bitcoin Monitor reposait principalement sur des cron jobs :

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

Mais avec l’arrivée du temps réel, les dépendances se sont multipliées :

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

Un seul maillon bloqué pouvait provoquer :

* du retard,
* des données incohérentes,
* des jobs en boucle,
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

* détecter son état réel,
* mesurer les retards,
* mesurer la fraîcheur,
* reprendre automatiquement,
* éviter les doubles traitements,
* éviter les boucles infinies,
* continuer même après panne,
* expliquer clairement ce qui est bloqué.

---

## Les curseurs comme fondation du recovery

La base du recovery dans Bitcoin Monitor repose sur un élément extrêmement simple :

```ruby
ScannerCursor
```

Chaque pipeline possède un curseur dédié :

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
* si un pipeline est en retard,
* si un traitement est réellement actif.

---

## Exemple : protection contre le double traitement

Le passage au temps réel a rapidement révélé un problème classique :

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

Le système retraitait donc les mêmes données.

La solution a été d’ajouter une protection basée sur le curseur :

```ruby
if cursor.last_blockheight.to_i >= height &&
   cursor.last_blockhash == blockhash

  Rails.logger.info(
    "[realtime] skip_already_processed"
  )

  return
end
```

Ce mécanisme simple est devenu une brique centrale du recovery.

---

## Reprendre automatiquement après interruption

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
best height actuel
↓
scan incrémental
↓
rattrapage progressif
```

Cela permet :

* de redémarrer après panne,
* de reprendre après maintenance,
* d’éviter les rescans complets,
* de limiter la charge CPU,
* de protéger Redis,
* de préserver PostgreSQL.

---

## Sidekiq et la reprise automatique

Le passage à Sidekiq a profondément transformé la stratégie de recovery.

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

Cela a apporté plusieurs mécanismes essentiels.

---

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

et afficher ces métriques dans `/system/recovery`.

---

### Reprise après reboot

Si Redis ou Sidekiq redémarrent :

```text
les jobs reprennent
```

au lieu d’être perdus.

---

## Une leçon importante : les jobs ne doivent jamais s’auto-boucler

Une erreur critique découverte pendant le développement concernait les jobs auto-relancés.

Exemple réel :

```ruby
InflowOutflowDetailsBuildJob.perform_later
```

appelé directement à l’intérieur du job lui-même.

Conséquence :

```text
job
↓
enqueue lui-même
↓
re-exécution
↓
nouvel enqueue
↓
boucle infinie
```

Le résultat :

* explosion du backlog Sidekiq,
* workers saturés,
* duplication des traitements,
* recovery bloqué.

La correction a consisté à :

* supprimer les auto-enqueue,
* centraliser l’orchestration,
* empêcher les doublons,
* contrôler les pipelines depuis un orchestrateur unique.

Cette erreur a fortement influencé l’architecture recovery finale.

---

## Le rôle des locks

Le système utilise plusieurs locks :

```text
realtime_processing_lock
exchange_observed_scan_lock
recovery_orchestrator_lock
```

Ces locks permettent de :

* empêcher les doubles exécutions,
* protéger les pipelines critiques,
* superviser les workers,
* détecter les traitements inactifs.

Mais une leçon importante est apparue :

> un lock ancien n’est pas forcément un problème.

Au début, tout lock “vieux” apparaissait comme :

```text
OLD
```

même lorsque le système était parfaitement synchronisé.

Le dashboard a ensuite été amélioré avec une logique contextuelle :

```text
ACTIVE
IDLE
WAITING
STALE
```

Le statut dépend maintenant :

* de l’âge du lock,
* ET du lag réel du pipeline associé.

Exemple :

```text
IDLE
lag lié: 0
Repos normal : aucun retard critique.
```

Cela a permis d’éviter de faux diagnostics.

---

## systemd et la supervision Linux

Les watchers temps réel ne pouvaient pas dépendre d’un terminal ouvert.

Ils ont donc été transformés en services systemd :

```text
zmq-block-watcher.service
sidekiq-bitcoin-monitor.service
```

Exemple :

```bash
systemctl --user status zmq-block-watcher
```

Les watchers deviennent alors :

* supervisés,
* relancés automatiquement,
* observables,
* intégrés au système Linux.

---

## Le dashboard `/system/recovery`

Une étape importante a été la création d’un véritable centre de supervision recovery.

Le système expose désormais :

```text
best height
realtime lag
exchange lag
cluster lag
pipeline status
queues Sidekiq
workers actifs
locks
recovery jobs
ETA
vitesse de rattrapage
```

Exemple :

```text
state: healthy
realtime_lag: 1
cluster_lag: 0
exchange_lag: 0
```

ou :

```text
STALLED
```

si un pipeline critique ne progresse plus.

---

## Recovery orchestration

Le système possède maintenant une logique d’orchestration recovery.

Le recovery n’est plus “passif”.

Le système sait :

* quel pipeline doit repartir en premier,
* quel lag est critique,
* quels jobs sont actifs,
* quels jobs sont bloqués,
* quels modules doivent attendre.

Exemple :

```text
P0 realtime
↓
P1 exchange scan
↓
P2 inflow/outflow
↓
P3 cluster scan
↓
P4 analytics
```

Cette hiérarchie évite :

* les recalculs inutiles,
* les backlogs massifs,
* les pipelines incohérents.

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

Le dashboard affiche désormais :

* les problèmes critiques,
* les pipelines en retard,
* les lags,
* les jobs actifs,
* les locks,
* les ETA,
* la progression du recovery,
* les dépendances critiques,
* les vitesses estimées de rattrapage.

Le dashboard est progressivement devenu :

```text
un centre de supervision opérationnel
```

et non plus une simple page système.

---

## Le temps réel a changé la philosophie du projet

Le passage au temps réel a transformé Bitcoin Monitor.

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
* une philosophie de conception,
* une couche critique de fiabilité.

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
* superviser les pipelines,
* superviser les locks,
* afficher l’état réel de la plateforme,
* orchestrer le recovery automatiquement,
* limiter les rescans massifs,
* expliquer les blocages en temps réel.

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
