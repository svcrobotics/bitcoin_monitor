

# Inflow / Outflow — V3 — Tests

Ce document décrit les tests permettant de valider le fonctionnement de la **V3 du module `inflow_outflow`**.

La V3 introduit une **analyse comportementale** basée sur :

* V1 : volumes (`exchange_flow_days`)
* V2 : structure (`exchange_flow_day_details`)

La V3 calcule :

* ratios retail / whale / institution
* ratios volume
* scores de concentration
* distribution score
* accumulation score
* behavior score

---

# Objectifs des tests

Les tests doivent vérifier :

1. la cohérence mathématique des ratios
2. la stabilité du builder
3. la gestion des cas extrêmes
4. la cohérence avec V1 et V2
5. la robustesse face aux journées partielles

---

# Test 1 — Existence des tables dépendantes

Avant tout calcul V3, vérifier l’existence des tables nécessaires.

Tables requises :

```text
exchange_flow_days
exchange_flow_day_details
exchange_flow_day_behavior
```

Commande :

```bash
bin/rails runner "
puts ActiveRecord::Base.connection.table_exists?(:exchange_flow_days)
puts ActiveRecord::Base.connection.table_exists?(:exchange_flow_day_details)
puts ActiveRecord::Base.connection.table_exists?(:exchange_flow_day_behavior)
"
```

Résultat attendu :

```text
true
true
true
```

---

# Test 2 — Existence d’une ligne V1 et V2

Pour un jour donné :

```ruby
day = Date.yesterday
```

Tester :

```bash
bin/rails runner "
day = Date.yesterday
puts ExchangeFlowDay.find_by(day: day).present?
puts ExchangeFlowDayDetail.find_by(day: day).present?
"
```

Résultat attendu :

```text
true
true
```

---

# Test 3 — Calcul du builder V3

Exécuter le builder :

```bash
bin/rails runner "p InflowOutflowBehaviorBuilder.call(day: Date.yesterday)"
```

Résultat attendu :

```ruby
{ ok: true, day: Date.yesterday }
```

---

# Test 4 — Vérification insertion ligne V3

Vérifier qu’une ligne est créée.

```bash
bin/rails runner "
p ExchangeFlowDayBehavior.order(day: :desc).limit(5).pluck(:day)
"
```

Résultat attendu :

```text
[2026-03-12]
```

---

# Test 5 — Vérification ratios bornés

Tous les ratios doivent être compris entre :

```text
0.0 et 1.0
```

Test :

```bash
bin/rails runner "
row = ExchangeFlowDayBehavior.last
puts row.retail_deposit_ratio.between?(0,1)
puts row.whale_deposit_ratio.between?(0,1)
puts row.institutional_deposit_ratio.between?(0,1)
"
```

Résultat attendu :

```text
true
true
true
```

---

# Test 6 — Somme logique des ratios

Les ratios ne doivent pas dépasser 1.

Test :

```bash
bin/rails runner "
row = ExchangeFlowDayBehavior.last
sum =
  row.retail_deposit_ratio +
  row.whale_deposit_ratio +
  row.institutional_deposit_ratio

puts sum <= 1.0
"
```

Résultat attendu :

```text
true
```

---

# Test 7 — Cohérence volume vs V1

Comparer volume V1 et ratios volume.

Exemple :

```bash
bin/rails runner "
d = ExchangeFlowDay.last
b = ExchangeFlowDayBehavior.last

puts d.inflow_btc
puts b.retail_deposit_volume_ratio
"
```

Vérification :

```text
ratio * inflow_btc <= inflow_btc
```

---

# Test 8 — Journée sans données

Cas :

```text
deposit_count = 0
withdrawal_count = 0
```

Le builder doit :

* éviter division par zéro
* retourner ratios = 0

Test :

```bash
bin/rails runner "
row = ExchangeFlowDayBehavior.find_by(day: Date.current)
puts row.retail_deposit_ratio
"
```

Résultat attendu :

```text
0
```

---

# Test 9 — Idempotence

Exécuter deux fois le builder :

```bash
bin/rails runner "
InflowOutflowBehaviorBuilder.call(day: Date.yesterday)
InflowOutflowBehaviorBuilder.call(day: Date.yesterday)
"
```

Vérifier :

```bash
bin/rails runner "
puts ExchangeFlowDayBehavior.where(day: Date.yesterday).count
"
```

Résultat attendu :

```text
1
```

---

# Test 10 — Rebuild période

Test rebuild :

```bash
bin/rails runner "
InflowOutflowBehaviorBuilder.call(days_back: 30)
"
```

Vérifier :

```bash
bin/rails runner "
puts ExchangeFlowDayBehavior.count
"
```

Résultat attendu :

```text
>= 30
```

---

# Test 11 — Cohérence distribution / accumulation

Cas typique distribution :

```text
inflow élevé
whale deposits élevés
```

Résultat attendu :

```text
distribution_score élevé
```

Cas accumulation :

```text
outflow élevé
whale withdrawals élevés
```

Résultat attendu :

```text
accumulation_score élevé
```

---

# Test 12 — Journée en cours

Pour :

```text
day = Date.current
```

Les ratios doivent rester valides même si la journée est partielle.

Test :

```bash
bin/rails runner "
row = ExchangeFlowDayBehavior.find_by(day: Date.current)
puts row.present?
"
```

---

# Test 13 — Job V3

Exécuter le job :

```bash
bin/rails runner "
InflowOutflowBehaviorBuildJob.perform_now
"
```

Vérifier dans `JobRun` :

```bash
bin/rails runner "
p JobRun.where(name: 'inflow_outflow_behavior_build').order(started_at: :desc).limit(5)
"
```

Résultat attendu :

```text
status = ok
```

---

# Test 14 — Cron

Après mise en place du cron :

```text
cron_inflow_outflow_behavior_build.sh
```

Vérifier logs :

```bash
grep inflow_outflow_behavior_build log/cron.victor.log
```

Résultat attendu :

```text
start
done
```

---

# Test 15 — Supervision `/system`

Vérifier que `/system` affiche :

* job `inflow_outflow_behavior_build`
* table `exchange_flow_day_behavior`

Vérifier :

```text
days stored
last computed day
status ok
```

---

# Résumé

La V3 est considérée validée lorsque :

* le builder calcule les ratios
* les scores sont cohérents
* les ratios restent bornés
* aucune division par zéro
* les calculs sont idempotents
* le cron fonctionne
* `/system` reflète l’état du module

---

# Tests futurs possibles

Tests plus avancés possibles :

* simulation marché retail panic
* simulation whale distribution
* simulation accumulation institutionnelle
* backtesting comportement vs prix BTC

Ces tests seront documentés dans `AMELIORATION.md`.
