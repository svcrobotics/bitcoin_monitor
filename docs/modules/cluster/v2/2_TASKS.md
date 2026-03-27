
# Bitcoin Monitor — Cluster V2 — Tasks

## 🎯 Objectif V2

Faire évoluer le moteur cluster V1 vers un module d’intelligence on-chain plus lisible et plus utile, avec :

- classification simple des clusters
- score basique
- enrichissement des pages adresse / cluster
- préparation à la détection de patterns plus avancés

La V2 reste progressive :
on ne cherche pas un moteur forensic complet d’un coup.

---

# 1. Documentation

## 1.1 Arborescence
- [ ] créer `docs/modules/cluster/v2/`
- [ ] créer `ARCHITECTURE.md`
- [ ] créer `TASKS.md`
- [ ] créer `README.md`
- [ ] créer `TESTS.md`
- [ ] créer `DECISIONS.md`
- [ ] créer `AMELIORATIONS.md`

## 1.2 Périmètre V2
- [ ] définir les fonctionnalités incluses en V2.1
- [ ] définir les fonctionnalités repoussées en V2.2+
- [ ] documenter les limites méthodologiques

---

# 2. Base de données

## 2.1 Table `cluster_profiles`
- [ ] créer migration `CreateClusterProfiles`
- [ ] ajouter `cluster_id`
- [ ] ajouter `cluster_size`
- [ ] ajouter `tx_count`
- [ ] ajouter `active_days`
- [ ] ajouter `total_sent_sats`
- [ ] ajouter `total_received_sats`
- [ ] ajouter `first_seen_height`
- [ ] ajouter `last_seen_height`
- [ ] ajouter `classification`
- [ ] ajouter `score`
- [ ] ajouter `is_exchange_like`
- [ ] ajouter `is_whale_cluster`

## 2.2 Table `cluster_patterns`
- [ ] créer migration `CreateClusterPatterns`
- [ ] ajouter `cluster_id`
- [ ] ajouter `coinjoin_detected`
- [ ] ajouter `repeated_structures`
- [ ] ajouter `automated_behavior_score`
- [ ] ajouter `unique_inputs_ratio`
- [ ] ajouter `avg_inputs_per_tx`

## 2.3 Table `address_profiles`
- [ ] créer migration `CreateAddressProfiles`
- [ ] ajouter `address_id`
- [ ] ajouter `cluster_id`
- [ ] ajouter `tx_count`
- [ ] ajouter `total_sent_sats`
- [ ] ajouter `total_received_sats`
- [ ] ajouter `active_span`
- [ ] ajouter `last_seen_height`
- [ ] ajouter `reuse_score`

## 2.4 Index
- [ ] index unique sur `cluster_profiles.cluster_id`
- [ ] index unique sur `cluster_patterns.cluster_id`
- [ ] index unique sur `address_profiles.address_id`
- [ ] index sur `cluster_profiles.classification`
- [ ] index sur `cluster_profiles.score`

---

# 3. Modèles Rails

## 3.1 Créer les modèles
- [ ] créer `app/models/cluster_profile.rb`
- [ ] créer `app/models/cluster_pattern.rb`
- [ ] créer `app/models/address_profile.rb`

## 3.2 Associations
- [ ] `Cluster has_one :cluster_profile`
- [ ] `Cluster has_one :cluster_pattern`
- [ ] `Address has_one :address_profile`
- [ ] `ClusterProfile belongs_to :cluster`
- [ ] `ClusterPattern belongs_to :cluster`
- [ ] `AddressProfile belongs_to :address`
- [ ] `AddressProfile belongs_to :cluster, optional: true`

## 3.3 Validations minimales
- [ ] présence `cluster_id` sur `cluster_profiles`
- [ ] présence `cluster_id` sur `cluster_patterns`
- [ ] présence `address_id` sur `address_profiles`

---

# 4. Services V2

## 4.1 Cluster Aggregator
- [ ] créer `app/services/cluster_aggregator.rb`
- [ ] calculer `cluster_size`
- [ ] calculer `tx_count`
- [ ] calculer `active_days`
- [ ] calculer `total_sent_sats`
- [ ] calculer `first_seen_height`
- [ ] calculer `last_seen_height`

## 4.2 Cluster Classifier
- [ ] créer `app/services/cluster_classifier.rb`
- [ ] définir classification simple :
  - [ ] `exchange_like`
  - [ ] `service`
  - [ ] `whale`
  - [ ] `retail`
  - [ ] `unknown`
- [ ] brancher classification sur taille / activité

## 4.3 Cluster Scorer
- [ ] créer `app/services/cluster_scorer.rb`
- [ ] définir score simple /100
- [ ] intégrer taille
- [ ] intégrer activité
- [ ] intégrer régularité minimale
- [ ] documenter la formule

## 4.4 Cluster Pattern Detector
- [ ] créer `app/services/cluster_pattern_detector.rb`
- [ ] détecter CoinJoin basique
- [ ] détecter structures répétées
- [ ] détecter comportement automatisé basique

## 4.5 Address Profiler
- [ ] créer `app/services/address_profiler.rb`
- [ ] calculer `tx_count`
- [ ] calculer `total_sent_sats`
- [ ] calculer `active_span`
- [ ] calculer `reuse_score`

---

# 5. Tâches rake

## 5.1 Cluster profiles
- [ ] créer `cluster:build_profiles`
- [ ] créer `cluster:rebuild_profiles`

## 5.2 Cluster patterns
- [ ] créer `cluster:detect_patterns`

## 5.3 Cluster scoring
- [ ] créer `cluster:score`

## 5.4 Pipeline V2 complet
- [ ] créer `cluster:v2_refresh`
- [ ] enchaîner :
  - [ ] aggregation
  - [ ] classification
  - [ ] scoring
  - [ ] patterns

---

# 6. Intégration cron

## 6.1 Script
- [ ] créer `bin/cron_cluster_v2_refresh.sh`
- [ ] charger rbenv
- [ ] lancer `bundle exec bin/rails cluster:v2_refresh`
- [ ] logger succès / échec

## 6.2 Crontab
- [ ] ajouter section `CLUSTER V2`
- [ ] choisir une fréquence cohérente
- [ ] protéger avec `flock`

## 6.3 Monitoring system
- [ ] ajouter suivi job V2 dans `SystemController`
- [ ] ajouter SLA `cluster_v2_refresh`
- [ ] afficher état dans `/system`

---

# 7. UI — Page adresse

## 7.1 Lecture rapide enrichie
- [ ] afficher classification
- [ ] afficher badge cluster type
- [ ] afficher score
- [ ] afficher résumé plus clair

## 7.2 Données enrichies
- [ ] afficher `cluster_profile`
- [ ] afficher `address_profile`
- [ ] afficher signaux simples :
  - [ ] cluster large
  - [ ] activité continue
  - [ ] activité limitée

## 7.3 Wording
- [ ] éviter “safe” / “trusted”
- [ ] préférer “compatible avec”
- [ ] préférer “aucun signal particulier détecté”
- [ ] rendre la lecture rapide plus naturelle

---

# 8. UI — Page cluster

## 8.1 Vue show enrichie
- [ ] afficher classification
- [ ] afficher score
- [ ] afficher pattern CoinJoin si détecté
- [ ] afficher indicateurs simples

## 8.2 Vue index enrichie
- [ ] ajouter colonne classification
- [ ] ajouter colonne score
- [ ] ajouter tri simple
- [ ] garder lisibilité

---

# 9. UI — Dashboard

## 9.1 Bloc address intelligence
- [ ] garder le moteur de recherche en haut
- [ ] enrichir le résultat avec badge V2

## 9.2 Module cluster
- [ ] ajouter widget résumé cluster sur dashboard
- [ ] afficher :
  - [ ] nombre de clusters
  - [ ] top classifications
  - [ ] score moyen ou simple breakdown

---

# 10. Classification simple V2.1

## 10.1 Règles initiales
- [ ] `cluster_size <= 1` → `unknown`
- [ ] `2..20` → `retail`
- [ ] `21..1000` → `service`
- [ ] `> 1000` → `exchange_like`

## 10.2 Ajustements métier
- [ ] tenir compte de `tx_count`
- [ ] tenir compte de `total_sent_sats`
- [ ] documenter les seuils retenus
- [ ] ne pas sur-promettre

---

# 11. Score simple V2.1

## 11.1 Définir formule simple
- [ ] taille cluster
- [ ] activité
- [ ] stabilité minimale
- [ ] éventuel malus si CoinJoin détecté

## 11.2 Affichage
- [ ] score /100
- [ ] score accompagné d’un texte humain
- [ ] ne pas appeler ça “risk score” si ce n’est pas encore mature

---

# 12. Pattern detection V2.2

## 12.1 CoinJoin
- [ ] repérer sorties de même valeur
- [ ] repérer symétrie inputs/outputs
- [ ] définir seuil minimal
- [ ] stocker drapeau `coinjoin_detected`

## 12.2 Automatisation
- [ ] mesurer structures répétées
- [ ] mesurer fréquence
- [ ] stocker score simple

## 12.3 Faux positifs
- [ ] documenter les limites
- [ ] rendre l’affichage prudent

---

# 13. Tests

## 13.1 Modèles
- [ ] tests `ClusterProfile`
- [ ] tests `ClusterPattern`
- [ ] tests `AddressProfile`

## 13.2 Services
- [ ] test `ClusterAggregator`
- [ ] test `ClusterClassifier`
- [ ] test `ClusterScorer`
- [ ] test `ClusterPatternDetector`
- [ ] test `AddressProfiler`

## 13.3 UI
- [ ] test page adresse enrichie
- [ ] test page cluster enrichie
- [ ] test cas sans profil
- [ ] test cas score absent
- [ ] test cas classification absente

## 13.4 Intégration
- [ ] pipeline `cluster:v2_refresh`
- [ ] cron V2
- [ ] monitoring system

---

# 14. Recette produit

## 14.1 Cas observé / gros cluster
- [ ] la lecture rapide est claire
- [ ] la classification paraît crédible
- [ ] le score est compréhensible

## 14.2 Cas observé / petit cluster
- [ ] pas de sur-interprétation
- [ ] wording prudent

## 14.3 Cas non observé
- [ ] message inchangé, clair et honnête

## 14.4 Cas invalide
- [ ] aucune régression UX

---

# 15. Définition de terminé — V2.1

La V2.1 sera considérée comme terminée si :

- [ ] `cluster_profiles` est alimentée
- [ ] `cluster_classifier` fonctionne
- [ ] `cluster_scorer` fonctionne
- [ ] la page adresse affiche classification + score
- [ ] la page cluster affiche classification + score
- [ ] le cron V2 tourne
- [ ] `/system` reflète correctement l’état
- [ ] les résultats sont compréhensibles sans doc technique

---

# 16. Hors scope immédiat

- [ ] identification réelle d’entités
- [ ] moteur AML complet
- [ ] scoring juridique / conformité
- [ ] risk engine avancé
- [ ] graph interactif complexe
- [ ] forensic complet

---

# 17. Priorités recommandées

## Priorité 1
- [ ] `cluster_profiles`
- [ ] `ClusterAggregator`
- [ ] `ClusterClassifier`
- [ ] badge + classification sur page adresse

## Priorité 2
- [ ] `ClusterScorer`
- [ ] score sur page adresse / cluster

## Priorité 3
- [ ] `cluster_patterns`
- [ ] CoinJoin basique
- [ ] score enrichi

## Priorité 4
- [ ] intégration profonde avec whales / inflow / outflow

