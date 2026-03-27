
# Exchange Like — V1 — Decisions

Ce document liste les décisions d’architecture prises pour le module `exchange_like` en version V1.

Il sert à conserver une trace claire des arbitrages réalisés pendant la construction du module.

---

# 1. Le module `exchange_like` est séparé de `true_flow`

## Décision

Le module `exchange_like` ne contient que :

- la découverte des adresses exchange-like
- l’observation de leurs UTXO

Il ne contient pas :

- le calcul des inflows / outflows agrégés
- le module `true_flow`

## Pourquoi

Le rôle du module `exchange_like` est de produire une base fiable :

- `exchange_addresses`
- `exchange_observed_utxos`

Le calcul des flux agrégés est un sujet aval, qui repose sur ces tables mais relève d’un autre module.

## Conséquence

Le pipeline V1 du module est limité à :

```text
Blockchain
↓
ExchangeAddressBuilder
↓
exchange_addresses
↓
ExchangeObservedScanner
↓
exchange_observed_utxos
````

---

# 2. Le builder apprend directement depuis la blockchain

## Décision

Le builder ne dépend plus de `WhaleAlert`.

Il apprend les adresses exchange-like directement depuis la blockchain Bitcoin.

## Pourquoi

La dépendance à `WhaleAlert` mélangeait deux sujets différents :

* la détection de transactions importantes
* la détection d’adresses exchange-like

Le module devait devenir autonome, compréhensible et stable.

## Conséquence

Le builder scanne les blocs Bitcoin via RPC et reconstruit son propre set d’adresses candidates.

---

# 3. La V1 apprend principalement depuis les outputs

## Décision

La découverte des adresses exchange-like se fait principalement à partir des `vout`.

## Pourquoi

L’apprentissage depuis les outputs est plus simple et plus robuste en V1 :

* compatible avec un environnement pruned
* pas besoin de remonter systématiquement les transactions précédentes
* les données utiles sont déjà présentes dans `getblock(..., 2)`

## Conséquence

Le builder est plus simple, plus lisible et plus stable, au prix d’une heuristique plus limitée.

---

# 4. Le builder reste heuristique et prudent

## Décision

Le builder ne cherche pas à identifier formellement un exchange précis.

## Pourquoi

La V1 n’a pas pour objectif :

* de prouver qu’une adresse est Binance, Coinbase, etc.
* de faire du clustering complet
* d’avoir une certitude absolue

Le but est de produire un set d’adresses candidates suffisamment utile pour les analyses aval.

## Conséquence

Le vocabulaire du module doit rester prudent :

* exchange-like
* adresse candidate
* score heuristique
* signal observé

---

# 5. Un filtrage fort est appliqué avant persistance

## Décision

Toutes les adresses apprises ne sont pas enregistrées dans `exchange_addresses`.

Un filtrage est appliqué avant persistance.

## Pourquoi

Sans filtrage, la table devient rapidement trop bruyante :

* trop d’adresses vues une seule fois
* trop de faux positifs faibles
* set peu exploitable

## Conséquence

La V1 utilise des seuils tels que :

* occurrences
* nombre de tx
* jours actifs

pour garder uniquement les signaux les plus intéressants.

---

# 6. Le builder est incrémental

## Décision

Le builder fonctionne en mode incrémental par défaut.

## Pourquoi

Un scan systématique d’une grande fenêtre à chaque exécution devient rapidement coûteux :

* CPU
* mémoire
* temps d’exécution

Le mode incrémental permet :

* reprise rapide
* robustesse après redémarrage
* coût constant dans le temps

## Conséquence

Le builder utilise un curseur stocké dans :

```text
scanner_cursors
name = exchange_address_builder
```

---

# 7. Les modes manuels sont conservés

## Décision

Le builder conserve des modes manuels :

* `blocks_back`
* `days_back`
* `reset`

## Pourquoi

Ils restent nécessaires pour :

* les tests
* les backfills
* les reconstructions volontaires
* les validations ponctuelles

## Conséquence

Le mode incrémental est le mode normal, mais les scans manuels restent possibles.

---

# 8. Le builder utilise un flush intermédiaire mémoire

## Décision

Les agrégats mémoire du builder sont flushés régulièrement.

## Pourquoi

Sans flush intermédiaire, un gros scan peut accumuler trop d’adresses en mémoire et dégrader fortement le processus Ruby.

## Conséquence

Le builder flush ses agrégats par paquets et vide `@stats` après persistance.

---

# 9. Le builder utilise un batch SQL

## Décision

Les écritures dans `exchange_addresses` sont faites en batch SQL.

## Pourquoi

Les écritures unitaires avec `find_or_initialize_by + save!` sont trop coûteuses à grande échelle.

## Conséquence

La persistance repose sur :

* un chargement groupé des adresses existantes
* un `upsert_all`
* un index unique sur `exchange_addresses.address`

---

# 10. Le scanner observé est incrémental

## Décision

`ExchangeObservedScanner` fonctionne aussi en mode incrémental par défaut.

## Pourquoi

Le rescanning constant d’une fenêtre glissante était trop coûteux et peu lisible.

## Conséquence

Le scanner utilise un curseur stocké dans :

```text
scanner_cursors
name = exchange_observed_scan
```

Chaque exécution reprend au dernier bloc observé.

---

# 11. Le scanner conserve aussi des modes manuels

## Décision

Le scanner conserve :

* `days_back`
* `last_n_blocks`

## Pourquoi

Ces modes restent utiles pour :

* les tests
* les relectures ponctuelles
* les comparaisons
* le diagnostic

## Conséquence

Le mode incrémental est la norme, mais le backfill manuel reste possible.

---

# 12. `exchange_observed_utxos` est la table centrale d’observation

## Décision

Le scanner produit une table dédiée `exchange_observed_utxos`.

## Pourquoi

Cette table représente un niveau de détail utile et réutilisable :

* UTXO vus
* UTXO dépensés
* date d’apparition
* date de dépense

Elle constitue une base stable pour les analyses ultérieures.

## Conséquence

Les modules aval pourront utiliser cette table sans relire la blockchain brute.

---

# 13. `exchange_observed_utxos` est fortement indexée

## Décision

La table reçoit plusieurs index importants :

* `txid + vout`
* `address`
* `address + seen_day`
* `seen_day`
* `spent_day`
* `spent_by_txid`

## Pourquoi

Cette table peut grossir rapidement. Les index sont nécessaires pour maintenir des performances correctes.

## Conséquence

Les lectures et updates principaux restent exploitables malgré la croissance du volume.

---

# 14. Les writes du scanner sont batchés

## Décision

Le scanner batch les écritures :

* `seen_rows`
* `spent_rows`

## Pourquoi

Les écritures unitaires deviennent trop coûteuses à mesure que la table grossit.

## Conséquence

Le scanner utilise des traitements batchés et `upsert_all` pour réduire la charge SQL.

---

# 15. Deux ensembles d’adresses sont distingués

## Décision

Le modèle `ExchangeAddress` expose deux scopes distincts :

* `operational`
* `scannable`

## Pourquoi

Les besoins ne sont pas les mêmes :

* la vue et l’analyse peuvent tolérer un set plus large
* le scanner temps réel doit être plus strict

## Conséquence

Le scanner utilise `scannable`, tandis que la vue peut s’appuyer sur `operational`.

---

# 16. `scannable` est plus strict que `operational`

## Décision

`scannable` utilise des seuils plus élevés.

## Pourquoi

Un set trop large augmente inutilement :

* le CPU
* les scans
* le volume observé
* le bruit

## Conséquence

Le scanner suit uniquement les adresses les plus solides du set exchange-like.

---

# 17. La supervision du module passe par `JobRun`

## Décision

Le builder et le scanner sont supervisés via `JobRun`.

## Pourquoi

Cela permet :

* suivi des exécutions
* visibilité dans `/system`
* durée
* statut
* erreurs

## Conséquence

Les scripts cron normaux doivent appeler les jobs, pas directement les services.

---

# 18. Le module doit être résilient aux redémarrages

## Décision

Le builder et le scanner doivent reprendre correctement après :

* crash
* reboot
* coupure de courant

## Pourquoi

Le module doit pouvoir fonctionner durablement sans intervention manuelle permanente.

## Conséquence

Les curseurs sont persistés et les cron reprennent le flux normal.

---

# 19. La vue `exchange_like` reste une étape distincte

## Décision

La vue du module est traitée comme un sujet à part entière.

## Pourquoi

Le moteur de données devait d’abord être stabilisé avant de figer l’interface.

## Conséquence

La V1 de la vue doit rester simple, lisible et alignée avec les données réellement produites.

---

# 20. La documentation du module est séparée du projet global

## Décision

La documentation du module est structurée sous :

```text
docs/modules/exchange_like/v1/
```

## Pourquoi

Le module a suffisamment de logique propre pour mériter une documentation indépendante :

* README
* ARCHITECTURE
* DECISIONS
* TASKS
* TESTS
* AMELIORATION

## Conséquence

La documentation globale du projet ne doit pas absorber les détails internes du module.


