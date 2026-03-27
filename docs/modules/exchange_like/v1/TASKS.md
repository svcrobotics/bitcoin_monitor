
# Exchange Like — V1 — Tasks

## Objectif

Construire, stabiliser et documenter le module `exchange_like` de Bitcoin Monitor.

Le module repose sur trois briques principales :

- `ExchangeAddressBuilder`
- `ExchangeObservedScanner`
- `ExchangeTrueFlow` / exploitation aval

Les tâches sont structurées par étapes fonctionnelles.

---

# Phase 1 — Analyse et recadrage de la V1

- [x] **Tâche 1 — Analyser l’existant**
  
  Vérifier les fichiers déjà présents pour `exchange_like` :
  
  - services
  - jobs
  - tables
  - cron
  - vue système

- [x] **Tâche 2 — Identifier les dépendances legacy**
  
  Vérifier les dépendances à :
  
  - `WhaleAlert`
  - anciens noms de jobs
  - anciennes hypothèses d’architecture

- [x] **Tâche 3 — Redéfinir le périmètre V1**
  
  Décider que la V1 repose sur :
  
  - un builder blockchain
  - un scanner UTXO observé
  - une supervision propre
  - une documentation dédiée

---

# Phase 2 — Refonte du builder

- [x] **Tâche 4 — Repartir d’un builder blockchain**
  
  Décider que le builder apprend directement depuis la blockchain Bitcoin,
  et non depuis `WhaleAlert`.

- [x] **Tâche 5 — Construire l’apprentissage depuis les outputs**
  
  Le builder :
  
  - scanne les blocs
  - lit les transactions
  - apprend les adresses via les `vout`
  - ignore les `coinbase`
  - ignore les `nulldata`
  - filtre les outputs trop petits / trop gros

- [x] **Tâche 6 — Agréger les adresses candidates**
  
  Agréger pour chaque adresse :
  
  - occurrences
  - score heuristique
  - first seen
  - last seen
  - jours actifs
  - nombre de tx

- [x] **Tâche 7 — Persister dans `exchange_addresses`**
  
  Mettre à jour :
  
  - `address`
  - `occurrences`
  - `confidence`
  - `first_seen_at`
  - `last_seen_at`
  - `source`

---

# Phase 3 — Réduction du bruit

- [x] **Tâche 8 — Ajouter un filtrage avant persistance**
  
  Objectif :
  
  - éviter de remplir la table avec des adresses vues une seule fois
  - garder uniquement les signaux utiles

- [x] **Tâche 9 — Définir les seuils de conservation**
  
  Utiliser :
  
  - `MIN_OCCURRENCES_TO_KEEP`
  - `MIN_TX_COUNT_TO_KEEP`
  - `MIN_ACTIVE_DAYS_TO_KEEP`

- [x] **Tâche 10 — Vérifier les résultats en base**
  
  Contrôler :
  
  - taille de `exchange_addresses`
  - top adresses
  - cohérence des scores

---

# Phase 4 — Incrémental builder

- [x] **Tâche 11 — Ajouter un curseur builder**
  
  Réutiliser `scanner_cursors` avec :
  
  - `name = exchange_address_builder`

- [x] **Tâche 12 — Rendre le builder incrémental**
  
  Mode normal :
  
  - reprendre au dernier bloc traité
  - traiter seulement les nouveaux blocs
  - mettre à jour le curseur à la fin

- [x] **Tâche 13 — Conserver les modes manuels**
  
  Garder :
  
  - `blocks_back`
  - `days_back`
  - `reset`

  pour les besoins de backfill / rebuild volontaire

- [x] **Tâche 14 — Vérifier la reprise après exécution**
  
  Vérifier :
  
  - mise à jour de `scanner_cursors`
  - reprise au bon `blockheight`
  - run suivant très court si rien à scanner

---

# Phase 5 — Optimisation mémoire builder

- [x] **Tâche 15 — Ajouter un flush intermédiaire**
  
  Objectif :
  
  - éviter qu’un trop grand nombre d’adresses reste en mémoire
  - stabiliser les gros scans

- [x] **Tâche 16 — Définir un seuil de flush**
  
  Utiliser :
  
  - `EXCHANGE_ADDR_FLUSH_EVERY_ADDRESSES`

- [x] **Tâche 17 — Vérifier les flush dans les logs**
  
  Vérifier :
  
  - nombre de flush
  - taille des lots
  - nettoyage de `@stats`

---

# Phase 6 — Optimisation SQL builder

- [x] **Tâche 18 — Remplacer les écritures unitaires**
  
  Remplacer :
  
  - `find_or_initialize_by`
  - `save!`

  par une logique batch SQL.

- [x] **Tâche 19 — Ajouter un index unique sur `exchange_addresses.address`**
  
  Objectif :
  
  - permettre `upsert_all`
  - sécuriser l’unicité des adresses

- [x] **Tâche 20 — Vérifier l’absence de doublons**
  
  Contrôler :
  
  - aucune adresse dupliquée avant migration
  - index unique bien présent après migration

- [x] **Tâche 21 — Valider le batch SQL**
  
  Vérifier :
  
  - runs plus rapides
  - persistance correcte
  - comportement stable

---

# Phase 7 — Structuration des scopes `ExchangeAddress`

- [x] **Tâche 22 — Créer un scope `operational`**
  
  Objectif :
  
  - fournir un ensemble plus large pour l’analyse et les vues

- [x] **Tâche 23 — Créer un scope `scannable`**
  
  Objectif :
  
  - fournir un sous-ensemble plus strict pour le scanner

- [x] **Tâche 24 — Ajuster les seuils**
  
  Vérifier les tailles de set :
  
  - `ExchangeAddress.operational.count`
  - `ExchangeAddress.scannable.count`

- [x] **Tâche 25 — Valider la séparation**
  
  Résultat :
  
  - `operational` pour la vue / analyse
  - `scannable` pour le scanner temps réel

---

# Phase 8 — Refonte du scanner observé

- [x] **Tâche 26 — Vérifier le scanner existant**
  
  Lire et analyser :
  
  - `ExchangeObservedScanner`
  - `ExchangeObservedScanJob`

- [x] **Tâche 27 — Passer le scanner en incrémental**
  
  Ajouter :
  
  - curseur `exchange_observed_scan`
  - reprise au dernier bloc
  - mise à jour du curseur à la fin

- [x] **Tâche 28 — Garder les modes manuels**
  
  Conserver :
  
  - `days_back`
  - `last_n_blocks`

- [x] **Tâche 29 — Vérifier les runs incrémentaux**
  
  Contrôler :
  
  - premier run
  - deuxième run
  - comportement quand il n’y a rien à scanner

---

# Phase 9 — Optimisation de `exchange_observed_utxos`

- [x] **Tâche 30 — Vérifier les index existants**
  
  Contrôler les index sur :
  
  - `txid + vout`
  - `seen_day`
  - `spent_day`

- [x] **Tâche 31 — Ajouter les index manquants**
  
  Ajouter :
  
  - `address`
  - `spent_by_txid`
  - `address + seen_day`

- [x] **Tâche 32 — Optimiser `flush_seen!`**
  
  Vérifier que les `seen` sont bien batchés via `upsert_all`.

- [x] **Tâche 33 — Optimiser `flush_spent!`**
  
  Remplacer les updates unitaires par une logique batchée.

- [x] **Tâche 34 — Vérifier le comportement du scanner**
  
  Contrôler :
  
  - stabilité des runs
  - cohérence des écritures
  - durée des jobs

---

# Phase 10 — Branchement du scanner sur `scannable`

- [x] **Tâche 35 — Modifier la source d’adresses scannées**
  
  Faire utiliser au scanner :
  
  - `ExchangeAddress.scannable`

  avec fallback sur `operational`.

- [x] **Tâche 36 — Vérifier le `exchange_set_size`**
  
  Vérifier dans les logs que le scanner utilise bien :
  
  - le set `scannable`
  - et non le set `operational`

---

# Phase 11 — Jobs, cron et supervision

- [x] **Tâche 37 — Ajouter `ExchangeAddressBuilderJob`**
  
  Objectif :
  
  - superviser le builder via `JobRun`

- [x] **Tâche 38 — Aligner `ExchangeAddressBuilderJob` avec l’incrémental**
  
  Ne plus forcer `blocks_back: 500` par défaut.

- [x] **Tâche 39 — Aligner le script cron builder**
  
  Le cron normal doit appeler :
  
  - `ExchangeAddressBuilderJob.perform_now`
  
  sans forcer un scan manuel.

- [x] **Tâche 40 — Vérifier le script cron scanner**
  
  Confirmer que le cron scanner :
  
  - appelle bien `ExchangeObservedScanJob.perform_now`
  - reste en mode incrémental

- [x] **Tâche 41 — Vérifier `JobRun` de bout en bout**
  
  Contrôler :
  
  - builder visible
  - scanner visible
  - durées OK
  - statuts OK

- [x] **Tâche 42 — Nettoyer les vieux `running` zombies**
  
  Marquer comme `fail` les anciens `running` bloqués.

---

# Phase 12 — Supervision `/system`

- [x] **Tâche 43 — Nettoyer `SystemController`**
  
  Garder uniquement les jobs et tables réellement utiles.

- [x] **Tâche 44 — Nettoyer `app/views/system/index.html.erb`**
  
  Rendre la page lisible et orientée supervision actuelle.

- [x] **Tâche 45 — Ajouter un bloc scanners**
  
  Afficher :
  
  - dernier bloc scanné
  - best block
  - lag
  - updated_at

- [x] **Tâche 46 — Améliorer l’affichage des jobs**
  
  Mieux distinguer :
  
  - `RUNNING`
  - `STALE RUNNING`
  - `OK`
  - `FAIL`

---

# Phase 13 — Vue module

* [x] **Tâche 47 — Définir la structure de la vue `exchange_like`**

  Structure retenue pour la page module :

  * résumé du module
  * évolution du builder (graphique)
  * évolution du scanner (graphique)
  * top adresses exchange-like
  * statut moteur (builder / scanner / lag)

  Objectif : transformer la page en **vue analytique du moteur exchange-like**, pas seulement un affichage d’adresses.

---

* [x] **Tâche 48 — Implémentation de la première vue `exchange_like`**

  La vue `/exchange_like` a été mise en place.

  Elle affiche :

  **Résumé**

  * total `exchange_addresses`
  * `operational`
  * `scannable`
  * total `exchange_observed_utxos`

  **Graphiques**

  * évolution quotidienne des nouvelles adresses découvertes (`builder`)
  * évolution quotidienne de l’activité observée (`scanner`)

    * `seen`
    * `spent`

  **Top adresses**

  * top 10 `ExchangeAddress.operational`
  * triées par `occurrences`

  **Engine status**

  * builder cursor
  * scanner cursor
  * best block
  * lag scanner

  Les graphiques utilisent **Chartkick**.

---

* [x] **Tâche 49 — Ajouter le lien dashboard**

  Le lien `exchange_like` a été ajouté aux **raccourcis dashboard**.

---

# Phase 14 — Documentation module

* [x] **Tâche 50 — Structurer la documentation module**

  Structure retenue :

```text
docs/modules/exchange_like/v1/
  README.md
  TASKS.md
  DECISIONS.md
  ARCHITECTURE.md
  TESTS.md
  AMELIORATION.md
```

---

* [x] **Tâche 51 — Mettre à jour `README.md`**

  Le README a été réécrit pour refléter :

  * l’objectif du module exchange-like
  * la philosophie du builder
  * le rôle du scanner observé
  * les données produites

---

* [x] **Tâche 52 — Mettre à jour `ARCHITECTURE.md`**

  Le document décrit maintenant :

  * `ExchangeAddressBuilder`
  * `ExchangeObservedScanner`
  * curseurs `ScannerCursor`
  * tables principales
  * jobs
  * cron
  * pipeline de données

---

* [x] **Tâche 53 — Mettre à jour `DECISIONS.md`**

  Les décisions techniques majeures ont été documentées :

  * builder basé sur **outputs blockchain**
  * fonctionnement **incrémental**
  * utilisation de **curseurs**
  * flush mémoire intermédiaire
  * batch SQL
  * séparation builder / scanner

---

* [x] **Tâche 54 — Mettre à jour `TESTS.md`**

  Les tests documentés couvrent :

  * builder manuel
  * builder incrémental
  * scanner manuel
  * scanner incrémental
  * vérification curseurs
  * vérification cron

---

* [x] **Tâche 55 — Mettre à jour `AMELIORATION.md`**

  Les améliorations futures documentées incluent :

  * scoring exchange-like avancé
  * clustering d’adresses
  * indicateurs de flux exchange
  * optimisation scanner
  * exploration vers un futur module **True Flow**

---

# Fin de la V1

La V1 est considérée comme réellement terminée lorsque :

* [x] le builder blockchain fonctionne
* [x] le builder est incrémental
* [x] le builder utilise un curseur
* [x] le builder flush intermédiaire la mémoire
* [x] le builder utilise un batch SQL
* [x] `exchange_addresses` a un index unique
* [x] le scanner observé fonctionne
* [x] le scanner est incrémental
* [x] le scanner utilise un curseur
* [x] `exchange_observed_utxos` est bien indexée
* [x] le scanner utilise `scannable`
* [x] les cron sont alignés
* [x] `/system` reflète bien l’état du module
* [x] la vue `exchange_like` est stabilisée
* [X] toute la documentation du module est synchronisée
