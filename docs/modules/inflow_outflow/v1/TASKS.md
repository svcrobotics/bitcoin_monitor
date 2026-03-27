
# Inflow / Outflow — V1 — Tasks

Ce document liste les étapes nécessaires à la mise en place du module
`inflow_outflow`.

Le module transforme les événements observés sur les adresses
`exchange-like` en flux journaliers exploitables.

---

# Phase 1 — Modélisation

- [x] **Tâche 1 — Créer la table `exchange_flow_days`**

  Table destinée à stocker les agrégats journaliers de flux.

  Colonnes prévues :

  - `day`
  - `inflow_btc`
  - `outflow_btc`
  - `netflow_btc`
  - `inflow_utxo_count`
  - `outflow_utxo_count`
  - `computed_at`
  - `created_at`
  - `updated_at`

---

- [x] **Tâche 2 — Ajouter index unique sur `day`**

  Garantir une seule ligne par jour.

---

- [x] **Tâche 3 — Créer le modèle `ExchangeFlowDay`**

  Fichier :

  ```text
  app/models/exchange_flow_day.rb
````

Le modèle représente un agrégat journalier.

---

# Phase 2 — Builder

* [x] **Tâche 4 — Créer `InflowOutflowBuilder`**

  Fichier :

  ```text
  app/services/inflow_outflow_builder.rb
  ```

  Responsabilités :

  * lire `exchange_observed_utxos`
  * agréger les flux par jour
  * écrire dans `exchange_flow_days`

---

* [x] **Tâche 5 — Calculer les inflows**

  Source :

  ```text
  exchange_observed_utxos.seen_day
  ```

  Calcul :

  * somme `value_btc`
  * nombre de lignes

---

* [x] **Tâche 6 — Calculer les outflows**

  Source :

  ```text
  exchange_observed_utxos.spent_day
  ```

  Calcul :

  * somme `value_btc`
  * nombre de lignes

---

* [x] **Tâche 7 — Calculer le netflow**

  Formule :

  ```text
  netflow = inflow_btc - outflow_btc
  ```

---

* [x] **Tâche 8 — Implémenter persistance idempotente**

  Si la ligne du jour existe :

  * la mettre à jour

  Sinon :

  * la créer

---

# Phase 3 — Modes d'exécution

* [x] **Tâche 9 — Supporter calcul d’un jour précis**

  Exemple :

  ```ruby
  InflowOutflowBuilder.call(day: Date.yesterday)
  ```

---

* [x] **Tâche 10 — Supporter rebuild d’une période**

  Exemple :

  ```ruby
  InflowOutflowBuilder.call(days_back: 30)
  ```

---

# Phase 4 — Job et cron

* [x] **Tâche 11 — Créer `InflowOutflowBuildJob`**

  Fichier :

  ```text
  app/jobs/inflow_outflow_build_job.rb
  ```

  Le job doit :

  * appeler `InflowOutflowBuilder`
  * être enveloppé dans `JobRun.log!`

---

* [x] **Tâche 12 — Créer script cron**

  Script :

  ```text
  bin/cron_inflow_outflow_build.sh
  ```

  Le script :

  * initialise l’environnement Rails
  * lance le job
  * écrit dans le log cron

---

* [x] **Tâche 13 — Ajouter cron**

  Fréquence suggérée :

  ```text
  toutes les heures
  ```

  ou

  ```text
  une fois par jour
  ```

---

# Phase 5 — Vue module

* [x] **Tâche 14 — Créer vue `inflow_outflow`**

  Page dédiée affichant :

  * inflow journalier
  * outflow journalier
  * netflow

---

* [x] **Tâche 15 — Ajouter graphiques**

  Graphiques proposés :

  * inflow BTC
  * outflow BTC
  * netflow

  Bibliothèque :

  ```text
  Chartkick
  ```

---

* [x] **Tâche 16 — Ajouter indicateurs rapides**

  Exemples :

  * inflow 24h
  * outflow 24h
  * netflow 24h

---

* [x] **Tâche 17 — Ajouter lien dashboard**

  Ajouter `inflow_outflow` dans les raccourcis du dashboard.

---

# Phase 6 — Documentation

* [x] **Tâche 18 — Créer documentation module**

  Structure :

```text
docs/modules/inflow_outflow/v1/
  README.md
  TASKS.md
  DECISIONS.md
  ARCHITECTURE.md
  TESTS.md
  AMELIORATION.md
```

---

* [x] **Tâche 19 — Écrire `ARCHITECTURE.md`**

  Décrire :

  * pipeline
  * builder
  * table `exchange_flow_days`

---

* [x] **Tâche 20 — Écrire `DECISIONS.md`**

  Documenter :

  * agrégation journalière
  * dépendance à `exchange_like`
  * absence de scan blockchain direct

---

* [x] **Tâche 21 — Écrire `TESTS.md`**

  Documenter :

  * rebuild historique
  * calcul d’un jour
  * validation des chiffres

---

* [x] **Tâche 22 — Écrire `AMELIORATION.md`**

  Lister les améliorations futures.

---

# Fin de la V1

La V1 sera considérée comme terminée lorsque :

* [x] la table `exchange_flow_days` existe
* [x] le builder fonctionne
* [x] les inflows sont calculés
* [x] les outflows sont calculés
* [x] le netflow est calculé
* [x] la persistance est idempotente
* [x] le job fonctionne
* [x] le cron est en place
* [x] la vue inflow/outflow existe
* [x] la documentation du module est complète

