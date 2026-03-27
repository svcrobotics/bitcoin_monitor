
# Bitcoin Monitor — Cluster V3 — QA Status

## 🎯 Objectif

Ce document fournit une vue claire de l’état de validation du module Cluster V3.

Il permet de :
- suivre la couverture des tests
- identifier les zones sûres
- identifier les zones à renforcer
- garantir la cohérence produit

---

# 🟢 Légende

- ✅ Vert → testé, stable
- 🟠 Orange → partiellement testé / validé manuellement
- ⚪ Gris → non testé

---

# 1. Services (cœur du moteur)

## ClusterAggregator
Statut : ✅ Vert

Couverture :
- agrégation `total_sent_sats`
- agrégation `tx_count`
- first_seen / last_seen
- mise à jour du `cluster_profile`
- cohérence des données
- idempotence

Commande :
```bash
bundle exec rspec spec/services/cluster_aggregator_spec.rb
````

---

## ClusterMetricsBuilder

Statut : ✅ Vert

Couverture :

* cluster sans profil
* projection activité 24h / 7j
* projection volume 24h / 7j
* activity_score
* idempotence par snapshot_date

⚠️ Note :
métriques estimées (pas temps réel exact)

Commande :

```bash
bundle exec rspec spec/services/cluster_metrics_builder_spec.rb
```

---

## ClusterSignalEngine

Statut : ✅ Vert

Couverture :

* aucun signal (cas baseline)
* sudden_activity
* volume_spike
* large_transfers
* cluster_activation
* anti-bruit (faux positifs)
* idempotence (delete + recreate)

Commande :

```bash
bundle exec rspec spec/services/cluster_signal_engine_spec.rb
```

---

# 2. UI — Page adresse (produit principal)

## AddressLookup

Statut : ✅ Vert

Couverture :

* rendu OK
* affichage adresse
* classification
* score
* signaux
* synthèse

Commande :

```bash
bundle exec rspec spec/requests/address_lookup_spec.rb
```

---

## AddressLookup — Edge Cases

Statut : ✅ Vert

Couverture :

* adresse valide non observée
* adresse sans signaux
* cluster incomplet
* cohérence affichage total cluster

👉 Couvre des cas réels rencontrés en production

Commande :

```bash
bundle exec rspec spec/requests/address_lookup_edge_cases_spec.rb
```

---

# 3. UI — Signaux cluster

## ClusterSignals

Statut : ✅ Vert

Couverture :

* page `/cluster_signals`
* page `/cluster_signals/top`
* tri par score
* filtres (severity, type)
* affichage des signaux
* affichage des adresses
* ranking clusters
* limit

Commande :

```bash
bundle exec rspec spec/requests/cluster_signals_spec.rb
```

---

# 4. Scanner cluster

## ClusterScanner

Statut : 🟠 Orange

Couverture :

* validation manuelle OK
* fix du bug d’agrégation confirmé
* comportement réel observé en console

Non couvert :

* tests RSpec
* scénarios multi-input complexes
* merge clusters

👉 Priorité future si évolution du scanner

---

# 5. Monitoring / System

## /system

Statut : 🟠 Orange

Couverture :

* validation visuelle OK

Non couvert :

* request specs
* vérification automatique freshness
* SLA tests

---

# 6. Tâches & Cron V3

## Rake tasks V3

Statut : ⚪ Gris

Non implémenté :

* cluster:v3_build_metrics
* cluster:v3_detect_signals

---

## Cron V3

Statut : ⚪ Gris

Non implémenté :

* cron metrics
* cron signals

---

# 7. UI métriques V3

Statut : ⚪ Gris

Non affiché actuellement :

* tx_count_24h
* tx_count_7d
* sent_24h
* sent_7d
* activity_score

---

# 8. Résumé global

## 🟢 Vert (solide)

* ClusterAggregator
* ClusterMetricsBuilder
* ClusterSignalEngine
* AddressLookup (UI principale)
* AddressLookup edge cases
* ClusterSignals

## 🟠 Orange (validé mais non testé)

* ClusterScanner
* Monitoring `/system`

## ⚪ Gris (non implémenté)

* tâches rake V3
* cron V3
* UI metrics détaillées

---

# 9. Commande globale

Pour lancer tous les tests du module cluster :

```bash
bundle exec rspec spec/services spec/requests
```

---

# 10. Conclusion

Le module Cluster V3 est :

* stable sur son cœur logique
* validé sur les cas critiques produit
* sécurisé contre les bugs majeurs rencontrés

Il reste à :

* industrialiser (cron, rake, monitoring)
* enrichir l’UI (metrics)
* préparer V3.2 (alertes)

---

# 11. Règle d’or QA

👉 “Tout ce qui influence une décision utilisateur doit être testé.”

Actuellement :
✔️ respecté sur la page adresse
✔️ respecté sur les signaux
⚠️ à compléter sur le monitoring et pipeline automatisé
