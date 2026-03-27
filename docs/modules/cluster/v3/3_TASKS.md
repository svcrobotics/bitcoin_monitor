
# Bitcoin Monitor — Cluster V3 — Tasks (Version réelle)

---

## 🎯 Objectif V3

Faire évoluer le module cluster vers :

* V1 : structure on-chain
* V2 : profils + classification
* V3 : métriques + signaux comportementaux

👉 La V3 actuelle permet déjà :

* lecture comportementale simple
* détection d’anomalies basiques
* enrichissement de la page adresse

---

# 1. Documentation

## 1.1 Arborescence

* [x] `ARCHITECTURE.md`
* [x] `TASKS.md`
* [x] `README.md`
* [x] `TESTS.md`
* [x] `DECISIONS.md`
* [x] `IMPROVEMENTS.md`

## 1.2 Alignement réel

* [x] architecture reflète le code
* [x] décisions cohérentes avec implémentation
* [ ] nettoyer mentions “à faire” encore présentes
* [ ] expliciter pipeline réel (dirty clusters déjà fait mais à vérifier partout)

---

# 2. Base de données

## 2.1 `cluster_metrics`

* [x] table existante
* [x] champs principaux présents
* [ ] index unique `(cluster_id, snapshot_date)`
* [ ] index `snapshot_date` (perfs dashboard)

## 2.2 `cluster_signals`

* [x] table existante
* [x] champs principaux présents
* [ ] index `(cluster_id, snapshot_date)`
* [ ] index `signal_type`
* [ ] index `score DESC` (top clusters)

## 2.3 Hors scope

* [ ] alerts
* [ ] whale links
* [ ] exchange links

---

# 3. Modèles

## 3.1 Existant

* [x] `ClusterMetric`
* [x] `ClusterSignal`

## 3.2 Associations

* [x] cluster → metrics
* [x] cluster → signals

## 3.3 À améliorer

* [ ] validations minimales (presence / inclusion)
* [ ] scopes utiles :

  * `.latest`
  * `.high_score`
  * `.recent`

---

# 4. Services

## 4.1 ClusterMetricsBuilder

* [x] calcul métriques
* [x] basé sur cluster_profile
* [x] persistance OK
* [ ] documenter clairement logique d’estimation
* [ ] extraire constantes (144 / 1008 / ratios)

## 4.2 ClusterSignalEngine

* [x] signaux simples OK
* [x] suppression/rebuild par date OK
* [ ] factoriser seuils
* [ ] centraliser config signaux

## 4.3 Core (V1/V2)

* [x] cluster_scanner
* [x] cluster_aggregator
* [x] cluster_classifier
* [x] cluster_scorer

## 4.4 Optimisation récente

* [x] dirty clusters tracking
* [x] rebuild batch via aggregator

👉 important : déjà en place, ne pas casser

---

# 5. Pipeline V3

## 5.1 Réel (implémenté)

* [x] scan incrémental
* [x] clusters modifiés détectés
* [x] rebuild profils batch

## 5.2 À formaliser

* [ ] tâche unique pipeline V3 :

```bash
cluster:v3_refresh
```

→ enchaîne :

* rebuild profiles (si nécessaire)
* metrics
* signals

---

# 6. Tâches rake

## 6.1 Existant (à vérifier/normaliser)

* [x] tasks metrics présentes
* [x] tasks signals présentes

## 6.2 À créer / standardiser

* [ ] `cluster:v3_build_metrics`
* [ ] `cluster:v3_detect_signals`
* [ ] `cluster:v3_refresh` (pipeline complet)

👉 IMPORTANT : uniformiser naming

---

# 7. Cron

## 7.1 Existant

* [x] scan cluster actif

## 7.2 À ajouter

* [ ] metrics (1x / jour)
* [ ] signals (1x / jour)

## 7.3 Scripts

* [ ] `cron_cluster_v3_metrics.sh`
* [ ] `cron_cluster_v3_signals.sh`

## 7.4 Sécurité

* [ ] flock
* [ ] logs propres
* [ ] exit codes

---

# 8. Monitoring `/system`

## 8.1 Déjà OK

* [x] cluster_metrics suivi
* [x] cluster_signals suivi

## 8.2 À améliorer

* [ ] ajouter SLA (ex : last < 24h)
* [ ] afficher volume (count)
* [ ] message clair si stale

---

# 9. UI — Page adresse

## 9.1 Déjà solide

* [x] synthèse intelligente
* [x] classification + score
* [x] traits
* [x] signaux récents
* [x] incohérences détectées (cluster incomplet)

## 9.2 À améliorer

* [ ] afficher métriques V3 (24h / 7j)
* [ ] afficher activity_score
* [ ] tooltip explicatif métriques

---

# 10. UI — Cluster signals

## 10.1 Déjà OK

* [x] `/cluster_signals`
* [x] `/cluster_signals/top`
* [x] affichage score + type

## 10.2 À améliorer

* [ ] pagination
* [ ] filtre par type
* [ ] filtre par severity

---

# 11. UI — Dashboard

## 11.1 Déjà OK

* [x] lien vers clusters / signals
* [x] top clusters visibles

## 11.2 À améliorer

* [ ] widget “activité cluster”
* [ ] résumé global (nb signals high aujourd’hui)

---

# 12. Signaux

## 12.1 Implémentés

* [x] sudden_activity
* [x] volume_spike
* [x] large_transfers
* [x] cluster_activation

## 12.2 À améliorer

* [ ] documenter seuils
* [ ] homogénéiser scoring
* [ ] éviter doublons de signaux

---

# 13. Tests

## 13.1 À faire (important)

* [ ] ClusterMetricsBuilder
* [ ] ClusterSignalEngine
* [ ] ClusterAggregator cohérence

## 13.2 UI

* [ ] page adresse
* [ ] signaux présents / absents

## 13.3 Invariants critiques

* [ ] profile == somme addresses
* [ ] rebuild après scan

---

# 14. Recette produit

## 14.1 Adresse

* [ ] utile avant envoi ?
* [ ] compréhensible ?

## 14.2 Cluster

* [ ] signaux lisibles ?
* [ ] pas de sur-interprétation ?

---

# 15. Définition de terminé — V3.1

## Réel actuel

* [x] metrics
* [x] signals
* [x] UI adresse enrichie
* [x] pipeline fonctionnel
* [x] cohérence cluster_profile fixée

## Manquant

* [ ] tâches rake propres
* [ ] cron V3
* [ ] métriques visibles UI
* [ ] tests essentiels

---

# 16. Priorités réelles

## 🔴 Priorité 1 — Production-ready

* [ ] tâches rake clean
* [ ] cron stable
* [ ] monitoring propre

## 🟡 Priorité 2 — Fiabilité

* [ ] tests services
* [ ] tests invariants cluster

## 🟢 Priorité 3 — UX

* [ ] métriques visibles
* [ ] dashboard enrichi

## 🔵 Priorité 4 — Futur (V3.2+)

* [ ] alertes
* [ ] corrélations
* [ ] market pressure

---

# 17. Résumé

👉 Ce que tu as aujourd’hui :

* pipeline cluster robuste
* signaux exploitables
* UI déjà utile
* cohérence des données corrigée

👉 Ce qu’il manque :

* orchestration propre (tasks + cron)
* visibilité métriques
* tests

