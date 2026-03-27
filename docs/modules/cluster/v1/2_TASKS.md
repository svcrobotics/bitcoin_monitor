
# Cluster — V1 — Tasks

Ce document liste les tâches à réaliser pour démarrer le module `cluster`
dans Bitcoin Monitor.

Le scope V1 est volontairement limité :

- scan incrémental bloc par bloc
- heuristique multi-input uniquement
- création de clusters probables
- statistiques simples

---

# 1. Documentation

## 1.1 Créer l’arborescence doc
- [x] créer `docs/modules/cluster/v1/`
- [x] créer `ARCHITECTURE.md`
- [ ] créer `TASKS.md`
- [ ] créer `README.md`
- [ ] créer `TESTS.md`
- [ ] créer `DECISIONS.md`

## 1.2 Définir le périmètre V1
- [x] limiter la V1 à l’heuristique `multi_input`
- [x] exclure `change detection`
- [x] exclure AML / scam detection
- [x] exclure classification exchange / service / scam
- [x] exclure visualisation graphe avancée

---

# 2. Base de données

## 2.1 Créer les tables principales
- [ ] créer la migration `clusters`
- [ ] créer la migration `addresses`
- [ ] créer la migration `address_links`

## 2.2 Définir les colonnes minimales

### `clusters`
- [ ] `address_count`
- [ ] `total_received_sats`
- [ ] `total_sent_sats`
- [ ] `first_seen_height`
- [ ] `last_seen_height`

### `addresses`
- [ ] `address`
- [ ] `first_seen_height`
- [ ] `last_seen_height`
- [ ] `total_received_sats`
- [ ] `total_sent_sats`
- [ ] `tx_count`
- [ ] `cluster_id`

### `address_links`
- [ ] `address_a_id`
- [ ] `address_b_id`
- [ ] `link_type`
- [ ] `txid`
- [ ] `block_height`

## 2.3 Ajouter les index nécessaires
- [ ] index unique sur `addresses.address`
- [ ] index sur `addresses.cluster_id`
- [ ] index sur `address_links.address_a_id`
- [ ] index sur `address_links.address_b_id`
- [ ] index sur `address_links.txid`
- [ ] index composite sur `address_links(address_a_id, address_b_id, link_type)`

## 2.4 Contraintes / hygiène
- [ ] empêcher l’auto-lien `address_a_id == address_b_id`
- [ ] normaliser l’ordre des paires `(a, b)` pour éviter les doublons
- [ ] choisir les types entiers (`bigint`) pour les satoshis
- [ ] ajouter les foreign keys si cohérent avec le reste du projet

---

# 3. Modèles Rails

## 3.1 Créer les modèles
- [ ] créer `app/models/cluster.rb`
- [ ] créer `app/models/address.rb`
- [ ] créer `app/models/address_link.rb`

## 3.2 Définir les associations
- [ ] `Cluster has_many :addresses`
- [ ] `Address belongs_to :cluster, optional: true`
- [ ] `AddressLink belongs_to :address_a`
- [ ] `AddressLink belongs_to :address_b`

## 3.3 Ajouter validations minimales
- [ ] présence de `addresses.address`
- [ ] unicité de `addresses.address`
- [ ] présence de `address_links.link_type`
- [ ] limiter `link_type` à `multi_input` en V1

---

# 4. Scanner

## 4.1 Créer le service principal
- [ ] créer `app/services/cluster_scanner.rb`

## 4.2 Définir le comportement général
- [ ] reprendre le pattern des scanners existants
- [ ] utiliser `ScannerCursor`
- [ ] nommer le curseur `cluster_scan`
- [ ] gérer mode incrémental
- [ ] gérer mode plage manuelle (`from_height`, `to_height`)

## 4.3 Lecture blockchain
- [ ] récupérer `block_count`
- [ ] récupérer `block_hash`
- [ ] récupérer `block` avec `verbosity=2`
- [ ] parcourir toutes les transactions du bloc

## 4.4 Traitement d’une transaction
- [ ] ignorer coinbase
- [ ] extraire les inputs
- [ ] retrouver les adresses des inputs si adressables
- [ ] dédupliquer les adresses input
- [ ] continuer seulement si au moins 2 adresses distinctes

## 4.5 Création des liens
- [ ] créer les liens `multi_input`
- [ ] éviter les doublons de liens
- [ ] stocker `txid` preuve
- [ ] stocker `block_height`

## 4.6 Affectation cluster
- [ ] trouver les clusters déjà présents sur les adresses input
- [ ] si aucun cluster : créer un nouveau cluster
- [ ] si un seul cluster : rattacher les autres adresses
- [ ] si plusieurs clusters : fusionner

---

# 5. Fusion de clusters

## 5.1 Définir la stratégie V1
- [ ] cluster maître = plus petit `id`
- [ ] rattacher toutes les adresses au cluster maître
- [ ] supprimer ou marquer les clusters fusionnés
- [ ] recalculer les statistiques minimales

## 5.2 Cas à couvrir
- [ ] aucune adresse clusterisée
- [ ] une seule adresse déjà clusterisée
- [ ] plusieurs adresses déjà dans le même cluster
- [ ] plusieurs adresses dans des clusters différents

## 5.3 Sécurité logique
- [ ] rendre la fusion idempotente
- [ ] éviter les doubles rattachements
- [ ] éviter les recalculs inutiles
- [ ] protéger les opérations critiques avec transaction SQL

---

# 6. Statistiques minimales

## 6.1 Adresse
- [ ] renseigner `first_seen_height`
- [ ] renseigner `last_seen_height`
- [ ] incrémenter `tx_count`
- [ ] mettre à jour `total_sent_sats` quand l’adresse apparaît en input
- [ ] préparer la possibilité de `total_received_sats` plus tard si besoin

## 6.2 Cluster
- [ ] calculer `address_count`
- [ ] calculer `first_seen_height`
- [ ] calculer `last_seen_height`
- [ ] calculer `total_sent_sats`
- [ ] laisser `total_received_sats` minimal ou différé si V1 simplifiée

## 6.3 Politique V1
- [ ] privilégier la simplicité sur l’exhaustivité
- [ ] recalculer les stats après fusion si nécessaire
- [ ] documenter les limites si certaines stats sont partielles

---

# 7. Tâches rake

## 7.1 Créer la tâche principale
- [ ] créer `lib/tasks/cluster.rake`
- [ ] ajouter `cluster:scan`

## 7.2 Options utiles
- [ ] paramètre `FROM`
- [ ] paramètre `TO`
- [ ] paramètre `LIMIT`
- [ ] paramètre `RESET_CURSOR=1` éventuel

## 7.3 Tâches futures possibles
- [ ] `cluster:stats`
- [ ] `cluster:rebuild_stats`
- [ ] `cluster:debug_tx[txid]`

---

# 8. Logging / observabilité

## 8.1 Logs scanner
- [ ] log hauteur courante
- [ ] log nombre de transactions traitées
- [ ] log nombre de liens créés
- [ ] log nombre de clusters créés
- [ ] log nombre de fusions

## 8.2 Intégration `job_runs`
- [ ] décider si le scanner utilise `JobRun.log!`
- [ ] stocker résumé du run
- [ ] stocker erreurs utiles

## 8.3 Debug
- [ ] prévoir un mode verbose
- [ ] afficher les tx multi-input détectées
- [ ] afficher les clusters fusionnés

---

# 9. Tests

## 9.1 Tests modèles
- [ ] validations `Address`
- [ ] validations `AddressLink`
- [ ] associations `Cluster`

## 9.2 Tests service
- [ ] transaction avec 2 inputs => 1 cluster
- [ ] transaction avec 3 inputs => 1 cluster + plusieurs liens
- [ ] nouvelle tx reliant 2 clusters => fusion
- [ ] tx coinbase ignorée
- [ ] input non adressable ignoré

## 9.3 Tests d’idempotence
- [ ] rescanner le même bloc ne doit pas dupliquer les liens
- [ ] rescanner la même tx ne doit pas créer plusieurs clusters incohérents
- [ ] relancer une fusion ne doit pas casser les stats

## 9.4 Tests sur petite plage réelle
- [ ] scan de quelques blocs récents
- [ ] vérification manuelle sur une tx multi-input connue
- [ ] vérification cohérence `addresses / links / clusters`

---

# 10. Performance

## 10.1 Objectifs V1
- [ ] éviter N requêtes par adresse si possible
- [ ] utiliser des batchs simples
- [ ] limiter la mémoire par bloc
- [ ] éviter de charger des structures inutiles

## 10.2 Points à surveiller
- [ ] coût des upserts d’adresses
- [ ] coût des fusions de clusters
- [ ] coût des recalculs de stats
- [ ] coût des index sur `address_links`

## 10.3 Arbitrages V1
- [ ] préférer code lisible à micro-optimisation prématurée
- [ ] mesurer avant d’optimiser
- [ ] documenter les points chauds détectés

---

# 11. Limites connues V1

- [ ] pas de `change detection`
- [ ] pas de détection CoinJoin / PayJoin
- [ ] pas de score de confiance avancé
- [ ] pas de classification d’entité
- [ ] pas de UI dédiée au début
- [ ] pas de backfill historique complet obligatoire au démarrage

---

# 12. Livrables V1

## Technique
- [ ] migrations prêtes
- [ ] modèles prêts
- [ ] `ClusterScanner` opérationnel
- [ ] tâche `cluster:scan`
- [ ] scan sur petite plage validé

## Documentation
- [x] `ARCHITECTURE.md`
- [ ] `TASKS.md`
- [ ] `README.md`
- [ ] `TESTS.md`
- [ ] `DECISIONS.md`

---

# 13. Ordre recommandé

## Phase A — socle
- [ ] écrire les migrations
- [ ] créer les modèles
- [ ] lancer `db:migrate`

## Phase B — scanner minimal
- [ ] créer `ClusterScanner`
- [ ] scanner quelques blocs
- [ ] créer les premiers liens `multi_input`

## Phase C — clusters
- [ ] création cluster si aucun cluster existant
- [ ] rattachement au cluster existant
- [ ] fusion simple des clusters

## Phase D — stabilisation
- [ ] tests
- [ ] logs
- [ ] idempotence
- [ ] documentation finale V1

---

# 14. Définition de terminé

La V1 sera considérée comme terminée quand :

- un scan de blocs récents fonctionne
- les adresses input multi-input sont détectées
- les liens sont persistés sans doublons
- les clusters sont créés et fusionnés proprement
- le curseur permet une reprise incrémentale
- la doc V1 est à jour
