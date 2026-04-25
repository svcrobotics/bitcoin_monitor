# Chapitre — Temps réel : quand Bitcoin Monitor a commencé à écouter Bitcoin

> Pendant longtemps, Bitcoin Monitor observait la blockchain.
>
> Puis un jour, l’application a commencé à l’écouter.

Ce chapitre raconte la transition progressive entre une architecture batch classique basée sur des cron et une architecture événementielle temps réel alimentée par Bitcoin Core via ZMQ. 

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
```

Ce système était robuste.

Simple.

Prévisible.

Mais une limite devenait de plus en plus visible :

> la blockchain évolue en permanence, mais l’application ne réagissait qu’à intervalles réguliers.

Pour certains modules, ce n’était pas grave.

Mais pour :

* Cluster,
* Exchange Flow,
* Signals,
* Realtime dashboards,

cela devenait une contrainte architecturale.

## La vraie question

La question n’était pas :

> “comment faire du temps réel ?”

La vraie question était :

> “quel module mérite réellement du temps réel maintenant ?”

Le choix retenu n’a pas été :

```text
Cluster temps réel
```

mais :

```text
Realtime::BlockStream
```

Autrement dit :

> construire un pipeline événementiel centralisé capable de réagir à un nouveau bloc Bitcoin.

Le premier consommateur de ce pipeline serait Cluster.

## L’idée du pipeline événementiel

L’architecture cible devenait :

```text
bitcoind
↓
nouveau bloc détecté
↓
Realtime::BlockIngestor
↓
Sidekiq
↓
Cluster scan incrémental
↓
refresh async
↓
signals
↓
dashboard
```

Le changement de philosophie était énorme.

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

## Pourquoi Cluster était le premier candidat

Le module Cluster était déjà prêt.

Il possédait déjà :

* un scanner incrémental,
* des jobs Sidekiq,
* Redis,
* un refresh asynchrone,
* des dirty clusters,
* des métriques,
* des signaux.

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

## Première version : polling RPC

La première V1 temps réel n’utilisait même pas ZMQ.

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

Simple.

Minimaliste.

Mais suffisant pour valider toute l’architecture.

## Premier job temps réel

Le premier job créé :

```text
Realtime::ProcessLatestBlockJob
```

avait une responsabilité volontairement limitée :

```text
traiter uniquement le dernier bloc
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

## Première validation

Le premier test manuel :

```bash
bin/rails realtime:process_latest_block
```

a immédiatement montré que le pipeline fonctionnait.

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

## La distinction Watcher / Processor

Bitcoin Monitor distingue désormais :

### Watcher

Responsable de :

* détecter les nouveaux blocs,
* écouter Bitcoin Core,
* déclencher les jobs.

### Processor

Responsable de :

* scanner les blocs,
* mettre à jour Cluster,
* recalculer les signaux,
* mettre à jour les curseurs.

Ce ne sont pas les mêmes responsabilités.

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

## Pourquoi Sidekiq était indispensable

Le watcher ne devait jamais :

* bloquer Rails,
* scanner directement,
* faire des traitements lourds.

Son rôle devait rester minimal :

```text
détection
↓
enqueue job
↓
fin
```

Sidekiq devient alors le moteur du traitement asynchrone.

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

## Le passage à ZMQ

Le polling RPC fonctionnait.

Mais il posait une question logique :

> pourquoi demander régulièrement à Bitcoin Core s’il y a un nouveau bloc, alors qu’il peut les publier lui-même ?

C’est là que ZMQ entre en scène.

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

## Le watcher ZMQ

Un nouveau watcher apparaît :

```text
bin/zmq_block_watcher
```

Cette fois, l’application ne poll plus.

Elle écoute directement Bitcoin Core.

Architecture :

```text
bitcoind ZMQ
↓
zmq_block_watcher
↓
Sidekiq
↓
Realtime::ProcessLatestBlockJob
```

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

## Le pipeline final

L’architecture devient :

```text
Bitcoin Core
↓
ZMQ
↓
zmq-block-watcher
↓
Sidekiq
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

## Ce que cela change réellement

Bitcoin Monitor ne fonctionne plus uniquement “par période”.

L’application réagit désormais :

* aux blocs,
* aux événements,
* au flux réel de la blockchain.

C’est un changement architectural majeur.

## Les leçons apprises

### Le temps réel doit être progressif

Commencer par :

* polling RPC,
* jobs simples,
* logs.

Puis seulement :

* ZMQ,
* systemd,
* supervision.

### Le temps réel doit être observable

Sans `/system` :

* impossible de savoir si le pipeline fonctionne,
* impossible de voir les retards,
* impossible de diagnostiquer les blocages.

### Watcher et Processor sont deux responsabilités différentes

Détecter :

```text
≠
traiter
```

### Les cron restent indispensables

Le temps réel accélère.

Les cron sécurisent :

* le rattrapage,
* les reconstructions,
* la cohérence.

Architecture finale :

```text
ZMQ      = accélérateur
Sidekiq  = orchestration
cron     = filet de sécurité
/system  = observabilité
```

## Conclusion

Le passage au temps réel représente une étape fondamentale dans Bitcoin Monitor.

Le projet est passé :

* d’une application Rails batch,
* à une plateforme blockchain événementielle.

L’application ne demande plus simplement :

> “où en est la blockchain ?”

Elle écoute désormais :

> “la blockchain vient de changer.”
