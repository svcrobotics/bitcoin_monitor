
# Inflow / Outflow — V3 — Tasks

Ce document liste les étapes nécessaires à la mise en place de la **V3**
du module `inflow_outflow`.

Rappel de progression :

```text
V1 = volume
V2 = structure des flux
V3 = comportement des flux
````

La V3 ajoute une couche d’analyse comportementale au-dessus des V1 et V2.

Elle vise à produire des indicateurs tels que :

* retail ratio
* whale ratio
* institutional ratio
* concentration score
* distribution score
* accumulation score
* behavior score

---

# Phase 1 — Modélisation

* [x] **Tâche 1 — Créer la table `exchange_flow_day_behaviors`**

  Table destinée à stocker les métriques comportementales journalières.

  Colonnes prévues :

  Ratios dépôts :

  * `retail_deposit_ratio`
  * `retail_deposit_volume_ratio`
  * `whale_deposit_ratio`
  * `whale_deposit_volume_ratio`
  * `institutional_deposit_ratio`
  * `institutional_deposit_volume_ratio`

  Ratios retraits :

  * `retail_withdrawal_ratio`
  * `retail_withdrawal_volume_ratio`
  * `whale_withdrawal_ratio`
  * `whale_withdrawal_volume_ratio`
  * `institutional_withdrawal_ratio`
  * `institutional_withdrawal_volume_ratio`

  Scores :

  * `deposit_concentration_score`
  * `withdrawal_concentration_score`
  * `distribution_score`
  * `accumulation_score`
  * `behavior_score`

  Timestamps :

  * `computed_at`
  * `created_at`
  * `updated_at`

---

* [x] **Tâche 2 — Ajouter index unique sur `day`**
  Garantir une seule ligne par jour dans `exchange_flow_day_behavior`.

---

* [x] **Tâche 3 — Créer le modèle `ExchangeFlowDayBehavior`**

  Fichier :

  ```text
  app/models/exchange_flow_day_behavior.rb
  ```

  Le modèle représente les scores comportementaux d’une journée.

---

# Phase 2 — Builder V3

* [x] **Tâche 4 — Créer `InflowOutflowBehaviorBuilder`**

  Fichier :

  ```text
  app/services/inflow_outflow_behavior_builder.rb
  ```

  Responsabilités :

  * lire `exchange_flow_days`
  * lire `exchange_flow_day_details`
  * calculer les ratios comportementaux
  * calculer les scores comportementaux
  * écrire dans `exchange_flow_day_behavior`

---

* [x] **Tâche 5 — Calculer `retail_deposit_ratio`**

  Heuristique initiale :

  * retail = `< 1 BTC` + `1–10 BTC`

  Calcul count :

  ```text
  (inflow_lt_1_count + inflow_1_10_count) / deposit_count
  ```

---

* [x] **Tâche 6 — Calculer `retail_deposit_volume_ratio`**

  Heuristique initiale :

  * retail = `< 1 BTC` + `1–10 BTC`

  Calcul volume :

  ```text
  (inflow_lt_1_btc + inflow_1_10_btc) / inflow_btc
  ```

---

* [x] **Tâche 7 — Calculer `whale_deposit_ratio`**

  Heuristique initiale :

  * whale = `10–100 BTC` + `100–500 BTC`

  Calcul count :

  ```text
  (inflow_10_100_count + inflow_100_500_count) / deposit_count
  ```

---

* [x] **Tâche 8 — Calculer `whale_deposit_volume_ratio`**

  Heuristique initiale :

  * whale = `10–100 BTC` + `100–500 BTC`

  Calcul volume :

  ```text
  (inflow_10_100_btc + inflow_100_500_btc) / inflow_btc
  ```

---

* [x] **Tâche 9 — Calculer `institutional_deposit_ratio`**

  Heuristique initiale :

  * institution estimée = `> 500 BTC`

  Calcul count :

  ```text
  inflow_gt_500_count / deposit_count
  ```

---

* [x] **Tâche 10 — Calculer `institutional_deposit_volume_ratio`**

  Calcul volume :

  ```text
  inflow_gt_500_btc / inflow_btc
  ```

---

* [x] **Tâche 11 — Calculer les ratios retraits retail / whale / institution**

  Même logique que pour les dépôts, mais appliquée aux buckets outflow :

  * retail withdrawal
  * whale withdrawal
  * institutional withdrawal

---

* [x] **Tâche 12 — Calculer `deposit_concentration_score`**

  Première approche V3 :

  score simple basé sur la part du volume dans :

  * `100–500 BTC`
  * `> 500 BTC`

  Objectif :

  mesurer la concentration des dépôts.

---

* [x] **Tâche 13 — Calculer `withdrawal_concentration_score`**

  Même logique côté retraits.

---

* [x] **Tâche 14 — Calculer `distribution_score`**

  Heuristique initiale fondée sur :

  * inflow élevé
  * whale/institution deposit ratio élevé
  * concentration dépôts élevée
  * outflow relativement faible

---

* [x] **Tâche 15 — Calculer `accumulation_score`**

  Heuristique initiale fondée sur :

  * outflow élevé
  * whale/institution withdrawal ratio élevé
  * concentration retraits élevée
  * inflow relativement plus faible

---

* [x] **Tâche 16 — Calculer `behavior_score`**

  Score synthétique du jour.

  But :

  résumer le comportement observé en un indicateur lisible.

---

* [x] **Tâche 17 — Implémenter persistance idempotente**

  Si la ligne du jour existe :

  * la mettre à jour

  Sinon :

  * la créer

---

# Phase 3 — Modes d’exécution

* [x] **Tâche 18 — Supporter calcul d’un jour précis**

  Exemple :

  ```ruby
  InflowOutflowBehaviorBuilder.call(day: Date.yesterday)
  ```

---

* [x] **Tâche 19 — Supporter rebuild d’une période**

  Exemple :

  ```ruby
  InflowOutflowBehaviorBuilder.call(days_back: 30)
  ```

---

* [ ] **Tâche 20 — Recalculer par défaut hier + aujourd’hui**

  En mode normal, le builder doit recalculer :

  * `Date.yesterday`
  * `Date.current`

  Objectif :

  * rester cohérent avec V1 et V2
  * afficher une journée en cours

---

# Phase 4 — Job et cron

* [x] **Tâche 21 — Créer `InflowOutflowBehaviorBuildJob`**

  Fichier :

  ```text
  app/jobs/inflow_outflow_behavior_build_job.rb
  ```

  Le job doit :

  * appeler `InflowOutflowBehaviorBuilder`
  * être enveloppé dans `JobRun.log!`

---

* [x] **Tâche 22 — Créer script cron**

  Script :

  ```text
  bin/cron_inflow_outflow_behavior_build.sh
  ```

  Le script :

  * initialise l’environnement Rails
  * lance le job
  * écrit dans le log cron

---

* [x] **Tâche 23 — Ajouter cron**

  Ordonnancement attendu :

  ```text
  exchange_observed_scan
  → inflow_outflow_build
  → inflow_outflow_details_build
  → inflow_outflow_behavior_build
  ```

---

# Phase 5 — Vue module V3

* [x] **Tâche 24 — Ajouter une section V3 dans la page `inflow_outflow`**

  Section dédiée à l’analyse comportementale.

---

* [x] **Tâche 25 — Afficher les ratios comportementaux**

  Afficher :

  * retail deposit ratio
  * whale deposit ratio
  * institutional deposit ratio
  * retail withdrawal ratio
  * whale withdrawal ratio
  * institutional withdrawal ratio

---

* [x] **Tâche 26 — Afficher les scores comportementaux**

  Afficher :

  * deposit concentration score
  * withdrawal concentration score
  * distribution score
  * accumulation score
  * behavior score

---

* [x] **Tâche 27 — Garder une présentation neutre**

  La vue ne doit pas présenter ces scores comme des certitudes.

  Approche :

  * données visibles
  * lecture prudente
  * pas de promesse de signal absolu

---

* [ ] **Tâche 28 — Préparer séparation produit V2 / V3**

  La vue doit pouvoir, plus tard, supporter :

  * V1 visible
  * V2 premium
  * V3 plus avancée

  sans casser l’architecture UI.

---

# Phase 6 — Supervision / System

* [x] **Tâche 29 — Ajouter le job V3 dans `/system`**

  Ajouter :

  ```text
  inflow_outflow_behavior_build
  ```

  dans :

  * `@job_health`

---

* [x] **Tâche 30 — Ajouter la table V3 dans `/system`**

  Ajouter :

  ```text
  exchange_flow_day_behavior
  ```

  dans :

  * `@tables`

---

# Phase 7 — Documentation

* [x] **Tâche 31 — Créer la structure doc V3**

  Structure :

```text
docs/modules/inflow_outflow/v3/
  README.md
  TASKS.md
  DECISIONS.md
  ARCHITECTURE.md
  TESTS.md
  AMELIORATION.md
```

---

* [x] **Tâche 32 — Écrire `DECISIONS.md`**

  Documenter :

  * conventions retail / whale / institution
  * heuristiques de concentration
  * règles des scores
  * neutralité d’interprétation

---

* [x] **Tâche 33 — Écrire `TESTS.md`**

  Documenter :

  * vérification des ratios
  * vérification des scores
  * validation des bornes 0..1 ou 0..100
  * cohérence face aux journées à zéro

---

* [x] **Tâche 34 — Écrire `README.md`**

  Décrire :

  * objectif V3
  * passage structure → comportement
  * lecture prudente des scores

---

* [x] **Tâche 35 — Écrire `AMELIORATION.md`**

  Lister les améliorations futures :

  * top deposits share
  * Gini / concentration avancée
  * clustering source
  * détection transferts internes
  * alertes comportementales

---

# Fin de la V3

La V3 sera considérée comme terminée lorsque :

* [x] la table `exchange_flow_day_behavior` existe
* [x] le builder V3 fonctionne
* [x] les ratios retail / whale / institution sont calculés
* [x] les scores de concentration sont calculés
* [x] `distribution_score` est calculé
* [x] `accumulation_score` est calculé
* [x] `behavior_score` est calculé
* [x] la persistance est idempotente
* [x] le job V3 fonctionne
* [x] le cron V3 est en place
* [x] la vue V3 existe
* [x] `/system` reflète bien la V3
* [ ] la documentation V3 est complète

