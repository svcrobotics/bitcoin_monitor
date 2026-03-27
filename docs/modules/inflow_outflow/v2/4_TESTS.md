
# Inflow / Outflow — V2 — Tests

Ce document décrit les tests permettant de vérifier le bon fonctionnement
du module `inflow_outflow` V2.

La V2 enrichit la V1 en analysant la composition des dépôts observés.

Objectifs des tests :

- vérifier la cohérence des statistiques
- vérifier la stabilité du builder
- détecter les erreurs de bucket
- valider la persistance des données

---

# Test 1 — Exécution du builder pour un jour

Commande :

```ruby
bin/rails runner "p InflowOutflowDetailsBuilder.call(day: Date.yesterday)"
````

Résultat attendu :

* aucune erreur
* ligne créée dans `exchange_flow_day_details`

Vérification :

```ruby
bin/rails runner "p ExchangeFlowDayDetail.order(day: :desc).first"
```

La ligne doit contenir :

* `deposit_count`
* `avg_deposit_btc`
* `max_deposit_btc`

---

# Test 2 — Rebuild d’une période

Commande :

```ruby
bin/rails runner "p InflowOutflowDetailsBuilder.call(days_back: 7)"
```

Résultat attendu :

* 7 lignes calculées ou mises à jour
* aucune duplication

Vérification :

```ruby
bin/rails runner "puts ExchangeFlowDayDetail.count"
```

---

# Test 3 — Vérifier la cohérence `deposit_count`

Commande :

```ruby
bin/rails runner "
day = Date.yesterday
puts ExchangeObservedUtxo.where(seen_day: day).count
puts ExchangeFlowDayDetail.find_by(day: day)&.deposit_count
"
```

Résultat attendu :

```text
deposit_count = nombre de lignes seen_day
```

---

# Test 4 — Vérifier `avg_deposit_btc`

Formule attendue :

```text
avg_deposit_btc = inflow_btc / deposit_count
```

Commande :

```ruby
bin/rails runner "
day = Date.yesterday
row = ExchangeFlowDayDetail.find_by(day: day)
flow = ExchangeFlowDay.find_by(day: day)

puts flow.inflow_btc / row.deposit_count
puts row.avg_deposit_btc
"
```

Les valeurs doivent être très proches.

---

# Test 5 — Vérifier `max_deposit_btc`

Commande :

```ruby
bin/rails runner "
day = Date.yesterday
puts ExchangeObservedUtxo.where(seen_day: day).maximum(:value_btc)
puts ExchangeFlowDayDetail.find_by(day: day)&.max_deposit_btc
"
```

Résultat attendu :

les deux valeurs doivent être identiques.

---

# Test 6 — Vérifier les buckets BTC

Buckets définis :

```text
< 1 BTC
1 – 10 BTC
10 – 100 BTC
100 – 500 BTC
> 500 BTC
```

Commande :

```ruby
bin/rails runner "
day = Date.yesterday
ExchangeObservedUtxo.where(seen_day: day).group(
  'CASE
    WHEN value_btc < 1 THEN ''lt1''
    WHEN value_btc < 10 THEN ''1_10''
    WHEN value_btc < 100 THEN ''10_100''
    WHEN value_btc < 500 THEN ''100_500''
    ELSE ''gt500''
  END
).count.each { |k,v| puts \"#{k}: #{v}\" }
"
```

Comparer avec :

```ruby
ExchangeFlowDayDetail.find_by(day: day)
```

Les counts doivent correspondre.

---

# Test 7 — Vérifier les volumes par bucket

Commande :

```ruby
bin/rails runner "
day = Date.yesterday
ExchangeObservedUtxo.where(seen_day: day).group(
  'CASE
    WHEN value_btc < 1 THEN ''lt1''
    WHEN value_btc < 10 THEN ''1_10''
    WHEN value_btc < 100 THEN ''10_100''
    WHEN value_btc < 500 THEN ''100_500''
    ELSE ''gt500''
  END
).sum(:value_btc).each { |k,v| puts \"#{k}: #{v}\" }
"
```

Comparer avec les colonnes :

```text
inflow_lt_1_btc
inflow_1_10_btc
inflow_10_100_btc
inflow_100_500_btc
inflow_gt_500_btc
```

---

# Test 8 — Vérifier la persistance idempotente

Lancer deux fois :

```ruby
bin/rails runner "p InflowOutflowDetailsBuilder.call(day: Date.yesterday)"
```

Résultat attendu :

* aucune duplication
* la ligne est mise à jour

Vérification :

```ruby
bin/rails runner "
puts ExchangeFlowDayDetail.where(day: Date.yesterday).count
"
```

Résultat attendu :

```text
1
```

---

# Test 9 — Vérifier le job

Commande :

```ruby
bin/rails runner "InflowOutflowDetailsBuildJob.perform_now"
```

Vérification :

```ruby
bin/rails runner "
JobRun.where(name: 'inflow_outflow_details_build').order(started_at: :desc).limit(5).each do |j|
  puts \"#{j.started_at} | #{j.status}\"
end
"
```

Résultat attendu :

```text
status = ok
```

---

# Test 10 — Vérifier la supervision `/system`

La page `/system` doit afficher :

* job `inflow_outflow_details_build`
* table `exchange_flow_day_details`

Statut attendu :

```text
OK
```

---

# Test 11 — Vérifier la vue V2

La vue doit afficher correctement :

* deposit_count
* avg_deposit_btc
* max_deposit_btc
* buckets BTC
* buckets count

Vérifier :

* aucune erreur Rails
* chiffres cohérents
* mise à jour quotidienne

---

# Conclusion

Les tests V2 visent à garantir :

* cohérence mathématique
* stabilité du builder
* absence de duplication
* fiabilité des buckets

Une fois ces tests validés, le module `inflow_outflow` V2 peut être considéré
comme stable pour l’exploitation dans Bitcoin Monitor.


