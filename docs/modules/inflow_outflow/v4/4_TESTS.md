
# Inflow / Outflow — V4 — Tests

Ce document décrit les tests permettant de valider le fonctionnement de la
**V4 du module `inflow_outflow`**.

La V4 introduit une analyse du **comportement du capital**.

Elle s’appuie sur :

- V1 : `exchange_flow_days`
- V2 : `exchange_flow_day_details`
- V3 : `exchange_flow_day_behaviors`

La V4 calcule :

- ratios capital retail / whale / institution
- `capital_dominance_score`
- `whale_distribution_score`
- `whale_accumulation_score`
- `count_volume_divergence_score`
- `capital_behavior_score`

---

# Objectifs des tests

Les tests doivent vérifier :

1. la cohérence mathématique des ratios capital
2. la stabilité du builder
3. la cohérence avec V1 / V2 / V3
4. la robustesse face aux journées vides ou partielles
5. l’idempotence du calcul
6. la bonne intégration dans le pipeline global

---

# Test 1 — Existence des tables dépendantes

Avant tout calcul V4, vérifier l’existence des tables nécessaires.

Tables requises :

```text
exchange_flow_days
exchange_flow_day_details
exchange_flow_day_behaviors
exchange_flow_day_capital_behaviors
````

Commande :

```bash
bin/rails runner "
puts ActiveRecord::Base.connection.table_exists?(:exchange_flow_days)
puts ActiveRecord::Base.connection.table_exists?(:exchange_flow_day_details)
puts ActiveRecord::Base.connection.table_exists?(:exchange_flow_day_behaviors)
puts ActiveRecord::Base.connection.table_exists?(:exchange_flow_day_capital_behaviors)
"
```

Résultat attendu :

```text
true
true
true
true
```

---

# Test 2 — Existence d’une ligne V1, V2, V3 pour le jour testé

Pour un jour donné :

```ruby
day = Date.yesterday
```

Commande :

```bash
bin/rails runner "
day = Date.yesterday
puts ExchangeFlowDay.find_by(day: day).present?
puts ExchangeFlowDayDetail.find_by(day: day).present?
puts ExchangeFlowDayBehavior.find_by(day: day).present?
"
```

Résultat attendu :

```text
true
true
true
```

---

# Test 3 — Calcul du builder V4 sur un jour

Commande :

```bash
bin/rails runner "p InflowOutflowCapitalBehaviorBuilder.call(day: Date.yesterday)"
```

Résultat attendu :

```ruby
{ ok: true, mode: :single_day, day: Date.yesterday }
```

---

# Test 4 — Vérifier insertion de la ligne V4

Commande :

```bash
bin/rails runner "
p ExchangeFlowDayCapitalBehavior.order(day: :desc).limit(5).pluck(:day)
"
```

Résultat attendu :

la date testée doit apparaître.

---

# Test 5 — Vérifier que les ratios capital sont bornés entre 0 et 1

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.last
puts row.retail_deposit_capital_ratio.between?(0,1)
puts row.whale_deposit_capital_ratio.between?(0,1)
puts row.institutional_deposit_capital_ratio.between?(0,1)
puts row.retail_withdrawal_capital_ratio.between?(0,1)
puts row.whale_withdrawal_capital_ratio.between?(0,1)
puts row.institutional_withdrawal_capital_ratio.between?(0,1)
"
```

Résultat attendu :

```text
true
true
true
true
true
true
```

---

# Test 6 — Vérifier la somme logique des ratios capital dépôts

La somme des ratios dépôts ne doit pas dépasser 1.

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.last
sum =
  row.retail_deposit_capital_ratio.to_d +
  row.whale_deposit_capital_ratio.to_d +
  row.institutional_deposit_capital_ratio.to_d

puts sum <= 1
puts sum
"
```

Résultat attendu :

```text
true
```

La somme peut être inférieure à 1 selon la logique d’arrondi.

---

# Test 7 — Vérifier la somme logique des ratios capital retraits

Même logique côté retraits.

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.last
sum =
  row.retail_withdrawal_capital_ratio.to_d +
  row.whale_withdrawal_capital_ratio.to_d +
  row.institutional_withdrawal_capital_ratio.to_d

puts sum <= 1
puts sum
"
```

Résultat attendu :

```text
true
```

---

# Test 8 — Vérifier cohérence V2 → V4 sur les dépôts

Le ratio retail capital doit être cohérent avec les volumes V2.

Commande :

```bash
bin/rails runner "
day = Date.yesterday
d2 = ExchangeFlowDayDetail.find_by(day: day)
d1 = ExchangeFlowDay.find_by(day: day)
d4 = ExchangeFlowDayCapitalBehavior.find_by(day: day)

expected =
  if d1.inflow_btc.to_d > 0
    (d2.inflow_lt_1_btc.to_d + d2.inflow_1_10_btc.to_d) / d1.inflow_btc.to_d
  else
    0.to_d
  end

puts expected
puts d4.retail_deposit_capital_ratio
"
```

Résultat attendu :

les deux valeurs doivent être identiques ou très proches.

---

# Test 9 — Vérifier cohérence V2 → V4 sur les retraits

Commande :

```bash
bin/rails runner "
day = Date.yesterday
d2 = ExchangeFlowDayDetail.find_by(day: day)
d1 = ExchangeFlowDay.find_by(day: day)
d4 = ExchangeFlowDayCapitalBehavior.find_by(day: day)

expected =
  if d1.outflow_btc.to_d > 0
    (d2.outflow_lt_1_btc.to_d + d2.outflow_1_10_btc.to_d) / d1.outflow_btc.to_d
  else
    0.to_d
  end

puts expected
puts d4.retail_withdrawal_capital_ratio
"
```

Résultat attendu :

les deux valeurs doivent être identiques ou très proches.

---

# Test 10 — Vérifier la divergence count / volume

L’objectif est de confirmer que la V4 mesure bien une divergence
entre activité et capital.

Commande :

```bash
bin/rails runner "
day = Date.yesterday
v3 = ExchangeFlowDayBehavior.find_by(day: day)
v4 = ExchangeFlowDayCapitalBehavior.find_by(day: day)

puts v3.whale_deposit_ratio
puts v4.whale_deposit_capital_ratio
puts v4.count_volume_divergence_score
"
```

Résultat attendu :

si le volume whale est très supérieur à l’activité whale,
le score de divergence doit être non nul.

---

# Test 11 — Vérifier `capital_dominance_score`

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.last
puts row.capital_dominance_score
puts row.capital_dominance_score.between?(0,1)
"
```

Résultat attendu :

* score compris entre `0` et `1`
* plus il est élevé, plus le capital est dominé par whales / institution

---

# Test 12 — Vérifier `whale_distribution_score`

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.last
puts row.whale_distribution_score
puts row.whale_distribution_score.between?(0,1)
"
```

Résultat attendu :

score compris entre `0` et `1`.

---

# Test 13 — Vérifier `whale_accumulation_score`

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.last
puts row.whale_accumulation_score
puts row.whale_accumulation_score.between?(0,1)
"
```

Résultat attendu :

score compris entre `0` et `1`.

---

# Test 14 — Vérifier `capital_behavior_score`

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.last
puts row.capital_behavior_score
puts row.capital_behavior_score.between?(0,1)
"
```

Résultat attendu :

score compris entre `0` et `1`.

---

# Test 15 — Journée sans données

Cas extrême :

* `inflow_btc = 0`
* `outflow_btc = 0`

Le builder doit :

* éviter les divisions par zéro
* produire des ratios à `0`

Commande :

```bash
bin/rails runner "
row = ExchangeFlowDayCapitalBehavior.find_by(day: Date.current)
p row&.attributes
"
```

Résultat attendu :

si la journée est vide, les ratios et scores restent à `0`.

---

# Test 16 — Journée en cours

Pour :

```ruby
day = Date.current
```

Le builder doit produire une ligne valide même si la journée est partielle.

Commande :

```bash
bin/rails runner "
p InflowOutflowCapitalBehaviorBuilder.call(day: Date.current)
p ExchangeFlowDayCapitalBehavior.find_by(day: Date.current)&.attributes
"
```

Résultat attendu :

* ligne présente
* pas d’erreur
* ratios bornés
* cohérence avec V1 / V2 / V3 du jour

---

# Test 17 — Idempotence

Exécuter deux fois le builder sur le même jour.

Commande :

```bash
bin/rails runner "
InflowOutflowCapitalBehaviorBuilder.call(day: Date.yesterday)
InflowOutflowCapitalBehaviorBuilder.call(day: Date.yesterday)
puts ExchangeFlowDayCapitalBehavior.where(day: Date.yesterday).count
"
```

Résultat attendu :

```text
1
```

---

# Test 18 — Rebuild période

Commande :

```bash
bin/rails runner "
InflowOutflowCapitalBehaviorBuilder.call(days_back: 30)
puts ExchangeFlowDayCapitalBehavior.count
"
```

Résultat attendu :

au moins 30 lignes si les données amont existent.

---

# Test 19 — Job V4

Exécuter le job :

```bash
bin/rails runner "
InflowOutflowCapitalBehaviorBuildJob.perform_now
"
```

Vérifier dans `JobRun` :

```bash
bin/rails runner "
JobRun.where(name: 'inflow_outflow_capital_behavior_build').order(started_at: :desc).limit(5).each do |j|
  puts \"#{j.started_at} | #{j.status} | #{j.duration_ms}\"
end
"
```

Résultat attendu :

```text
status = ok
```

---

# Test 20 — Cron V4

Après mise en place du cron :

```text
bin/cron_inflow_outflow_capital_behavior_build.sh
```

Vérifier les logs :

```bash
grep inflow_outflow_capital_behavior_build log/cron.victor.log
```

Résultat attendu :

```text
start
done
```

---

# Test 21 — Supervision `/system`

Vérifier que `/system` affiche :

* job `inflow_outflow_capital_behavior_build`
* table `exchange_flow_day_capital_behaviors`

Statut attendu :

```text
OK
```

---

# Résumé

La V4 est considérée validée lorsque :

* les ratios capital sont corrects
* les scores sont bornés
* la divergence count / volume est cohérente
* les calculs sont idempotents
* le job fonctionne
* le cron fonctionne
* `/system` reflète l’état du module

---

# Tests futurs possibles

Tests plus avancés possibles :

* simulation retail panic avec faible capital
* simulation whale dominance avec faible activity
* simulation accumulation institutionnelle
* comparaison V3 / V4 sur longues périodes
* backtesting capital behavior vs prix BTC

