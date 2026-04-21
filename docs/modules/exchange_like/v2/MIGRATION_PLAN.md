# Exchange Like — V2 — Migration Plan

---

# Objectif

Faire évoluer le module `exchange_like` de la V1 vers la V2 sans casser
le pipeline existant, en gardant une approche incrémentale, observable
et documentée.

La migration doit préserver la production correcte de :

- `exchange_addresses`
- `exchange_observed_utxos`

---

# Principes de migration

- pas de big bang
- pas de réécriture complète d’un coup
- monitoring renforcé avant gros refacto
- comparaison V1 / V2 à chaque étape critique
- PostgreSQL reste la source de vérité
- Redis et temps réel sont hors périmètre de cette migration initiale

---

# Vue d’ensemble

## Phase 0 — Cadrage
- T1 — Geler le périmètre V1
- T2 — Finaliser la cible V2
- T3 — Analyser les écarts V1 → V2

## Phase 1 — Sécurisation
- T4 — Définir une baseline de référence
- T5 — Enrichir logs et `JobRun`
- T6 — Renforcer le monitoring `/system`

## Phase 2 — Refacto du builder
- T7 — Transformer `ExchangeAddressBuilder` en orchestrateur
- T8 — Extraire `ScanRangeResolver`
- T9 — Extraire `OutputCandidateExtractor`
- T10 — Extraire `AddressAggregator`
- T11 — Extraire `AddressFilter`
- T12 — Extraire `AddressScorer`
- T13 — Extraire `AddressUpserter`
- T14 — Extraire `CursorManager`
- T15 — Vérifier la parité V1 / V2

## Phase 3 — Refacto du scanner
- T16 — Transformer `ExchangeObservedScanner` en orchestrateur
- T17 — Extraire `ScannableAddressSet`
- T18 — Extraire `ObservedSeenBuilder`
- T19 — Extraire `ObservedSpentMarker`
- T20 — Ajouter métriques détaillées scanner

## Phase 4 — Stabilisation V2
- T21 — Formaliser les heuristiques
- T22 — Documenter l’exploitation opérationnelle
- T23 — Nettoyer le legacy
- T24 — Valider officiellement la V2

---

# Phase 0 — Cadrage

## T1 — Geler le périmètre V1

### Description
Confirmer et figer ce que fait la V1 aujourd’hui.

### À faire
- conserver la documentation V1 actuelle
- confirmer le rôle réel de `exchange_like`
- confirmer ce qui relève de `exchange_like`
- confirmer ce qui relève d’autres modules

### Pourquoi
Il faut une base stable de comparaison avant de commencer la migration.

### Livrables
- `docs/exchange_like/v1/README.md`
- `docs/exchange_like/v1/IMPROVEMENTS.md`

### Statut
- [ ] À faire

---

## T2 — Finaliser la cible V2

### Description
Formaliser la cible d’architecture du module `exchange_like`.

### À faire
- finaliser `docs/exchange_like/v2/TARGET.md`
- vérifier cohérence avec le code actuel
- confirmer les responsabilités et hors périmètre

### Pourquoi
La migration doit aller vers une cible claire et documentée.

### Livrables
- `docs/exchange_like/v2/TARGET.md`

### Statut
- [ ] À faire

---

## T3 — Analyser les écarts V1 → V2

### Description
Lister précisément les écarts entre l’implémentation actuelle et la cible.

### À faire
Créer une matrice simple :

```text
Sujet | V1 | V2 | Écart | Action
````

### Pourquoi

Permet de prioriser les tâches de migration.

### Livrables

* `docs/exchange_like/v2/MIGRATION_GAP_ANALYSIS.md`

### Statut

* [ ] À faire

---

# Phase 1 — Sécurisation

## T4 — Définir une baseline de référence

### Description

Capturer les métriques actuelles avant refacto.

### À faire

Mesurer et consigner :

* nombre total d’adresses
* nouvelles adresses détectées
* distribution des scores
* total `exchange_observed_utxos`
* lag builder
* lag scanner

### Pourquoi

Permet de vérifier qu’un refacto n’a pas dégradé les résultats.

### Livrables

* baseline V1 documentée dans la doc ou dans un fichier dédié

### Statut

* [ ] À faire

---

## T5 — Enrichir logs et `JobRun`

### Description

Rendre le builder et le scanner plus observables.

### À faire

Ajouter dans les métadonnées et logs :

* blocs scannés
* candidats détectés
* adresses retenues
* adresses rejetées
* lignes upsertées
* durée du run
* erreurs rencontrées

### Pourquoi

Un refacto sans logs précis est trop risqué.

### Livrables

* logs enrichis
* `JobRun` enrichi pour builder/scanner

### Statut

* [ ] À faire

---

## T6 — Renforcer le monitoring `/system`

### Description

Créer ou enrichir une section dédiée `Exchange Like Health`.

### À faire

Afficher :

* dernier builder run
* dernier scanner run
* lag curseur builder
* lag curseur scanner
* total adresses
* `operational`
* `scannable`
* total observed utxos
* seen today
* spent today
* erreurs récentes

### Pourquoi

Le module doit être pilotable avant transformation.

### Livrables

* section `/system` dédiée

### Statut

* [ ] À faire

---

# Phase 2 — Refacto du builder

## T7 — Transformer `ExchangeAddressBuilder` en orchestrateur

### Description

Réduire le builder à un rôle d’orchestration.

### À faire

Le builder doit seulement :

* résoudre la plage de scan
* appeler les sous-composants
* gérer le curseur
* journaliser le run

### Pourquoi

Aujourd’hui, trop de logique est concentrée dans le builder.

### Livrables

* `ExchangeAddressBuilder` allégé

### Statut

* [ ] À faire

---

## T8 — Extraire `ScanRangeResolver`

### Description

Créer une brique dédiée à la résolution de la plage de scan.

### À faire

Isoler :

* lecture du curseur
* calcul de `from_height`
* calcul de `to_height`
* reset / backfill court

### Pourquoi

La logique incrémentale est une responsabilité autonome.

### Livrables

* `ExchangeLike::ScanRangeResolver`

### Statut

* [ ] À faire

---

## T9 — Extraire `OutputCandidateExtractor`

### Description

Créer une classe dédiée à l’extraction des outputs candidats.

### À faire

Isoler :

* lecture des blocs
* parcours des transactions
* extraction des outputs
* filtres de premier niveau

  * coinbase
  * `nulldata`
  * outputs hors bornes

### Pourquoi

L’extraction brute ne doit pas être mélangée au reste du pipeline.

### Livrables

* `ExchangeLike::OutputCandidateExtractor`

### Statut

* [ ] À faire

---

## T10 — Extraire `AddressAggregator`

### Description

Créer une classe dédiée à l’agrégation en mémoire.

### À faire

Agrégats attendus :

* occurrences
* txids
* volume
* first seen
* last seen
* seen days

### Pourquoi

L’agrégation est une responsabilité distincte et testable.

### Livrables

* `ExchangeLike::AddressAggregator`

### Statut

* [ ] À faire

---

## T11 — Extraire `AddressFilter`

### Description

Créer une classe dédiée au filtrage des candidats.

### À faire

Isoler les règles :

* min occurrences
* min tx count
* min active days
* bornes volume
* exclusions supplémentaires futures

### Pourquoi

Le filtrage doit être lisible, documenté et évolutif.

### Livrables

* `ExchangeLike::AddressFilter`

### Statut

* [ ] À faire

---

## T12 — Extraire `AddressScorer`

### Description

Créer une classe dédiée au calcul du score `confidence`.

### À faire

Formaliser les signaux pris en compte :

* occurrences
* volume
* fréquence
* jours actifs
* autres signaux futurs

### Pourquoi

Le scoring doit devenir explicite et testable.

### Livrables

* `ExchangeLike::AddressScorer`

### Statut

* [ ] À faire

---

## T13 — Extraire `AddressUpserter`

### Description

Créer une classe dédiée à la persistance batch dans `exchange_addresses`.

### À faire

Isoler :

* préparation des lignes
* `upsert_all`
* journalisation associée

### Pourquoi

La persistance ne doit pas être mélangée à la logique métier.

### Livrables

* `ExchangeLike::AddressUpserter`

### Statut

* [ ] À faire

---

## T14 — Extraire `CursorManager`

### Description

Créer une interface dédiée autour des curseurs du module.

### À faire

Isoler :

* lecture
* écriture
* reset
* inspection

### Pourquoi

Les curseurs sont critiques et doivent être manipulés proprement.

### Livrables

* `ExchangeLike::CursorManager`

### Statut

* [ ] À faire

---

## T15 — Vérifier la parité V1 / V2

### Description

Comparer les résultats V1 et V2 après refacto du builder.

### À faire

Comparer sur une plage donnée :

* nombre d’adresses
* score moyen
* top adresses
* temps d’exécution
* résultats métier attendus

### Pourquoi

Le refacto doit préserver les sorties essentielles.

### Livrables

* rapport de comparaison V1 / V2

### Statut

* [ ] À faire

---

# Phase 3 — Refacto du scanner

## T16 — Transformer `ExchangeObservedScanner` en orchestrateur

### Description

Réduire le scanner à un rôle d’orchestration.

### À faire

Le scanner doit :

* résoudre la plage de scan
* charger le set scannable
* déléguer les traitements `seen` / `spent`
* journaliser le run

### Pourquoi

Même logique que pour le builder : clarifier les responsabilités.

### Livrables

* `ExchangeObservedScanner` allégé

### Statut

* [ ] À faire

---

## T17 — Extraire `ScannableAddressSet`

### Description

Créer une brique dédiée au chargement des adresses scannables.

### À faire

Rendre explicite :

* le set `operational`
* le set `scannable`
* les règles de seuil associées

### Pourquoi

Les notions métier doivent sortir de l’implicite.

### Livrables

* `ExchangeLike::ScannableAddressSet`

### Statut

* [ ] À faire

---

## T18 — Extraire `ObservedSeenBuilder`

### Description

Créer une classe dédiée aux UTXO vus.

### À faire

Construire les lignes `seen` à partir des outputs adressés au set exchange-like.

### Pourquoi

Le traitement `seen` est distinct et doit être testable isolément.

### Livrables

* `ExchangeLike::ObservedSeenBuilder`

### Statut

* [ ] À faire

---

## T19 — Extraire `ObservedSpentMarker`

### Description

Créer une classe dédiée au marquage des UTXO dépensés.

### À faire

Isoler :

* résolution des `vin`
* détection des UTXO existants
* marquage `spent`

### Pourquoi

Le traitement `spent` est une zone sensible côté performance et lisibilité.

### Livrables

* `ExchangeLike::ObservedSpentMarker`

### Statut

* [ ] À faire

---

## T20 — Ajouter métriques détaillées scanner

### Description

Améliorer la visibilité métier et technique du scanner.

### À faire

Mesurer :

* blocs scannés
* outputs vus
* UTXO seen créés
* UTXO spent marqués
* temps RPC
* temps SQL

### Pourquoi

Le scanner peut devenir coûteux et doit être supervisé finement.

### Livrables

* métriques scanner enrichies
* affichage `/system` mis à jour

### Statut

* [ ] À faire

---

# Phase 4 — Stabilisation V2

## T21 — Formaliser les heuristiques

### Description

Documenter précisément les règles métier du module.

### À faire

Documenter :

* règles de filtrage
* règles de scoring
* seuils ENV
* définition de `operational`
* définition de `scannable`

### Pourquoi

Les heuristiques doivent être explicites et transmissibles.

### Livrables

* `docs/exchange_like/v2/HEURISTICS.md`

### Statut

* [ ] À faire

---

## T22 — Documenter l’exploitation opérationnelle

### Description

Rédiger la documentation d’exploitation du module.

### À faire

Documenter :

* comment vérifier l’état du module
* comment relancer builder/scanner
* comment lire les curseurs
* que faire en cas de retard ou blocage

### Pourquoi

Le module doit être opérable en production sans improvisation.

### Livrables

* `docs/exchange_like/v2/OPERATIONS.md`

### Statut

* [ ] À faire

---

## T23 — Nettoyer le legacy

### Description

Supprimer ou clarifier les reliquats de l’ancienne logique.

### À faire

Repérer et nettoyer :

* références ambiguës à `WhaleAlert`
* anciens noms de tasks
* documentation obsolète
* confusion entre `exchange_like` et `exchange_flow`

### Pourquoi

Le vocabulaire et les frontières doivent devenir cohérents.

### Livrables

* legacy nettoyé
* doc alignée

### Statut

* [ ] À faire

---

## T24 — Valider officiellement la V2

### Description

Acter la V2 comme nouvelle architecture de référence.

### À faire

* mettre à jour la documentation
* figer la migration comme terminée
* conserver V1 comme archive

### Pourquoi

Il faut une fin claire à la migration.

### Livrables

* V2 déclarée comme référence officielle

### Statut

* [ ] À faire

---

# Priorité recommandée

## Sprint 1

* [ ] T4 — baseline
* [ ] T5 — logs / JobRun
* [ ] T6 — monitoring `/system`
* [ ] T7 — builder orchestrateur
* [ ] T8 — `ScanRangeResolver`

## Sprint 2

* [ ] T9 — `OutputCandidateExtractor`
* [ ] T10 — `AddressAggregator`
* [ ] T11 — `AddressFilter`
* [ ] T12 — `AddressScorer`

## Sprint 3

* [ ] T13 — `AddressUpserter`
* [ ] T14 — `CursorManager`
* [ ] T15 — parité V1 / V2

## Sprint 4

* [ ] T16 — scanner orchestrateur
* [ ] T17 — `ScannableAddressSet`
* [ ] T18 — `ObservedSeenBuilder`
* [ ] T19 — `ObservedSpentMarker`
* [ ] T20 — métriques scanner

## Sprint 5

* [ ] T21 — heuristiques
* [ ] T22 — opérations
* [ ] T23 — nettoyage legacy
* [ ] T24 — validation V2

---

# Hors périmètre immédiat

Les sujets suivants sont explicitement hors périmètre de cette migration initiale :

* Redis
* temps réel
* Sidekiq refacto global
* Streams
* ZMQ
* gros changement de schéma DB

Ils pourront être abordés après stabilisation de la V2.

---

# Conclusion

La migration V1 → V2 de `exchange_like` vise à transformer un pipeline déjà utile
mais concentré en un module :

* mieux découpé
* mieux documenté
* mieux supervisé
* plus simple à faire évoluer
* plus solide pour les optimisations futures