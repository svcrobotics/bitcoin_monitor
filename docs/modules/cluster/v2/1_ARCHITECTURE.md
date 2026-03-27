
# Bitcoin Monitor — Architecture V2 (Cluster Engine)

## 🎯 Objectif

Faire évoluer le moteur de clusters V1 vers un système d’analyse avancé permettant :

- classification des clusters
- scoring
- analyse comportementale
- détection de patterns (CoinJoin, services, automatisation)
- intégration avec les modules existants (whales, inflow/outflow)

---

# 🧱 1. Architecture globale

## Modules principaux

### 1. Cluster Engine (V1 → V2)
- Scan blockchain
- Multi-input heuristic
- Création / merge clusters
- Base actuelle

### 2. Cluster Intelligence (NEW)
- Classification des clusters
- Score
- Tags (exchange, whale, retail…)

### 3. Address Intelligence (NEW)
- Analyse d’une adresse
- Résumé enrichi
- Risk hints

### 4. Pattern Detection (NEW)
- CoinJoin detection
- Automated patterns
- Suspicious structures

### 5. Scoring Engine (NEW)
- Score global cluster
- Score adresse
- Pondération multi-facteurs

---

# 🗄️ 2. Base de données (V2)

## Tables existantes (V1)
- addresses
- address_links
- clusters

## Tables à ajouter

### cluster_profiles
Stocke les infos enrichies d’un cluster

- id
- cluster_id
- cluster_size
- total_sent_sats
- total_received_sats
- first_seen_height
- last_seen_height

- tx_count
- active_days

- classification (string)
- score (float)

- is_exchange_like (boolean)
- is_whale_cluster (boolean)

- created_at
- updated_at

---

### cluster_patterns
Détection de patterns techniques

- id
- cluster_id

- coinjoin_detected (boolean)
- repeated_structures (integer)
- automated_behavior_score (float)

- unique_inputs_ratio (float)
- avg_inputs_per_tx (float)

---

### address_profiles
Profil enrichi d’une adresse

- id
- address_id
- cluster_id

- tx_count
- total_sent_sats
- total_received_sats

- active_span (integer)
- last_seen_height

- reuse_score (float)

---

# ⚙️ 3. Pipeline de calcul

## Étape 1 — Cluster Scan (existant)
→ remplit clusters / links

## Étape 2 — Cluster Aggregation (NEW)
Service :
```

ClusterAggregator.call

```

Calcule :
- total_sent
- tx_count
- activity span

---

## Étape 3 — Pattern Detection (NEW)

```

ClusterPatternDetector.call

```

Détecte :
- CoinJoin (multi inputs + outputs symétriques)
- répétitions
- automatisation

---

## Étape 4 — Classification (NEW)

```

ClusterClassifier.call

```

Exemples :

- cluster_size > 10k → exchange-like
- tx_count élevé + activité constante → service
- petit cluster → retail

---

## Étape 5 — Scoring (NEW)

```

ClusterScorer.call

```

Score basé sur :

- taille
- activité
- patterns
- distribution

---

# 🧠 4. Logique de classification (V2)

## Types de clusters

- `exchange_like`
- `service`
- `whale`
- `retail`
- `unknown`

---

## Heuristiques simples

### Exchange-like
- cluster_size > 10,000
- tx_count élevé
- activité continue

### Whale
- total_sent élevé
- cluster moyen

### Retail
- petit cluster
- faible activité

---

# 📊 5. UI V2

## Page adresse

Ajouts :

- badge cluster type
- score
- résumé enrichi

Exemple :

```

Cluster large (exchange-like)
Score : 82/100
Activité continue observée

```

---

## Page cluster

Ajouts :

- classification
- score
- graphique activité
- distribution des montants

---

# 🔗 6. Intégration avec modules existants

## Inflow / Outflow
→ enrichir avec type de cluster

## Whale alerts
→ mapper whale → cluster

## Exchange observed
→ validation croisée

---

# 🚨 7. Cas d’usage produit

## 1. Vérification avant transfert
→ "Cette adresse appartient à un cluster exchange-like"

## 2. Analyse de marché
→ flux par type de cluster

## 3. Sécurité
→ patterns suspects

---

# ⚠️ 8. Limites connues

- heuristique multi-input imparfaite
- CoinJoin peut casser les clusters
- pas d’identité réelle garantie

---

# 🚀 9. Roadmap

## V2.1
- classification simple
- score basique

## V2.2
- pattern detection avancé
- CoinJoin detection

## V2.3
- scoring avancé
- UI enrichie

---

# 🧩 10. Philosophie

Bitcoin Monitor V2 n’est pas :

❌ un outil de surveillance intrusive  
❌ un outil de “labeling absolu”

C’est :

✅ un outil d’analyse probabiliste  
✅ un moteur de compréhension on-chain  
✅ un assistant de décision

