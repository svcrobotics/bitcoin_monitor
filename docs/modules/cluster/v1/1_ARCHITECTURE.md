
# Cluster — V1 — Architecture

Ce document décrit l’architecture interne du module `cluster`.

Le module a pour objectif :

regrouper les adresses Bitcoin qui semblent appartenir à une même entité
à partir d’heuristiques on-chain simples.

La V1 repose volontairement sur une seule heuristique principale :

- multi-input heuristic

Le module ne dépend pas d’API externes.

---

# Vue générale

Le module fonctionne comme un scanner incrémental bloc par bloc.

Pipeline :

```text
Blockchain
↓
ClusterScanner
↓
addresses
address_links
clusters
````

Le scanner lit les blocs Bitcoin via RPC, analyse les transactions
et crée des relations entre adresses lorsqu’une transaction consomme
plusieurs inputs adressables.

---

# Objectif V1

La V1 ne cherche pas à :

* détecter des scams
* attribuer un cluster à un exchange précis
* détecter le change
* faire de l’AML
* produire un graphe complet temps réel

La V1 cherche uniquement à :

* enregistrer les adresses vues
* détecter les liens multi-input
* créer des clusters probables
* maintenir des statistiques simples

---

# Heuristique V1

## Multi-input heuristic

Si une transaction consomme plusieurs adresses en input, on suppose que ces adresses
sont probablement contrôlées par la même entité.

Exemple :

```text
Inputs:
A
B
C

=> A, B, C appartiennent probablement au même cluster
```

Pourquoi :

pour signer une transaction multi-input, il faut contrôler les clés privées
des UTXO consommés.

---

# Composants

| composant      | rôle                                              |
| -------------- | ------------------------------------------------- |
| ClusterScanner | scanne les blocs et détecte les liens multi-input |
| Address        | représente une adresse Bitcoin observée           |
| AddressLink    | représente une relation entre deux adresses       |
| Cluster        | représente un groupe probable d’adresses liées    |
| ScannerCursor  | stocke la progression du scan                     |

---

# Service principal

Service :

```text
app/services/cluster_scanner.rb
```

Objectif :

scanner les blocs Bitcoin et construire progressivement les clusters.

Le service fonctionne en deux modes :

1. mode incrémental
2. mode manuel / backfill

---

# Mode incrémental

Le scanner reprend à partir d’un curseur stocké en base.

Nom du curseur :

```text
cluster_scan
```

Le curseur est stocké dans :

```text
scanner_cursors
```

Le mode incrémental permet :

* de ne traiter que les nouveaux blocs
* de reprendre après interruption
* d’intégrer le module au pipeline global

---

# Mode manuel / backfill

Le scanner peut aussi être lancé sur une plage volontaire :

* derniers N blocs
* plage de hauteurs
* future extension : jours récents

Ce mode sert surtout à :

* tester
* débugger
* recalculer une petite fenêtre

En V1, le backfill complet historique n’est pas l’objectif principal.

---

# Scan blockchain

Le scanner utilise `BitcoinRpc`.

Séquence typique :

```text
getblockcount
getblockhash
getblock
```

Le scan lit les blocs avec :

```text
verbosity = 2
```

afin d’obtenir directement les transactions et leurs `vin` / `vout`.

---

# Traitement d’une transaction

Pour chaque transaction :

1. extraire les inputs
2. retrouver les adresses des inputs
3. éliminer les cas non adressables ou incomplets
4. dédupliquer les adresses input
5. si au moins 2 adresses distinctes :

   * créer des liens `multi_input`
   * fusionner ou créer un cluster

---

# Données persistées

## Table `addresses`

Rôle :

stocker les adresses observées et leurs statistiques simples.

Colonnes principales :

| colonne             | rôle                        |
| ------------------- | --------------------------- |
| address             | adresse Bitcoin             |
| first_seen_height   | premier bloc observé        |
| last_seen_height    | dernier bloc observé        |
| total_received_sats | total reçu                  |
| total_sent_sats     | total envoyé                |
| tx_count            | nombre de transactions vues |
| cluster_id          | cluster courant             |

---

## Table `address_links`

Rôle :

stocker les relations détectées entre adresses.

Colonnes principales :

| colonne      | rôle                         |
| ------------ | ---------------------------- |
| address_a_id | première adresse             |
| address_b_id | deuxième adresse             |
| link_type    | type de lien (`multi_input`) |
| txid         | transaction preuve           |
| block_height | bloc de détection            |

La V1 ne stocke que les liens utiles au clustering.

---

## Table `clusters`

Rôle :

stocker les groupes probables d’adresses liées.

Colonnes principales :

| colonne             | rôle                         |
| ------------------- | ---------------------------- |
| address_count       | nombre d’adresses du cluster |
| total_received_sats | total reçu du cluster        |
| total_sent_sats     | total envoyé du cluster      |
| first_seen_height   | premier bloc du cluster      |
| last_seen_height    | dernier bloc du cluster      |

---

# Fusion des clusters

Lorsqu’un lien multi-input est détecté, plusieurs cas existent.

## Cas 1

Aucune adresse n’a encore de cluster :

* création d’un nouveau cluster
* rattachement des adresses au cluster

## Cas 2

Une seule adresse a déjà un cluster :

* rattachement des autres adresses à ce cluster

## Cas 3

Plusieurs adresses ont déjà des clusters différents :

* fusion des clusters
* choix d’un cluster maître
* rattachement des adresses au cluster maître
* recalcul des statistiques

---

# Stratégie V1 de fusion

La V1 adopte une stratégie simple :

* cluster maître = plus petit `id`
* mise à jour en base des adresses rattachées
* recalcul minimal des compteurs

Cette stratégie est suffisante pour une première version opérationnelle.

---

# Limites assumées

La V1 accepte plusieurs limites :

* faux positifs possibles
* faux négatifs possibles
* pas de détection CoinJoin spécifique
* pas de change detection
* pas de classification d’entité

Le module produit donc des :

* clusters probables
* et non des vérités absolues

---

# Intégration au projet Bitcoin Monitor

Le module `cluster` est une brique transverse.

Il pourra servir plus tard à :

* enrichir les whales
* améliorer les flux exchange
* construire des entités
* calculer des scores de risque
* analyser la concentration du capital

Mais en V1, il reste autonome.

---

# Tâches techniques prévues

Structure visée :

```text
app/services/cluster_scanner.rb
app/models/address.rb
app/models/address_link.rb
app/models/cluster.rb
lib/tasks/cluster.rake
docs/modules/cluster/v1/*
```

---

# Philosophie

La V1 doit rester :

* simple
* incrémentale
* compréhensible
* compatible avec l’architecture actuelle

Le but n’est pas de créer un moteur forensic complet immédiatement,
mais un socle fiable pour les futurs modules de clustering et d’analyse d’entités.

