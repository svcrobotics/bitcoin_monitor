
# Cluster — V1

Le module **cluster** permet de regrouper des adresses Bitcoin qui semblent
probablement contrôlées par une même entité.

Il s’appuie uniquement sur des heuristiques **on-chain** et ne dépend
d’aucune API externe.

La V1 se concentre volontairement sur un périmètre minimal afin de construire
un socle fiable pour les analyses futures.

---

# Objectif

Le module a pour but de :

- détecter des relations entre adresses Bitcoin
- construire des clusters d’adresses liées
- maintenir des statistiques simples sur ces clusters

Ces clusters pourront ensuite être utilisés pour :

- enrichir l’analyse des whales
- analyser les flux vers les exchanges
- mesurer la concentration du capital
- construire des analyses comportementales plus avancées

---

# Principe

Le module repose sur une heuristique simple appelée **multi-input heuristic**.

## Règle

Si une transaction consomme plusieurs adresses en entrée :

```

Inputs:
A
B
C

```

alors ces adresses sont **probablement contrôlées par la même entité**.

Pourquoi :

pour signer une transaction multi-input, il faut contrôler les clés privées
des UTXO consommés.

---

# Architecture

Pipeline général :

```

Bitcoin RPC
↓
ClusterScanner
↓
addresses
address_links
clusters

```

Le scanner lit les blocs Bitcoin et détecte les transactions contenant
plusieurs inputs distincts.

Ces transactions créent des **liens entre adresses** qui permettent
de construire progressivement des clusters.

---

# Composants principaux

## ClusterScanner

Service principal :

```

app/services/cluster_scanner.rb

```

Rôle :

- scanner les blocs Bitcoin
- analyser les transactions
- détecter les liens multi-input
- créer ou fusionner les clusters

---

## Address

Modèle :

```

app/models/address.rb

```

Rôle :

représente une adresse Bitcoin observée sur la blockchain.

Informations stockées :

- adresse
- première apparition
- dernière apparition
- cluster associé
- statistiques simples

---

## AddressLink

Modèle :

```

app/models/address_link.rb

```

Rôle :

représente une relation détectée entre deux adresses.

Exemple :

```

A ↔ B
type: multi_input
txid: ...

```

---

## Cluster

Modèle :

```

app/models/cluster.rb

```

Rôle :

représente un groupe d’adresses probablement contrôlées
par la même entité.

Statistiques associées :

- nombre d’adresses
- activité observée
- volume approximatif

---

# Base de données

La V1 introduit trois tables principales :

```

addresses
address_links
clusters

```

## addresses

Stocke les adresses observées.

Champs principaux :

- address
- first_seen_height
- last_seen_height
- tx_count
- cluster_id

---

## address_links

Stocke les relations entre adresses.

Champs principaux :

- address_a_id
- address_b_id
- link_type
- txid
- block_height

---

## clusters

Stocke les groupes d’adresses liées.

Champs principaux :

- address_count
- first_seen_height
- last_seen_height
- total_sent_sats
- total_received_sats

---

# Scanner incrémental

Le module fonctionne en **mode incrémental**.

Un curseur est stocké dans :

```

scanner_cursors

```

Nom du curseur :

```

cluster_scan

```

Ce curseur permet :

- de reprendre le scan après interruption
- d’éviter de rescanner les blocs déjà traités

---

# Exécution

Le module est lancé via une tâche rake.

Exemple :

```

bin/rails cluster:scan

```

Options possibles (selon implémentation) :

```

FROM=840000
TO=840100
LIMIT=100

```

---

# Résultat attendu

Après exécution :

- des adresses sont enregistrées
- des liens multi-input sont créés
- des clusters d’adresses apparaissent
- les statistiques des clusters sont mises à jour

---

# Exemple

Transaction :

```

Inputs:
A
B
C

```

Résultat :

```

Cluster #42

Addresses:
A
B
C

```

Un lien est enregistré pour chaque relation détectée.

---

# Limites de la V1

La V1 est volontairement limitée.

Elle **ne fait pas** :

- change detection
- détection CoinJoin spécifique
- attribution d’entité
- scoring AML
- détection scam

Les clusters produits sont donc :

```

clusters probables

```

et non des certitudes.

---

# Utilisations futures

Une fois stabilisé, le module pourra servir à :

- améliorer les analyses whales
- enrichir les flux exchange
- détecter des structures de capital
- construire un moteur d’analyse comportementale du marché

---

# Documentation associée

Voir aussi :

```

ARCHITECTURE.md
TASKS.md
TESTS.md
DECISIONS.md
AMELIORATIONS.md

```

---

# Philosophie

La V1 privilégie :

- simplicité
- robustesse
- incrémentalité
- explicabilité

Le but est de construire un **socle de clustering fiable**
sur lequel les modules futurs pourront s’appuyer.
