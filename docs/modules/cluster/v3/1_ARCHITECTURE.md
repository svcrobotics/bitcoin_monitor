
# Bitcoin Monitor — Cluster V3 — Architecture (État réel)

## 1. Objectif

La V3 étend le module cluster au-delà de :

* la **structure on-chain (V1)**
* l’**interprétation heuristique (V2)**

en introduisant une couche de :

> **métriques agrégées + signaux comportementaux détectés automatiquement**

L’objectif réel est :

* qualifier l’activité d’un cluster
* détecter des comportements atypiques
* enrichir la lecture utilisateur sans sur-interprétation

---

# 2. Positionnement réel

## V1 — Structure

Détection on-chain :

* `addresses`
* `address_links`
* `clusters`

👉 basé sur heuristique multi-input

---

## V2 — Interprétation

Profil du cluster :

* `cluster_profiles`
* classification (`retail`, `whale`, `exchange_like`, etc.)
* score (0 → 100)
* traits (`high_volume`, `large_cluster`, etc.)

👉 basé sur agrégats cluster

---

## V3 — Comportement (implémenté)

Analyse dynamique :

* `cluster_metrics`
* `cluster_signals`

👉 basé sur projection temporelle + heuristiques

---

# 3. Architecture réelle (couches)

## Couche 1 — Structure (V1)

* extraction via `ClusterScanner`
* stockage :

  * addresses
  * address_links
  * clusters

---

## Couche 2 — Profils (V2)

* `ClusterAggregator`
* `ClusterClassifier`
* `ClusterScorer`

Produit :

* `cluster_profiles`

⚠️ Important :
Le profil est **reconstruit dynamiquement** à partir des adresses du cluster.

---

## Couche 3 — Métriques & Signaux (V3)

* `ClusterMetricsBuilder`
* `ClusterSignalEngine`

Produit :

* `cluster_metrics`
* `cluster_signals`

---

# 4. Pipeline réel (IMPORTANT)

Le pipeline réel n’est plus celui de la V1/V2 initiale.

## Pipeline actuel :

```text
cluster scan
→ addresses / links / merge
→ clusters modifiés (dirty)
→ rebuild cluster_profiles (ClusterAggregator)
→ build cluster_metrics
→ detect cluster_signals
→ UI
```

## Point clé

👉 Le recalcul des profils n’est **plus implicite**

Il est maintenant :

* déclenché **après modification du cluster**
* effectué **en batch (optimisé)**

---

# 5. Cohérence des données (point critique)

Un `cluster_profile` peut devenir **obsolète** si :

* de nouvelles adresses sont ajoutées
* des clusters sont fusionnés

Solution implémentée :

* rebuild via `ClusterAggregator.call(cluster)`
* recalcul basé sur :

  * `addresses.sum(:total_sent_sats)`
  * `addresses.sum(:tx_count)`
  * bornes `first_seen / last_seen`

👉 Garantit :

```ruby
cluster.addresses.sum(:total_sent_sats)
==
cluster.cluster_profile.total_sent_sats
```

---

# 6. Tables réellement utilisées

## 6.1 `cluster_profiles`

Agrégat réel du cluster :

* cluster_size
* tx_count
* total_sent_sats
* classification
* score
* traits

👉 source de vérité V2

---

## 6.2 `cluster_metrics`

Projection temporelle estimée :

* tx_count_24h
* tx_count_7d
* sent_sats_24h
* sent_sats_7d
* activity_score

⚠️ Important :
Pas de time-series réelle → estimation basée sur durée de vie du cluster.

---

## 6.3 `cluster_signals`

Signaux comportementaux :

* signal_type
* severity
* score
* metadata (JSON)

👉 dérivés de `cluster_metrics`

---

# 7. Signaux implémentés

Actuellement :

* `volume_spike`
* `sudden_activity`
* `large_transfers`
* `cluster_activation`

Basés sur :

* ratios 24h vs 7j
* volume total
* nombre de transactions
* heuristiques simples

👉 Pas de ML, pas de corrélation externe

---

# 8. Services clés

## Core

* `ClusterScanner`
* `ClusterAggregator`
* `ClusterClassifier`
* `ClusterScorer`

## V3

* `ClusterMetricsBuilder`
* `ClusterSignalEngine`

---

# 9. UI réelle

## Page adresse

Affiche :

* synthèse interprétée (prudente)
* classification + score
* traits
* signaux récents
* cluster size / tx / volumes
* adresses liées
* preuves multi-input

## Ajouts récents importants

* gestion des incohérences :

  * cluster incomplet
  * profil obsolète
* affichage basé sur **données réelles + interprétation prudente**

---

## Pages V3

* `/cluster_signals`
* `/cluster_signals/top`

👉 accès direct aux signaux du jour

---

## Dashboard

* entrée vers les signaux cluster
* navigation vers analyse adresse

---

# 10. Monitoring réel

Implémenté :

* `/system` :

  * `cluster_metrics`
  * `cluster_signals`
  * freshness OK

Non implémenté :

* alerting automatique
* monitoring avancé V3

---

# 11. Cron réel

Présent :

* cluster scan (incremental)

Présent (via tasks) :

* build metrics
* detect signals

⚠️ Mais :

* orchestration globale encore simple
* pas de pipeline unifié V3

---

# 12. Limites actuelles

* métriques estimées (pas temps réel)
* pas de corrélation avec :

  * whales
  * exchange flow
* pas d’alerting
* pas de scoring comportemental avancé
* dépendance à la qualité du clustering V1

---

# 13. Résumé

Le module cluster V3 actuel est :

* un moteur de structure fiable (V1)
* un moteur d’interprétation cohérent (V2)
* un moteur de détection comportementale simple mais fonctionnel (V3)

Il permet déjà :

* de comprendre un cluster
* de détecter des anomalies simples
* de guider l’utilisateur avec prudence

👉 C’est une base solide pour un moteur d’analyse on-chain avancé.