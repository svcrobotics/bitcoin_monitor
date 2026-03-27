
# Inflow / Outflow — V4 — Tasks

Ce document liste les étapes nécessaires à la mise en place de la **V4 du module inflow_outflow**.

La progression du module devient :

```
V1 = volume
V2 = structure
V3 = comportement (activity)
V4 = comportement du capital (capital behavior)
```

La V4 vise à analyser **qui contrôle réellement le volume BTC**, pas seulement qui effectue le plus d'opérations.

---

# Phase 1 — Modélisation

### [x] Tâche 1 — Créer la table `exchange_flow_day_capital_behaviors`

Cette table stocke les métriques V4 pour chaque jour.

Fichier migration :

```
db/migrate/xxxx_create_exchange_flow_day_capital_behaviors.rb
```

Colonnes :

### Clé

```
day :date
```

### Capital ratios — deposits

```
retail_deposit_capital_ratio
whale_deposit_capital_ratio
institutional_deposit_capital_ratio
```

### Capital ratios — withdrawals

```
retail_withdrawal_capital_ratio
whale_withdrawal_capital_ratio
institutional_withdrawal_capital_ratio
```

### Capital behavior scores

```
capital_dominance_score
whale_distribution_score
whale_accumulation_score
count_volume_divergence_score
capital_behavior_score
```

### Métadonnées

```
computed_at
created_at
updated_at
```

---

### [x] Tâche 2 — Ajouter index unique sur `day`

Garantir une seule ligne par jour.

```
add_index :exchange_flow_day_capital_behaviors, :day, unique: true
```

---

### [x] Tâche 3 — Créer modèle `ExchangeFlowDayCapitalBehavior`

Fichier :

```
app/models/exchange_flow_day_capital_behavior.rb
```

Responsabilité :

représenter l'analyse V4 d'une journée.

---

# Phase 2 — Builder V4

### [x] Tâche 4 — Créer `InflowOutflowCapitalBehaviorBuilder`

Fichier :

```
app/services/inflow_outflow_capital_behavior_builder.rb
```

Responsabilités :

* lire `exchange_flow_days`
* lire `exchange_flow_day_details`
* lire `exchange_flow_day_behaviors`
* calculer les ratios capital
* calculer les scores V4
* persister les résultats

---

### [x] Tâche 5 — Lire les données V1

Lire :

```
ExchangeFlowDay
```

Données nécessaires :

```
inflow_btc
outflow_btc
```

---

### [x] Tâche 6 — Lire les données V2

Lire :

```
ExchangeFlowDayDetail
```

Données nécessaires :

```
inflow_lt_1_btc
inflow_1_10_btc
inflow_10_100_btc
inflow_100_500_btc
inflow_gt_500_btc
```

et

```
outflow_lt_1_btc
outflow_1_10_btc
outflow_10_100_btc
outflow_100_500_btc
outflow_gt_500_btc
```

---

# Phase 3 — Calcul des ratios capital

### [x] Tâche 7 — Calculer `retail_deposit_capital_ratio`

```
retail =
inflow_lt_1_btc + inflow_1_10_btc
```

```
retail_deposit_capital_ratio =
retail / inflow_btc
```

---

### [x] Tâche 8 — Calculer `whale_deposit_capital_ratio`

```
whale =
inflow_10_100_btc + inflow_100_500_btc
```

```
whale_deposit_capital_ratio =
whale / inflow_btc
```

---

### [x] Tâche 9 — Calculer `institutional_deposit_capital_ratio`

```
institutional =
inflow_gt_500_btc
```

```
institutional_deposit_capital_ratio =
institutional / inflow_btc
```

---

### [x] Tâche 10 — Calculer les ratios capital côté retraits

```
retail_withdrawal_capital_ratio
whale_withdrawal_capital_ratio
institutional_withdrawal_capital_ratio
```

Même logique que pour les dépôts.

---

# Phase 4 — Scores V4

### [x] Tâche 11 — Calculer `capital_dominance_score`

Objectif :

mesurer si le capital est dominé par whales / institutions.

Exemple simple :

```
capital_dominance_score =
whale_capital_ratio + institutional_capital_ratio
```

---

### [x] Tâche 12 — Calculer `whale_distribution_score`

Mesurer si les whales déposent vers exchanges.

Heuristique simple :

```
whale_distribution_score =
whale_deposit_capital_ratio * inflow_ratio
```

---

### [x] Tâche 13 — Calculer `whale_accumulation_score`

Mesurer si les whales retirent des exchanges.

Heuristique :

```
whale_withdrawal_capital_ratio * outflow_ratio
```

---

### [x] Tâche 14 — Calculer `count_volume_divergence_score`

Comparer :

```
activity behavior (V3)
vs
capital behavior (V4)
```

Exemple :

```
abs(whale_deposit_ratio - whale_deposit_capital_ratio)
```

Objectif :

détecter divergence entre activité et capital.

---

### [x] Tâche 15 — Calculer `capital_behavior_score`

Score synthétique combinant :

* capital dominance
* divergence count / volume
* distribution / accumulation

---

# Phase 5 — Persistance

### [x] Tâche 16 — Persistance idempotente

Si la ligne existe :

```
update
```

Sinon :

```
create
```

---

### [x] Tâche 17 — Supporter calcul d’un jour précis

```
InflowOutflowCapitalBehaviorBuilder.call(day: Date.yesterday)
```

---

### [x] Tâche 18 — Supporter recalcul période

```
InflowOutflowCapitalBehaviorBuilder.call(days_back: 30)
```

---

# Phase 6 — Job

### [x] Tâche 19 — Créer job

Fichier :

```
app/jobs/inflow_outflow_capital_behavior_build_job.rb
```

Responsabilité :

```
JobRun.log!
→ InflowOutflowCapitalBehaviorBuilder
```

---

# Phase 7 — Cron

### [x] Tâche 20 — Script cron

Créer :

```
bin/cron_inflow_outflow_capital_behavior_build.sh
```

---

### [x] Tâche 21 — Ajouter cron

Fréquence :

```
toutes les heures
```

Ordre pipeline :

```
scan
→ inflow_outflow_build
→ inflow_outflow_details_build
→ inflow_outflow_behavior_build
→ inflow_outflow_capital_behavior_build
```

---

# Phase 8 — System monitoring

### [x] Tâche 22 — Ajouter job dans `/system`

```
inflow_outflow_capital_behavior_build
```

---

### [x] Tâche 23 — Ajouter table dans `/system`

```
exchange_flow_day_capital_behaviors
```

---

# Phase 9 — Vue V4

### [x] Tâche 24 — Section Capital Behavior

Afficher :

```
Retail capital ratio
Whale capital ratio
Institution capital ratio
```

---

### [x] Tâche 25 — Graphique capital

Graphique :

```
capital distribution
```

---

### [x] Tâche 26 — Divergence chart

Afficher :

```
activity vs capital
```

---

### [x] Tâche 27 — Scores capital

Afficher :

```
capital dominance
whale distribution
whale accumulation
count-volume divergence
```

---

# Phase 10 — Documentation

### [x] Tâche 28 — README V4

Décrire :

* concept capital behavior
* différence V3 vs V4

---

### [x] Tâche 29 — DECISIONS V4

Documenter :

* heuristiques capital
* buckets utilisés
* limites

---

### [x] Tâche 30 — TESTS V4

Tests :

* ratios capital
* divergence count / volume
* cohérence scores

---

### [x] Tâche 31 — AMELIORATION V4

Lister futures améliorations :

* dominance historique
* whale clusters
* top deposit share
* OTC detection

---

# Fin de la V4

La V4 sera considérée comme terminée lorsque :

```
✔ table capital behaviors existe
✔ builder V4 fonctionne
✔ ratios capital calculés
✔ scores capital calculés
✔ persistance idempotente
✔ job V4 opérationnel
✔ cron V4 en place
✔ monitoring system OK
✔ vue V4 intégrée
✔ documentation complète
