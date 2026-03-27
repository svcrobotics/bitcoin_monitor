
# Inflow / Outflow — V2 — Tasks

Ce document liste les étapes nécessaires à la mise en place de la **V2 du module `inflow_outflow`**.

La **V1** calcule :

* inflow BTC
* outflow BTC
* netflow BTC

La **V2** enrichit l’analyse en décrivant la **structure des flux observés** :

* nombre de dépôts
* taille moyenne
* plus gros dépôt
* nombre de retraits
* taille moyenne des retraits
* plus gros retrait
* répartition par buckets de taille

En résumé :

```
V1 = volume
V2 = structure des flux
```

---

# Phase 1 — Modélisation

### [x] Tâche 1 — Créer la table `exchange_flow_day_details`

Table destinée à stocker les **statistiques journalières enrichies** de composition des flux.

Colonnes principales :

```
day
deposit_count
avg_deposit_btc
max_deposit_btc

withdrawal_count
avg_withdrawal_btc
max_withdrawal_btc
```

### Buckets inflow (volume)

```
inflow_lt_1_btc
inflow_1_10_btc
inflow_10_100_btc
inflow_100_500_btc
inflow_gt_500_btc
```

### Buckets inflow (count)

```
inflow_lt_1_count
inflow_1_10_count
inflow_10_100_count
inflow_100_500_count
inflow_gt_500_count
```

### Buckets outflow (volume)

```
outflow_lt_1_btc
outflow_1_10_btc
outflow_10_100_btc
outflow_100_500_btc
outflow_gt_500_btc
```

### Buckets outflow (count)

```
outflow_lt_1_count
outflow_1_10_count
outflow_10_100_count
outflow_100_500_count
outflow_gt_500_count
```

Timestamps :

```
computed_at
created_at
updated_at
```

---

### [x] Tâche 2 — Ajouter index unique sur `day`

Garantir **une seule ligne par jour** dans `exchange_flow_day_details`.

---

### [x] Tâche 3 — Créer le modèle `ExchangeFlowDayDetail`

Fichier :

```
app/models/exchange_flow_day_detail.rb
```

Le modèle représente **les statistiques V2 journalières**.

---

# Phase 2 — Builder V2

### [x] Tâche 4 — Créer `InflowOutflowDetailsBuilder`

Fichier :

```
app/services/inflow_outflow_details_builder.rb
```

Responsabilités :

* lire `exchange_observed_utxos`
* filtrer inflows (`seen_day`)
* filtrer outflows (`spent_day`)
* calculer statistiques journalières
* écrire dans `exchange_flow_day_details`

---

### [x] Tâche 5 — Calculer `deposit_count`

Source :

```
exchange_observed_utxos.where(seen_day: day)
```

Calcul :

```
nombre total de dépôts observés
```

---

### [x] Tâche 6 — Calculer `avg_deposit_btc`

Formule :

```
avg_deposit_btc = inflow_btc / deposit_count
```

---

### [x] Tâche 7 — Calculer `max_deposit_btc`

Formule :

```
MAX(value_btc)
```

---

### [x] Tâche 8 — Calculer les buckets inflow

Buckets :

```
< 1 BTC
1 – 10 BTC
10 – 100 BTC
100 – 500 BTC
> 500 BTC
```

Calcul attendu :

* volume BTC par bucket

---

### [x] Tâche 9 — Calculer les buckets inflow count

Pour chaque bucket :

```
nombre de dépôts
```

---

### [x] Tâche 10 — Calculer `withdrawal_count`

Source :

```
exchange_observed_utxos.where(spent_day: day)
```

Calcul :

```
nombre total de retraits observés
```

---

### [x] Tâche 11 — Calculer `avg_withdrawal_btc`

Formule :

```
avg_withdrawal_btc = outflow_btc / withdrawal_count
```

---

### [x] Tâche 12 — Calculer `max_withdrawal_btc`

Formule :

```
MAX(value_btc)
```

---

### [x] Tâche 13 — Calculer les buckets outflow

Buckets :

```
< 1 BTC
1 – 10 BTC
10 – 100 BTC
100 – 500 BTC
> 500 BTC
```

Calcul attendu :

* volume BTC par bucket
* nombre de retraits par bucket

---

### [x] Tâche 14 — Implémenter persistance idempotente

Si la ligne existe :

```
UPDATE
```

Sinon :

```
INSERT
```

---

# Phase 3 — Modes d'exécution

### [x] Tâche 15 — Supporter calcul d’un jour précis

Exemple :

```ruby
InflowOutflowDetailsBuilder.call(day: Date.yesterday)
```

---

### [x] Tâche 16 — Supporter rebuild d’une période

Exemple :

```ruby
InflowOutflowDetailsBuilder.call(days_back: 30)
```

---

### [x] Tâche 17 — Recalculer par défaut hier + aujourd’hui

Le builder recalculera automatiquement :

```
Date.yesterday
Date.current
```

Objectif :

* absorber les retards du scanner
* permettre l'affichage de la **journée en cours**

---

# Phase 4 — Job et cron

### [x] Tâche 18 — Créer `InflowOutflowDetailsBuildJob`

Fichier :

```
app/jobs/inflow_outflow_details_build_job.rb
```

Responsabilités :

* appeler `InflowOutflowDetailsBuilder`
* journaliser via `JobRun.log!`

---

### [x] Tâche 19 — Créer script cron

Script :

```
bin/cron_inflow_outflow_details_build.sh
```

Le script :

* initialise l’environnement Rails
* lance le job
* écrit dans le log cron

---

### [x] Tâche 20 — Ajouter cron

Fréquence :

```
toutes les heures
```

---

# Phase 5 — Vue module V2

### [x] Tâche 21 — Ajouter la structure V2 dans la page `inflow_outflow`

La page doit afficher :

* statistiques inflow
* statistiques outflow
* structure des flux

---

### [x] Tâche 22 — Ajouter graphique de composition inflow

Graphiques possibles :

* volume BTC par bucket
* count par bucket

---

### [x] Tâche 23 — Ajouter graphique de composition outflow

Graphiques possibles :

* volume BTC par bucket
* count par bucket

---

### [x] Tâche 24 — Ajouter tableau buckets

Afficher :

```
bucket
volume BTC
nombre de transactions
part relative
```

---

### [x] Tâche 25 — Indiquer journée en cours

Si :

```
day == Date.current
```

Afficher :

```
journée en cours
```

---

### [ ] Tâche 26 — Préparer séparation produit V1 / V2

Objectif futur :

* V1 visible
* V2 premium

sans casser l’architecture.

---

# Phase 6 — Supervision / System

### [x] Tâche 27 — Ajouter le job V2 dans `/system`

Ajouter :

```
inflow_outflow_details_build
```

dans :

```
@job_health
```

---

### [x] Tâche 28 — Ajouter la table V2 dans `/system`

Ajouter :

```
exchange_flow_day_details
```

dans :

```
@tables
```

---

# Phase 7 — Documentation

Structure :

```
docs/modules/inflow_outflow/v2/

README.md
TASKS.md
DECISIONS.md
ARCHITECTURE.md
TESTS.md
AMELIORATION.md
```

---

### [x] Tâche 29 — Écrire `DECISIONS.md`

Documenter :

* séparation V1 / V2
* table dédiée
* segmentation buckets
* recalcul jour courant

---

### [x] Tâche 30 — Écrire `TESTS.md`

Valider :

* deposit_count
* avg_deposit_btc
* max_deposit_btc
* withdrawal_count
* buckets inflow
* buckets outflow

---

### [x] Tâche 31 — Écrire `README.md`

Décrire :

* objectif V2
* structure des flux
* lecture retail / whale

---

### [x] Tâche 32 — Écrire `AMELIORATION.md`

Améliorations futures :

* médiane des dépôts
* clustering d'adresses
* score retail / whale
* détection comportements suspects

---

# Fin de la V2

La V2 est considérée comme **terminée** lorsque :

* [x] la table `exchange_flow_day_details` existe
* [x] le builder V2 fonctionne
* [x] `deposit_count` est calculé
* [x] `avg_deposit_btc` est calculé
* [x] `max_deposit_btc` est calculé
* [x] `withdrawal_count` est calculé
* [x] `avg_withdrawal_btc` est calculé
* [x] `max_withdrawal_btc` est calculé
* [x] les buckets inflow sont calculés
* [x] les buckets inflow count sont calculés
* [x] les buckets outflow sont calculés
* [x] les buckets outflow count sont calculés
* [x] la persistance est idempotente
* [x] le job V2 fonctionne
* [x] le cron V2 est en place
* [x] la vue V2 existe
* [x] `/system` reflète bien la V2
* [x] la documentation V2 est complète

