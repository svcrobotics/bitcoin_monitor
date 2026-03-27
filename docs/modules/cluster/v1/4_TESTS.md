
# Cluster — V1 — Tests

Ce document décrit la stratégie de test du module `cluster`
pour la V1.

L’objectif n’est pas de tester un moteur forensic complet,
mais de valider un socle fiable autour de :

- l’heuristique multi-input
- la création d’adresses
- la création de liens
- la création / fusion de clusters
- l’idempotence du scanner

---

# 1. Objectifs des tests

La V1 doit prouver que :

- les transactions multi-input sont détectées correctement
- les adresses sont créées proprement
- les liens `multi_input` sont persistés sans doublons
- les clusters sont créés correctement
- les clusters sont fusionnés correctement
- le rescanning ne casse pas la cohérence
- les cas non pertinents sont ignorés

---

# 2. Périmètre testé

## Inclus
- modèles `Address`, `AddressLink`, `Cluster`
- service `ClusterScanner`
- logique de fusion
- logique de déduplication
- mise à jour du curseur
- petite exécution sur plage de blocs

## Exclu en V1
- UI
- change detection
- CoinJoin classification avancée
- AML / scam detection
- performance à l’échelle full history

---

# 3. Niveaux de tests

## 3.1 Tests unitaires
But :
- valider les modèles
- valider les helpers purs
- valider les règles de fusion simples

## 3.2 Tests de service
But :
- valider `ClusterScanner`
- valider les effets en base
- valider l’idempotence

## 3.3 Tests d’intégration légère
But :
- scanner une petite plage réelle ou mockée
- vérifier la cohérence globale des données créées

---

# 4. Jeux de données de test

La V1 doit utiliser deux types de jeux de données :

## 4.1 Jeux synthétiques
Transactions construites artificiellement pour couvrir précisément :
- 2 inputs
- 3 inputs
- fusion de clusters
- cas coinbase
- inputs non adressables

Avantages :
- déterministes
- lisibles
- rapides

## 4.2 Jeux réels limités
Petite plage de blocs récents ou transactions connues.

Objectif :
- vérifier que le parsing réel Bitcoin RPC produit
  des résultats compatibles avec les hypothèses de la V1

---

# 5. Tests des modèles

---

## 5.1 `Address`

### À vérifier
- présence de `address`
- unicité de `address`
- `cluster` optionnel
- valeurs par défaut cohérentes sur les compteurs

### Cas de test
- création valide avec une adresse Bitcoin
- refus d’un doublon exact
- création sans cluster
- mise à jour de `first_seen_height` / `last_seen_height`

### Attendus
- un enregistrement unique par adresse
- pas de doublons en base
- association cluster fonctionnelle

---

## 5.2 `AddressLink`

### À vérifier
- présence de `link_type`
- présence des adresses liées
- `link_type = multi_input` en V1
- absence d’auto-lien

### Cas de test
- création d’un lien valide entre deux adresses
- refus d’un lien sans type
- refus d’un lien où `address_a == address_b`
- déduplication logique d’un même lien

### Attendus
- un lien représente une relation utile et stable
- pas de lien aberrant
- pas de duplication simple

---

## 5.3 `Cluster`

### À vérifier
- création valide
- association avec plusieurs adresses
- agrégation simple des compteurs

### Cas de test
- création cluster vide
- rattachement de plusieurs adresses
- recalcul de `address_count`

### Attendus
- le cluster représente bien un groupe d’adresses
- les associations sont cohérentes

---

# 6. Tests du scanner

---

## 6.1 Transaction simple avec 2 inputs distincts

### Données
Transaction :
- inputs : A, B
- outputs : X, Y

### Attendus
- A créée
- B créée
- un cluster créé
- A et B rattachées au même cluster
- un lien `multi_input` créé entre A et B

### Vérifications
- `Address.count == 2` pour les inputs concernés
- `Cluster.count == 1`
- `AddressLink.count == 1`

---

## 6.2 Transaction avec 3 inputs distincts

### Données
Transaction :
- inputs : A, B, C

### Attendus
- A, B, C créées
- un cluster créé
- les 3 adresses dans le même cluster
- plusieurs liens créés

### Vérifications possibles
Selon la stratégie retenue :
- soit liens complets par paires
- soit liens minimaux mais cluster unique cohérent

### Point important
Le test doit valider la cohérence finale du cluster
plus que le nombre exact de liens si l’implémentation change.

---

## 6.3 Transaction avec inputs dupliqués après normalisation

### Données
Transaction contenant plusieurs références menant à la même adresse input.

### Attendus
- l’adresse ne doit être comptée qu’une fois
- pas de faux multi-input si une seule adresse distincte reste

### Vérifications
- pas de création de cluster artificiel
- pas de lien inutile

---

## 6.4 Transaction coinbase

### Données
Transaction coinbase.

### Attendus
- ignorée par le moteur de clustering
- aucun lien créé
- aucun cluster créé à partir de cette transaction

### Vérifications
- `AddressLink.count` inchangé
- `Cluster.count` inchangé

---

## 6.5 Input non adressable ou incomplet

### Données
Transaction avec un ou plusieurs inputs sans adresse exploitable.

### Attendus
- les inputs non exploitables sont ignorés
- la transaction ne produit un cluster que si au moins 2 adresses distinctes exploitables restent

### Vérifications
- pas d’erreur levée
- comportement robuste
- pas de cluster invalide

---

# 7. Tests de fusion de clusters

---

## 7.1 Création d’un cluster puis extension

### Étape 1
Transaction 1 :
- inputs : A, B

### Étape 2
Transaction 2 :
- inputs : B, C

### Attendus
- un seul cluster final
- A, B, C dans le même cluster
- pas de second cluster inutile

---

## 7.2 Fusion de deux clusters existants

### Étape 1
Transaction 1 :
- inputs : A, B
=> cluster 1

### Étape 2
Transaction 2 :
- inputs : C, D
=> cluster 2

### Étape 3
Transaction 3 :
- inputs : B, C
=> fusion cluster 1 + cluster 2

### Attendus
- un seul cluster maître à la fin
- A, B, C, D rattachées au même cluster
- le cluster maître respecte la règle définie
- les stats sont recalculées proprement

### Vérifications
- toutes les adresses pointent vers le même `cluster_id`
- le nombre de clusters actifs correspond à la stratégie choisie

---

## 7.3 Fusion idempotente

### Données
Même scénario de fusion relancé une seconde fois.

### Attendus
- pas de duplication
- pas de corruption des stats
- pas de création d’un nouveau cluster

---

# 8. Tests d’idempotence

L’idempotence est critique.

---

## 8.1 Rescanner le même bloc

### Attendus
- pas de création de nouveaux liens identiques
- pas de duplication d’adresses
- pas de nouveaux clusters incohérents

### Vérifications
Comparer les compteurs avant / après un second passage.

---

## 8.2 Rescanner la même transaction

### Attendus
- même état final
- aucune inflation des compteurs structurels
- pas de nouveaux liens si déjà présents

---

## 8.3 Relancer une fusion déjà appliquée

### Attendus
- aucun changement destructif
- aucune duplication
- cluster final identique

---

# 9. Tests du curseur

---

## 9.1 Premier lancement sans curseur

### Attendus
- création ou initialisation correcte du curseur
- démarrage à la hauteur prévue par la tâche

---

## 9.2 Reprise après interruption

### Attendus
- le scanner reprend au bon bloc
- les blocs déjà traités ne sont pas retraités de façon destructive

---

## 9.3 Reset volontaire

### Attendus
- un reset permet de rescanner une plage choisie
- le comportement est documenté
- l’opération reste contrôlée

---

# 10. Tests de statistiques

Les stats V1 doivent rester simples.

---

## 10.1 Stats adresse

### À vérifier
- `first_seen_height`
- `last_seen_height`
- `tx_count`

### Attendus
- première apparition correctement conservée
- dernière apparition correctement mise à jour
- compteur transaction cohérent avec la stratégie retenue

---

## 10.2 Stats cluster

### À vérifier
- `address_count`
- `first_seen_height`
- `last_seen_height`

### Attendus
- `address_count` reflète le nombre d’adresses rattachées
- les bornes de hauteur sont cohérentes
- pas d’inflation après rescanning

---

# 11. Tests sur blockchain réelle

Ces tests sont limités et servent surtout de validation terrain.

---

## 11.1 Scan sur petite plage récente

### Objectif
Scanner quelques blocs récents.

### Vérifications
- le scanner tourne sans erreur
- des adresses sont créées
- certains liens sont créés
- le curseur avance

---

## 11.2 Vérification manuelle d’une transaction multi-input connue

### Objectif
Choisir une transaction connue contenant plusieurs inputs adressables.

### Vérifications
- les adresses inputs détectées en base correspondent bien au cas observé
- le cluster attendu est créé

---

## 11.3 Vérification de cohérence globale

### Contrôles
- aucune adresse orpheline incohérente
- aucun lien auto-référent
- aucun cluster avec `address_count` impossible
- pas de duplication évidente

---

# 12. Tests de robustesse

---

## 12.1 RPC indisponible

### Attendus
- erreur claire
- pas de corruption du curseur
- pas d’état partiel silencieux

---

## 12.2 Bloc invalide / données incomplètes

### Attendus
- log explicite
- passage au bloc suivant seulement si stratégie assumée
- comportement documenté

---

## 12.3 Transaction inattendue

### Attendus
- l’erreur ne doit pas casser silencieusement la cohérence globale
- la transaction problématique doit être identifiable dans les logs

---

# 13. Métriques minimales de validation V1

La V1 peut être considérée testée si :

- les cas synthétiques principaux passent
- les fusions fonctionnent
- le rescanning est idempotent
- le curseur fonctionne
- une petite plage réelle passe sans erreur bloquante

---

# 14. Ordre recommandé des tests

## Étape A — modèles
- validations `Address`
- validations `AddressLink`
- associations `Cluster`

## Étape B — logique pure
- normalisation des paires
- règles de fusion
- idempotence des liens

## Étape C — scanner
- 2 inputs
- 3 inputs
- coinbase
- input non adressable

## Étape D — fusion
- extension cluster
- fusion de 2 clusters
- relance fusion

## Étape E — intégration
- curseur
- petite plage réelle
- vérifications en base

---

# 15. Philosophie de test

La V1 cherche avant tout à garantir :

- cohérence
- lisibilité
- stabilité
- explicabilité

On privilégie :

- des cas simples et solides
- plutôt qu’un grand nombre de tests opaques

Le but est d’obtenir un socle de clustering fiable,
pas une couverture artificielle déconnectée du comportement réel.
