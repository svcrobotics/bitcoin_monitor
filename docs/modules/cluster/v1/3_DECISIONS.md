
# Cluster — V1 — Decisions

Ce document consigne les décisions d’architecture et de périmètre prises
pour le module `cluster`.

Il sert à garder une trace claire de ce qui a été choisi,
de ce qui a été exclu en V1,
et des raisons de ces choix.

---

# D-001 — Le module cluster démarre en V1 autonome

## Décision
Le module `cluster` est développé comme un module autonome,
sans couplage fort avec les modules `whales`, `exchange_true_flow`,
`vaults` ou `market`.

## Raisons
- limiter le risque de casser l’existant
- permettre un démarrage simple et incrémental
- construire un socle réutilisable par les autres modules plus tard
- faciliter les tests et le debug

## Conséquence
Le module introduit ses propres tables et son propre scanner,
tout en réutilisant les composants transverses déjà présents
comme `BitcoinRpc` et `ScannerCursor`.

---

# D-002 — La V1 repose uniquement sur l’heuristique multi-input

## Décision
La première version du moteur de clustering utilise uniquement
la règle `multi-input`.

## Définition
Si une transaction consomme plusieurs adresses distinctes en input,
ces adresses sont considérées comme probablement contrôlées
par une même entité.

## Raisons
- heuristique simple
- heuristique robuste
- forte valeur pratique
- peu de complexité d’implémentation
- bon rapport signal / effort

## Ce qui est exclu en V1
- change detection
- CoinJoin detection spécifique
- PayJoin handling
- heuristiques comportementales complexes

## Conséquence
Les clusters V1 sont des clusters probables,
pas une attribution certaine d’entité.

---

# D-003 — Le module utilise un scanner incrémental bloc par bloc

## Décision
Le moteur cluster est implémenté sous forme de scanner incrémental
par hauteur de bloc.

## Raisons
- cohérence avec l’architecture existante
- compatibilité avec `ScannerCursor`
- simplicité opérationnelle
- reprise facile après interruption
- possibilité de backfill partiel

## Conséquence
Le service principal sera un scanner dédié,
et non un recalcul global en mémoire ou un batch opaque.

---

# D-004 — Le point d’entrée principal est `ClusterScanner`

## Décision
Le service principal du module est :

```text
app/services/cluster_scanner.rb
````

## Raisons

* cohérence avec les services scanners déjà présents
* bonne intégration avec Rails
* testabilité simple
* possibilité d’ajouter ensuite une tâche rake et un job

## Conséquence

La logique de lecture blockchain, détection de liens
et mise à jour des clusters sera centralisée dans ce service.

---

# D-005 — Le curseur utilisé est `cluster_scan`

## Décision

Le scanner stocke sa progression dans `scanner_cursors`
avec un nom dédié :

```text
cluster_scan
```

## Raisons

* réutiliser l’infrastructure existante
* permettre la reprise incrémentale
* séparer clairement ce scanner des autres modules

## Conséquence

Le module pourra être relancé sans rescanner toute la plage déjà traitée.

---

# D-006 — La V1 crée trois tables métier principales

## Décision

La V1 introduit les tables :

* `addresses`
* `address_links`
* `clusters`

## Raisons

* modèle minimal suffisant pour démarrer
* séparation claire entre nœuds, liens et groupes
* bonne lisibilité métier
* extensibilité future

## Ce qui est volontairement exclu

* table exhaustive des transactions cluster dédiée
* table détaillée de scripts
* stockage brut complet de toutes les métadonnées de transaction

## Conséquence

La base PostgreSQL conserve l’intelligence dérivée utile au module,
pas une copie exhaustive naïve de toute la blockchain.

---

# D-007 — PostgreSQL est la base principale du module

## Décision

Le module cluster utilise PostgreSQL comme base principale.

## Raisons

* base déjà utilisée par l’application
* excellente intégration Rails
* transactions SQL utiles pour les fusions
* indexation robuste
* simplicité de déploiement et de maintenance

## Alternatives non retenues en V1

* base graph spécialisée
* moteur analytique séparé
* stockage documentaire supplémentaire

## Conséquence

La logique de graphe reste dans le code Ruby,
et PostgreSQL stocke l’état consolidé.

---

# D-008 — La V1 ne cherche pas à être un moteur forensic complet

## Décision

Le module cluster V1 n’a pas vocation à fournir
une analyse forensic ou AML complète.

## Raisons

* éviter l’éparpillement
* construire d’abord le socle
* réduire le risque de fausses promesses
* garder une première version livrable rapidement

## Ce qui est explicitement hors scope

* score AML
* détection scam
* exposure analysis
* typologie d’entités
* risk engine

## Conséquence

Le module ne répond pas encore à la question :
“cette adresse est-elle malveillante ?”
Il répond uniquement :
“quelles adresses semblent liées ?”

---

# D-009 — La V1 ne fait pas de change detection

## Décision

La détection d’adresse de change est exclue de la V1.

## Raisons

* heuristique plus fragile
* plus de faux positifs
* complexité supérieure
* besoin de règles et scores supplémentaires

## Conséquence

Les clusters V1 seront moins complets,
mais plus simples et plus fiables à expliquer.

---

# D-010 — La fusion de clusters suit une stratégie simple

## Décision

Quand plusieurs clusters doivent être fusionnés,
le cluster maître est celui qui a le plus petit `id`.

## Raisons

* stratégie simple
* facile à rendre déterministe
* simple à tester
* adaptée à une V1

## Conséquence

Les fusions sont prévisibles,
et les opérations de rattachement restent compréhensibles.

---

# D-011 — Les clusters V1 sont probabilistes

## Décision

Les résultats du module sont présentés comme :

* clusters probables
* liens probables
* groupements heuristiques

et non comme des vérités absolues.

## Raisons

* certaines transactions peuvent casser les heuristiques
* existence de CoinJoin, PayJoin et cas particuliers
* nécessité d’honnêteté méthodologique

## Conséquence

La documentation et l’UI future devront employer
un vocabulaire prudent et explicite.

---

# D-012 — La V1 privilégie la simplicité de stockage

## Décision

Le module stocke surtout :

* les adresses
* les liens utiles
* les clusters
* les statistiques simples

et non l’intégralité du brut transactionnel.

## Raisons

* limiter la croissance de la base
* éviter la redondance avec le nœud Bitcoin
* mieux contrôler la volumétrie
* concentrer le stockage sur la donnée utile au cluster

## Conséquence

Le nœud reste la source brute,
la base applicative garde la donnée dérivée.

---

# D-013 — La V1 peut démarrer sans full forensic history

## Décision

Le module est conçu pour pouvoir démarrer
sur une plage récente ou un flux incrémental,
sans exiger immédiatement une reconstruction totale historique.

## Raisons

* mise en route plus rapide
* compatibilité avec un démarrage progressif
* possibilité de valider le moteur sur petite fenêtre

## Limite

Une vision historique complète et homogène exigera idéalement
un accès non pruned ou un historique déjà dérivé en base.

## Conséquence

Le module peut être validé rapidement,
même si l’historique global complet vient plus tard.

---

# D-014 — L’exécution initiale passe par une tâche rake

## Décision

Le premier mode d’exécution du module est une tâche rake manuelle.

## Raisons

* plus simple à débugger
* meilleur contrôle au démarrage
* évite d’introduire trop tôt un job automatique

## Conséquence

Le module aura une tâche de type :

```text
cluster:scan
```

Le job d’arrière-plan éventuel viendra après stabilisation.

---

# D-015 — La V1 ne prévoit pas d’interface utilisateur dédiée immédiatement

## Décision

Le module cluster démarre sans UI dédiée.

## Raisons

* priorité au socle de données
* priorité à la fiabilité du scanner
* meilleure maîtrise du périmètre

## Conséquence

La première validation se fera :

* en base
* via logs
* via console Rails
* via tâches rake

---

# D-016 — Le module cluster est une brique transverse pour le futur

## Décision

Le module cluster est pensé comme un socle transversal.

## Raisons

Il pourra servir plus tard à :

* enrichir les whales
* relier des flux exchange
* construire des entités
* améliorer les scores de risque
* mesurer la concentration du capital

## Conséquence

Même si la V1 est réduite,
sa modélisation doit rester propre et extensible.

---

# D-017 — La philosophie V1 est “simple, incrémental, explicable”

## Décision

Toute décision technique de la V1 doit privilégier :

* simplicité
* incrémentalité
* explicabilité

## Raisons

* éviter la sur-ingénierie
* réduire les bugs
* accélérer la livraison
* garder un module compréhensible

## Conséquence

En cas d’arbitrage, on préfère :

* une heuristique plus simple mais robuste
* à une heuristique plus riche mais fragile

