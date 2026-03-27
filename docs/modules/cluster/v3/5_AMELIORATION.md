
# Bitcoin Monitor — Cluster V3 — Improvements

## 1. Objectif

Ce document définit les améliorations du module Cluster à partir de l’état réel V3.1.

Objectifs :

* stabiliser la V3.1 existante
* améliorer la lisibilité produit
* préparer V3.2 (alertes) sans casser l’existant
* garantir cohérence, performance et observabilité

---

# 2. État réel actuel

## Déjà implémenté

* clusters V1 (structure)
* cluster_profiles V2 (classification, score, traits)
* cluster_metrics V3 (estimées)
* cluster_signals V3 (simples)
* page adresse enrichie
* page `/cluster_signals`
* page `/cluster_signals/top`
* recalcul cohérent via `ClusterAggregator`
* optimisation scanner (dirty clusters)
* monitoring partiel `/system`

## Non implémenté

* alertes
* corrélations whales
* corrélations exchange
* pipeline V3 industrialisé (rake + cron complet)
* tests V3

---

# 3. Priorité absolue — Stabilisation V3.1

⚠️ Aucune nouvelle feature avant stabilisation complète.

---

## I-100 — Monitoring V3

### Objectif

Rendre visible et fiable le pipeline V3.

### À faire

* ajouter JobRun pour :

  * `cluster:v3_build_metrics`
  * `cluster:v3_detect_signals`

* compléter `/system` :

  * freshness `cluster_metrics`
  * freshness `cluster_signals`

### Impact

⭐⭐⭐⭐⭐

---

## I-101 — Cron V3

### Objectif

Industrialiser V3.

### À faire

Créer :

```bash
cron_cluster_v3_build_metrics.sh
cron_cluster_v3_detect_signals.sh
```

Ajouter :

* `flock`
* logs propres
* exit codes

### Impact

⭐⭐⭐⭐⭐

---

## I-102 — UI métriques (très important)

### Objectif

Rendre V3 réellement utile.

### À faire

Afficher dans page adresse :

* tx_count_24h
* tx_count_7d
* sent_btc_24h
* sent_btc_7d
* activity_score

### Pourquoi c’est critique

👉 Aujourd’hui tu affiches les signaux
👉 Mais pas les **données qui les expliquent**

### Impact

⭐⭐⭐⭐⭐

---

## I-103 — Tests V3.1

### À faire

* tests `ClusterMetricsBuilder`
* tests `ClusterSignalEngine`
* tests UI (signaux visibles / absents)

### Impact

⭐⭐⭐⭐⭐

---

## I-104 — Invariants cluster (nouveau 🔥)

### Objectif

Garantir la cohérence data.

### À vérifier

Toujours vrai :

```ruby
cluster.addresses.sum(:total_sent_sats)
==
cluster.cluster_profile.total_sent_sats
```

### À faire

* test automatique
* log si mismatch
* fallback rebuild

### Impact

⭐⭐⭐⭐⭐

---

# 4. Améliorations V3.2 (court terme)

---

## I-200 — Cluster Alerts (priorité #1)

### Objectif

Transformer signaux → décisions utiles

### À faire

* table `cluster_alerts`
* service `ClusterAlertEngine`

### Logique

* seuils (score, volume, ratio)
* regroupement
* cooldown

### Impact

⭐⭐⭐⭐⭐

---

## I-201 — Résumé intelligent V3

### Objectif

Remplacer logique actuelle statique par algo.

### Basé sur

* classification
* metrics
* signals
* (futur) alerts

### Impact

⭐⭐⭐⭐⭐

---

## I-202 — Priorisation des signaux

### Problème actuel

Trop de signaux → bruit

### À faire

* top 3 max
* tri intelligent :

  * severity
  * score
  * type

### Impact

⭐⭐⭐⭐⭐

---

## I-203 — Réduction du bruit

### À faire

* cooldown
* déduplication
* regroupement

### Impact

⭐⭐⭐⭐⭐

---

# 5. Améliorations Data (V3.2 → V3.3)

---

## I-210 — Détection de changement de comportement

### Objectif

Passer de "volume élevé" à :

👉 "changement anormal"

### À faire

* comparer périodes
* détecter rupture

### Impact

⭐⭐⭐⭐⭐

---

## I-211 — Confidence scoring

### À faire

* score confiance :

  * classification
  * signals

### Impact

⭐⭐⭐⭐⭐

---

## I-212 — Détection automatisation

### À faire

* patterns répétitifs
* fréquence

### Impact

⭐⭐⭐⭐

---

## I-213 — Détection CoinJoin

### À faire

* patterns outputs
* distributions symétriques

### Impact

⭐⭐⭐⭐⭐

---

# 6. Cross-modules (V3.3)

---

## I-300 — Whale ↔ Cluster

### À faire

* mapping whales → clusters

### Impact

⭐⭐⭐⭐⭐

---

## I-301 — Exchange ↔ Cluster

### À faire

* enrichir inflow/outflow avec clusters

### Impact

⭐⭐⭐⭐⭐

---

## I-302 — Segmentation marché

### Objectif

Transformer cluster → vision marché

### À faire

* retail
* whale
* service

### Impact

⭐⭐⭐⭐⭐

---

# 7. UI avancée

---

## I-310 — Timeline cluster

* activité dans le temps
* volume

---

## I-311 — Mode simple / expert

* simple → synthèse
* expert → data brute

---

## I-312 — Heatmap clusters

* activité globale réseau

---

# 8. Performance

---

## I-320 — Incremental metrics (important)

### Objectif

Ne recalculer QUE :

👉 clusters dirty

### Impact

⭐⭐⭐⭐⭐

---

## I-321 — Cache signaux

* cache `cluster_signals`

### Impact

⭐⭐⭐⭐

---

# 9. Monitoring avancé

---

## I-330 — Dashboard cluster

* top clusters
* signaux
* alertes

---

## I-331 — KPI système

* nb clusters actifs
* nb signaux
* volume total

---

# 10. Produit avancé (V4)

---

## I-400 — Alertes utilisateur

---

## I-401 — API cluster intelligence

---

## I-402 — AI insights

---

## I-403 — Détection risques avancée

---

# 11. Roadmap claire

---

## V3.1 (à finaliser)

* monitoring complet
* cron V3
* UI metrics
* tests
* invariants cluster

---

## V3.2

* alerts
* résumé intelligent
* priorisation signaux

---

## V3.3

* behavior change
* cross-modules
* dashboard cluster

---

## V4

* produit utilisateur
* API
* AI

---

# 12. Règle stratégique

👉 Tant que V3.1 n’est pas :

* stable
* observable
* cohérente

❌ on ne passe pas à V3.2

---

## 💡 Mon feedback direct (important)

Tu es à un point **très solide** :

👉 Le moteur fonctionne vraiment
👉 Les signaux sont déjà utiles
👉 L’UX commence à devenir pro

La **prochaine vraie valeur** n’est PAS technique :

👉 c’est **afficher les métriques V3 dans l’UI**

C’est ça qui va transformer ton produit.

