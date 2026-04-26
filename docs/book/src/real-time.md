# Temps réel : quand Bitcoin Monitor a commencé à écouter Bitcoin

> Pendant longtemps, Bitcoin Monitor observait la blockchain.
>
> Puis un jour, l’application a commencé à l’écouter.

Ce chapitre raconte la transition progressive entre une architecture batch classique basée sur des cron et une architecture événementielle temps réel alimentée par Bitcoin Core via ZMQ, Redis Streams et Turbo Streams.

---

## Pourquoi le batch ne suffisait plus

Au début, Bitcoin Monitor fonctionnait selon un modèle très classique :

```text
cron
↓
scan blockchain
↓
PostgreSQL
↓
dashboard
````

Ce système était robuste, simple et prévisible.

Mais une limite devenait de plus en plus visible :

> la blockchain évolue en permanence, mais l’application ne réagissait qu’à intervalles réguliers.

Pour certains modules, ce n’était pas grave.

Mais pour :

* Cluster,
* Exchange Flow,
* Signals,
* Realtime dashboards,
* alertes,
* supervision live,

cela devenait une contrainte architecturale.

---

## La vraie question

La question n’était pas seulement :

> “comment faire du temps réel ?”

La vraie question était :

> “quel socle construire pour que plusieurs modules puissent réagir au même événement Bitcoin ?”

Le choix retenu n’a pas été de rendre immédiatement tous les modules temps réel.

Le choix a été :

```text
construire un flux événementiel central
```

D’abord :

```text
Realtime::BlockStream
```

Puis progressivement :

```text
Redis Stream bitcoin.blocks
```

Autrement dit :

> construire un pipeline centralisé capable de recevoir un nouveau bloc Bitcoin, de le publier comme événement, puis de laisser plusieurs consommateurs spécialisés réagir.

---

## L’idée du pipeline événementiel

L’architecture cible devient :

```text
Bitcoin Core
↓
ZMQ
↓
zmq_block_watcher
↓
Redis Stream bitcoin.blocks
↓
workers spécialisés
↓
PostgreSQL + cache
↓
Turbo Streams / ActionCable
↓
UI live
```

Le changement de philosophie est énorme.

Avant :

```text
l’application demande régulièrement :
“y a-t-il du nouveau ?”
```

Après :

```text
Bitcoin Core annonce :
“un nouveau bloc vient d’arriver”
```

Puis Bitcoin Monitor publie cet événement dans un flux interne.

---

## Première version : polling RPC

La première version temps réel n’utilisait pas encore ZMQ.

Elle utilisait simplement :

```text
getblockcount
```

dans une boucle Ruby.

Le premier watcher :

```text
bin/realtime_block_watcher
```

fonctionnait ainsi :

```text
boucle
↓
getblockcount
↓
nouveau bloc ?
↓
enqueue Sidekiq job
```

Simple, minimaliste, mais suffisant pour valider l’architecture.

---

## Premier job temps réel

Le premier job créé :

```text
Realtime::ProcessLatestBlockJob
```

avait une responsabilité volontairement limitée :

```text
traiter le dernier bloc connu
```

Architecture :

```text
watcher
↓
Sidekiq
↓
Realtime::ProcessLatestBlockJob
↓
ClusterScanner
↓
refresh async
```

Le premier consommateur du temps réel était donc le module Cluster.

---

## Pourquoi Cluster était le premier candidat

Le module Cluster était déjà prêt.

Il possédait déjà :

* un scanner incrémental,
* des jobs Sidekiq,
* Redis,
* un refresh asynchrone,
* des dirty clusters,
* des métriques,
* des signaux,
* un curseur de reprise.

Le pipeline existait déjà :

```text
scan
↓
dirty clusters
↓
refresh async
↓
metrics
↓
signals
```

Il ne manquait qu’une chose :

> le déclenchement événementiel.

---

## Première validation

Le premier test manuel :

```bash
bin/rails realtime:process_latest_block
```

a montré que le pipeline fonctionnait.

Dans les logs :

```text
[realtime] latest_block_processed height=946547
```

Et surtout :

```text
dirty_clusters_count > 0
links_created > 0
clusters_created > 0
```

Le temps réel devenait concret.

---

## Premier vrai problème : le même bloc traité deux fois

Très vite, les logs ont révélé un problème important :

```text
height=946547 traité plusieurs fois
```

Premier passage :

```text
links_created=230
clusters_created=54
```

Deuxième passage :

```text
already_linked_txs=100
links_created=0
```

Le système ne cassait pas.

Mais il retraitait inutilement les mêmes données.

---

## L’idempotence devient obligatoire

Pour corriger cela, un curseur dédié a été introduit :

```text
ScannerCursor
name = realtime_block_stream
```

Avant chaque traitement :

```ruby
if cursor.last_blockheight >= height
```

alors :

```text
skip_already_processed
```

apparaît dans les logs.

Le système devient alors :

* résistant aux retries,
* résistant aux redémarrages,
* compatible avec Sidekiq,
* compatible avec systemd.

C’est une règle fondamentale des systèmes événementiels :

> un événement peut arriver plusieurs fois.

Le système doit survivre à cela.

---

## Le watcher devient observable

Ensuite, un deuxième curseur a été ajouté :

```text
realtime_block_watcher
```

Sa responsabilité :

```text
dernier bloc vu
```

alors que :

```text
realtime_block_stream
```

représente :

```text
dernier bloc traité
```

Cette séparation est essentielle.

---

## La distinction Watcher / Processor

Bitcoin Monitor distingue désormais deux responsabilités.

### Watcher

Responsable de :

* détecter les nouveaux blocs,
* écouter Bitcoin Core,
* mettre à jour son curseur,
* publier l’événement,
* déclencher le traitement.

### Processor

Responsable de :

* scanner les blocs,
* mettre à jour Cluster,
* mettre à jour Exchange,
* recalculer les signaux,
* mettre à jour les curseurs de traitement.

Détecter n’est pas traiter.

---

## Première supervision dans `/system`

Une nouvelle carte apparaît dans le dashboard système :

```text
Realtime block stream
```

avec :

```text
Watcher
Processor
```

Pour chacun :

* status,
* last height,
* hash,
* age,
* freshness.

C’est une étape très importante.

Parce qu’un système temps réel invisible est dangereux.

---

## Pourquoi Sidekiq était indispensable

Le watcher ne devait jamais :

* bloquer Rails,
* scanner directement,
* faire des traitements lourds.

Son rôle devait rester minimal :

```text
détection
↓
publication événement
↓
enqueue job
↓
fin
```

Sidekiq devient alors le moteur du traitement asynchrone.

---

## Le premier problème Sidekiq

À un moment :

```text
watcher height != processor height
```

Le watcher voyait bien les nouveaux blocs.

Mais le processor restait bloqué.

Cause :

```text
Sidekiq n’était pas redémarré via systemd
```

Après :

```bash
systemctl --user restart sidekiq-bitcoin-monitor
```

les deux curseurs se réalignent :

```text
watcher   height=946548
processor height=946548
```

C’est exactement ce que le dashboard `/system` devait permettre de voir immédiatement.

---

## Le passage à ZMQ

Le polling RPC fonctionnait.

Mais il posait une question logique :

> pourquoi demander régulièrement à Bitcoin Core s’il y a un nouveau bloc, alors qu’il peut les publier lui-même ?

C’est là que ZMQ entre en scène.

---

## Configuration ZMQ dans Bitcoin Core

Le fichier `bitcoin.conf` évolue :

```conf
rpcbind=127.0.0.1
rpcbind=::1
rpcallowip=127.0.0.1
rpcallowip=::1
rpcport=8332

datadir=/var/lib/bitcoind

maxconnections=24
maxuploadtarget=1000
dbcache=2048

txindex=0
blockfilterindex=0

rpcworkqueue=64
rpcthreads=16

loadwallet=vault_watch3
prune=55000

zmqpubhashblock=tcp://127.0.0.1:28332
zmqpubhashtx=tcp://127.0.0.1:28333
```

Les lignes importantes :

```conf
zmqpubhashblock
zmqpubhashtx
```

Bitcoin Core commence alors à publier :

* les nouveaux blocs,
* les nouvelles transactions.

---

## Première erreur : mauvais datadir

Premier test :

```bash
bitcoin-cli getzmqnotifications
```

Erreur :

```text
Could not locate RPC credentials
```

Le problème n’était pas ZMQ.

Le problème venait du fait que :

```text
bitcoin-cli utilisait ~/.bitcoin
```

alors que le vrai datadir était :

```text
/var/lib/bitcoind
```

La bonne commande devient :

```bash
bitcoin-cli -datadir=/var/lib/bitcoind getzmqnotifications
```

Et enfin :

```json
[
  {
    "type": "pubhashblock",
    "address": "tcp://127.0.0.1:28332"
  }
]
```

Bitcoin Core publie maintenant les événements blockchain.

---

## Le watcher ZMQ

Un nouveau watcher apparaît :

```text
bin/zmq_block_watcher
```

Cette fois, l’application ne poll plus.

Elle écoute directement Bitcoin Core.

Architecture initiale :

```text
bitcoind ZMQ
↓
zmq_block_watcher
↓
Sidekiq
↓
Realtime::ProcessLatestBlockJob
```

Puis l’architecture évolue :

```text
bitcoind ZMQ
↓
zmq_block_watcher
↓
Redis Stream bitcoin.blocks
↓
Sidekiq / workers spécialisés
```

---

## Deuxième problème : libzmq absente

Premier lancement :

```bash
bin/zmq_block_watcher
```

Erreur :

```text
Unable to load this gem.
The libzmq library could not be found.
```

Le gem Ruby existait.

Mais pas la librairie système native.

Correction :

```bash
sudo apt install libzmq3-dev
```

C’est un rappel important :

```text
gem Ruby ≠ dépendance système native
```

---

## Troisième problème : FrozenError

Ensuite :

```text
can't modify frozen String
```

dans :

```text
ffi-rzmq/socket.rb
```

Le watcher crashait.

Mais systemd le redémarrait automatiquement :

```text
Scheduled restart job
Started zmq-block-watcher.service
```

C’est exactement pour cela que les watchers doivent être supervisés.

---

## Systemd devient obligatoire

Le watcher devient un vrai service :

```text
zmq-block-watcher.service
```

Vérification :

```bash
systemctl --user status zmq-block-watcher
```

Résultat :

```text
Active: active (running)
```

Le watcher n’est plus un simple terminal Ruby.

Il devient une pièce d’infrastructure.

---

## L’ancien watcher RPC est désactivé

Deux watchers existaient :

```text
realtime-block-watcher
zmq-block-watcher
```

Le premier utilisait :

* polling RPC,
* boucle Ruby.

Le second :

* écoute ZMQ,
* événements natifs Bitcoin Core.

Le watcher RPC devient alors :

```text
inactive (dead)
```

ZMQ devient la source officielle du temps réel.

---

## Redis Streams : le tournant architectural

Après ZMQ, une nouvelle étape majeure est ajoutée :

```text
Redis Stream bitcoin.blocks
```

L’objectif n’est plus seulement de lancer un job.

L’objectif devient de publier un événement réutilisable.

Un nouveau service apparaît :

```text
Realtime::BlockEventProducer
```

Il écrit dans Redis Stream :

```ruby
Realtime::BlockEventProducer.call(
  height: height,
  blockhash: blockhash
)
```

L’événement ressemble à ceci :

```text
type       new_block
height     946798
blockhash  000000000000000000017c51640fcc139c81c7cc1695f8600978d0d17f44955a
created_at 1777243718
```

Redis Stream devient alors :

```text
le bus d’événements blockchain interne
```

Ce n’est plus une simple queue.

C’est un journal d’événements.

---

## Pourquoi Redis Streams change tout

Avant :

```text
ZMQ
↓
Sidekiq job
↓
traitement
```

Après :

```text
ZMQ
↓
Redis Stream bitcoin.blocks
↓
plusieurs consommateurs
```

La différence est majeure.

Un même événement `new_block` peut alimenter :

```text
Cluster
Exchange
Whales
Alerts
Metrics
UI live
```

Visuellement :

```text
bitcoin.blocks
├── Cluster worker
├── Exchange worker
├── Whale worker
├── Alert worker
├── Metrics worker
└── UI broadcaster
```

Cela transforme Bitcoin Monitor en architecture event-driven.

---

## Premier vrai événement live

Après redémarrage du watcher ZMQ, un nouveau bloc réel arrive :

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

Ce n’est plus un test.

C’est un vrai événement Bitcoin reçu en live depuis le nœud local.

Bitcoin Monitor possède désormais un flux blockchain temps réel.

---

## Plusieurs streams demain

Le premier stream est :

```text
bitcoin.blocks
```

Mais l’architecture ouvre la voie à plusieurs flux spécialisés :

| Stream                   | Rôle                  |
| ------------------------ | --------------------- |
| `bitcoin.blocks`         | nouveaux blocs        |
| `bitcoin.transactions`   | transactions          |
| `bitcoin.whales`         | transferts importants |
| `bitcoin.exchange_flows` | inflow/outflow        |
| `bitcoin.alerts`         | alertes critiques     |
| `bitcoin.metrics`        | analytics calculés    |

L’application passe d’un modèle :

```text
jobs qui interrogent la base
```

à un modèle :

```text
modules qui réagissent à des événements
```

---

## Turbo Streams : l’UI devient vivante

Une fois l’événement publié dans Redis Stream, une nouvelle étape devient possible :

```text
afficher le bloc en live dans l’interface
```

Un partial est créé :

```text
app/views/system/realtime/_latest_block.html.erb
```

Il contient la cible Turbo :

```html
<div id="latest_block_live">
```

La page `/system` s’abonne au flux :

```erb
<%= turbo_stream_from "bitcoin_blocks" %>
```

Puis un broadcaster est ajouté :

```text
Realtime::BlockEventBroadcaster
```

Il envoie le remplacement Turbo :

```ruby
Turbo::StreamsChannel.broadcast_replace_to(
  "bitcoin_blocks",
  target: "latest_block_live",
  partial: "system/realtime/latest_block",
  locals: {
    block: {
      height: height,
      blockhash: blockhash,
      created_at: created_at
    }
  }
)
```

Le résultat :

```text
nouveau bloc Bitcoin
↓
ZMQ
↓
Redis Stream
↓
Turbo Stream
↓
carte live dans /system
```

Pour la première fois, `/system` change sans refresh navigateur.

---

## Validation de l’UI live

Un premier test manuel :

```ruby
Turbo::StreamsChannel.broadcast_replace_to(
  "bitcoin_blocks",
  target: "latest_block_live",
  html: "<div id=\"latest_block_live\">LIVE TEST</div>"
)
```

a validé que :

```text
ActionCable fonctionne
Turbo Streams fonctionne
la page écoute bien le channel
```

Puis le service applicatif a été testé :

```ruby
Realtime::BlockEventBroadcaster.call(
  height: 947000,
  blockhash: "service_test_hash",
  created_at: Time.current
)
```

La carte `/system` s’est mise à jour instantanément :

```text
Live block stream
947000
service_test_hash
reçu à 2026-04-27 01:28:44 +0200
```

La chaîne WebSocket est donc opérationnelle.

---

## Protection anti-backlog

Un autre point critique a été ajouté : empêcher le watcher d’empiler plusieurs jobs realtime identiques.

Avant :

```text
nouveau bloc
↓
enqueue
↓
nouveau bloc
↓
enqueue
↓
backlog possible
```

Maintenant, avant d’enqueue :

```ruby
realtime_queue_size = Sidekiq::Queue.new("realtime").size

realtime_running =
  Sidekiq::Workers.new.any? do |_, _, work|
    payload = work.payload
    work.queue == "realtime" &&
      (payload["wrapped"] == "Realtime::ProcessLatestBlockJob" ||
       payload["class"] == "Realtime::ProcessLatestBlockJob")
  end

if realtime_queue_size.zero? && !realtime_running
  Realtime::ProcessLatestBlockJob.perform_later
else
  Rails.logger.info("[realtime] skip_enqueue already_pending")
end
```

Cette protection est indispensable dans un système temps réel.

Elle évite qu’un pic d’événements crée un backlog inutile.

---

## Le pipeline actuel

À ce stade, l’architecture réelle devient :

```text
Bitcoin Core
↓
ZMQ
↓
zmq_block_watcher
↓
Redis Stream bitcoin.blocks
↓
Turbo Stream live UI
↓
Sidekiq realtime job
↓
Realtime::ProcessLatestBlockJob
↓
ClusterScanner
↓
dirty clusters
↓
refresh async
↓
metrics
↓
signals
↓
dashboard
```

Ce pipeline combine :

* ZMQ pour la détection immédiate,
* Redis Streams pour le bus d’événements,
* Sidekiq pour les traitements lourds,
* Turbo Streams pour l’interface live,
* PostgreSQL pour la persistance,
* `/system` pour l’observabilité.

---

## Ce que cela change réellement

Bitcoin Monitor ne fonctionne plus uniquement “par période”.

L’application réagit désormais :

* aux blocs,
* aux événements,
* au flux réel de la blockchain.

La page `/system` n’est plus seulement un tableau de bord statique.

Elle devient une interface vivante.

---

## Les leçons apprises

### Le temps réel doit être progressif

Commencer par :

* polling RPC,
* jobs simples,
* logs.

Puis seulement :

* ZMQ,
* Redis Streams,
* systemd,
* Turbo Streams,
* supervision.

---

### Le temps réel doit être observable

Sans `/system` :

* impossible de savoir si le pipeline fonctionne,
* impossible de voir les retards,
* impossible de diagnostiquer les blocages.

---

### Watcher et Processor sont deux responsabilités différentes

Détecter :

```text
≠
traiter
```

Publier :

```text
≠
analyser
```

Afficher :

```text
≠
persister
```

---

### Les cron restent indispensables

Le temps réel accélère.

Les cron sécurisent :

* le rattrapage,
* les reconstructions,
* la cohérence.

Architecture finale :

```text
ZMQ            = détection immédiate
Redis Streams  = bus d’événements
Sidekiq        = orchestration lourde
Turbo Streams  = UI live
cron           = filet de sécurité
/system        = observabilité
```

---

## Conclusion

Le passage au temps réel représente une étape fondamentale dans Bitcoin Monitor.

Le projet est passé :

```text
application Rails batch
```

à :

```text
plateforme blockchain événementielle
```

L’application ne demande plus simplement :

> “où en est la blockchain ?”

Elle écoute désormais :

> “la blockchain vient de changer.”

Puis elle publie, traite, affiche et supervise cet événement en temps réel.

