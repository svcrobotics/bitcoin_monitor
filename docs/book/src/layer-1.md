# Layer 1 : le moment où Bitcoin Monitor a séparé la collecte de l’intelligence

> Au début, chaque module voulait lire la blockchain à sa manière.
>
> Puis une évidence est apparue :
>
> > si chaque module rescane Bitcoin Core, l’application finit par devenir lente, fragile et impossible à maintenir.

Ce chapitre raconte comment Bitcoin Monitor a commencé à construire son propre **Layer 1** : une couche centrale responsable de récupérer les blocs, extraire les données brutes, les stocker proprement, puis les rendre disponibles aux modules métiers.

---

## 1. Le problème initial

Bitcoin Monitor avait plusieurs modules :

* Cluster,
* Exchange-like,
* Whale,
* Inflow / Outflow,
* Recovery,
* Realtime.

Chacun avait besoin de données blockchain.

Mais progressivement, un problème est apparu :

```text
chaque module voulait interroger bitcoind
````

Cela semblait pratique au début.

Mais à mesure que le projet grandissait, cette approche créait plusieurs risques :

* appels RPC répétés,
* scans redondants,
* logique dupliquée,
* lenteur,
* difficulté de recovery,
* difficulté de monitoring,
* dépendances floues entre modules.

Autrement dit :

> la blockchain était lue plusieurs fois, par plusieurs chemins différents, sans source officielle unique.

---

## 2. Le déclic architectural

Le vrai déclic a été de comprendre que Bitcoin Monitor ne devait plus être organisé autour des modules uniquement.

Il fallait d’abord construire une base commune :

```text
Bitcoin Core
↓
Layer 1
↓
Modules métier
```

Le Layer 1 devient alors :

> la source officielle des données blockchain dans l’application.

Son rôle n’est pas d’analyser.

Son rôle est de :

* collecter,
* bufferiser,
* parser,
* persister,
* exposer des données propres.

L’intelligence vient ensuite.

---

## 3. Séparer collecte et traitement

La règle principale est devenue :

```text
Layer 1 collecte les données.
Les modules interprètent les données.
```

Cela change profondément l’architecture.

Avant :

```text
Cluster → bitcoind
Exchange-like → bitcoind
Whale → bitcoind
Inflow / Outflow → tables intermédiaires
```

Après :

```text
bitcoind
↓
Layer 1
↓
tx_outputs / events / edges / block_buffers
↓
Cluster / Exchange-like / Whale / Inflow-Outflow
```

Cette séparation est importante parce qu’elle évite de mélanger :

* extraction brute,
* logique métier,
* scoring,
* visualisation,
* recovery.

---

## 4. Les responsabilités du Layer 1

Le Layer 1 ne doit pas tout faire.

Il doit rester une couche basse.

Ses responsabilités principales sont :

* écouter ou récupérer les nouveaux blocs,
* stocker leur état dans `block_buffers`,
* extraire les outputs,
* détecter les outputs dépensés,
* bufferiser les écritures dans Redis,
* flusher vers PostgreSQL,
* suivre la progression,
* exposer un état de recovery.

Dans Bitcoin Monitor, cette logique se retrouve dans :

```text
app/services/blockchain/
```

avec des sous-parties comme :

```text
ingest/
processing/
buffers/
flushers/
orchestration/
state/
utxo/
events/
edges/
```

Ce découpage rend le système beaucoup plus lisible.

---

## 5. Le rôle de `block_buffers`

La table `block_buffers` devient le journal de progression du Layer 1.

Chaque bloc peut être dans un état :

```text
pending
enqueued
processing
processed
failed
```

Ce modèle est très important.

Il permet de savoir :

* quel bloc est arrivé,
* quel bloc attend un worker,
* quel bloc est en traitement,
* quel bloc est terminé,
* quel bloc a échoué.

Sans cette table, le système serait aveugle.

Avec elle, le recovery devient possible.

---

## 6. Redis comme zone tampon

Un autre changement important a été l’introduction de buffers Redis.

Au lieu d’écrire chaque donnée immédiatement en base :

```text
BlockProcessor
↓
PostgreSQL
```

le système peut faire :

```text
BlockProcessor
↓
Redis buffers
↓
Flusher
↓
PostgreSQL
```

Ce choix est important pour les performances.

Il permet de :

* réduire la pression sur PostgreSQL,
* écrire par batch,
* séparer parsing et persistence,
* mieux absorber les pics,
* rendre le pipeline plus résilient.

Dans une architecture de données, cette séparation est fondamentale.

---

## 7. Le rôle de l’orchestrateur

Le Layer 1 ne dépend pas uniquement d’un job isolé.

Il possède un orchestrateur.

Son rôle est de coordonner :

* backfill des blocs manquants,
* requeue des blocs bloqués,
* retry des blocs échoués,
* enqueue des blocs pending,
* état global du pipeline.

L’orchestrateur transforme le système en pipeline contrôlable.

Ce n’est plus seulement :

```text
un job qui tourne
```

mais :

```text
un système qui sait où il en est
```

Et c’est précisément ce qui permet le recovery.

---

## 8. Le bug de l’adapter supprimé

Pendant le nettoyage, une erreur intéressante est apparue.

Un fichier legacy a été supprimé :

```text
Blockchain::Buffer::BlockBuffer
```

Le système ne traitait plus les blocs.

Le dashboard montrait :

```text
pending: 16
enqueued: 1
processing: 0
process queue: 0
```

Cela voulait dire :

```text
les blocs arrivaient
mais le processing ne partait plus
```

Le diagnostic a permis de trouver rapidement le problème :

```text
l’ancien adapter était encore utilisé par le nouveau pipeline
```

Ce bug est important pédagogiquement.

Il montre qu’en phase de refactor, tout ne peut pas être supprimé immédiatement.

Parfois, il faut garder des adapters de compatibilité.

Ils permettent de faire évoluer l’architecture sans casser le système.

---

## 9. Pourquoi cette architecture est plus professionnelle

Le Layer 1 apporte plusieurs gains majeurs.

### Lisibilité

Chaque partie a un rôle clair.

```text
ingest = recevoir les blocs
processing = parser les blocs
buffers = absorber les écritures
flushers = écrire en base
orchestration = coordonner
state = observer
```

### Performance

Les écritures peuvent être batchées.

Les appels RPC sont mieux contrôlés.

Les modules ne refont pas tous le même travail.

### Recovery

Le système sait quels blocs sont :

* en attente,
* en cours,
* traités,
* échoués.

Il peut reprendre après un crash.

### Modularité

Les modules métier n’ont plus besoin de connaître tous les détails RPC.

Ils peuvent consommer les données Layer 1.

### Observabilité

Le dashboard `/system/recovery` peut montrer précisément où le pipeline bloque.

---

## 10. La règle architecturale finale

La règle à retenir est simple :

```text
Aucun module métier ne doit rescanner la blockchain
si les données existent déjà dans Layer 1.
```

Cela signifie :

```text
Cluster lit Layer 1
Exchange-like lit Layer 1
Whale lit Layer 1
Inflow / Outflow lit les données dérivées d’Exchange-like
BTC reste séparé car il vient de sources marché externes
```

Le module BTC est un cas différent.

Il ne dépend pas de Bitcoin Core.

Il récupère ses données depuis :

* Coinbase,
* Binance,
* CoinGecko,
* ou d’autres APIs marché.

Il appartient donc à une autre famille :

```text
Market Data
```

et non :

```text
Blockchain Data Engine
```

---

## 11. Le vrai changement de pensée

Ce refactor Layer 1 n’est pas seulement technique.

Il marque un changement de manière de penser.

Avant, on construisait des modules.

Après, on construit une plateforme.

Avant :

```text
je veux une feature
```

Après :

```text
je veux un pipeline fiable sur lequel plusieurs features peuvent s’appuyer
```

C’est une différence majeure.

C’est précisément ce qui transforme Bitcoin Monitor :

```text
d’une application Rails
```

en :

```text
une plateforme d’analyse blockchain
```

---

## 12. Conclusion

Le Layer 1 est devenu le socle de Bitcoin Monitor.

Il ne produit pas directement l’intelligence finale.

Mais sans lui, aucun module avancé ne peut être fiable.

Il apporte :

* une source officielle blockchain,
* une séparation claire des responsabilités,
* une meilleure performance,
* un recovery contrôlable,
* une base pour les modules futurs.

Et surtout, il impose une discipline architecturale :

> collecter d’abord proprement, analyser ensuite.

C’est l’une des décisions les plus importantes du projet.

