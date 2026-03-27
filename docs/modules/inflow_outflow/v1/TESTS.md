
# Inflow / Outflow — V1 — Tests

Ce document liste les tests réalisés pour valider le bon fonctionnement
du module `inflow_outflow`.

Le but est de vérifier :

- la cohérence des calculs
- la stabilité du builder
- la validité des données produites

---

# Test 1 — Présence des données sources

Le module dépend uniquement de la table :

```

exchange_observed_utxos

````

Vérification :

```ruby
ExchangeObservedUtxo.count
````

Résultat attendu :

* la table contient des données
* les colonnes `seen_day` et `spent_day` sont remplies

---

# Test 2 — Vérification des inflows

Calcul manuel :

```ruby
ExchangeObservedUtxo
  .where(seen_day: Date.yesterday)
  .sum(:value_btc)
```

Résultat attendu :

* correspond au `inflow_btc` enregistré dans `exchange_flow_days`

---

# Test 3 — Vérification des outflows

Calcul manuel :

```ruby
ExchangeObservedUtxo
  .where(spent_day: Date.yesterday)
  .sum(:value_btc)
```

Résultat attendu :

* correspond au `outflow_btc` enregistré dans `exchange_flow_days`

---

# Test 4 — Vérification du netflow

Calcul :

```
netflow = inflow_btc - outflow_btc
```

Vérification :

* le champ `netflow_btc` correspond à la différence.

---

# Test 5 — Vérification des compteurs UTXO

Calcul manuel :

```ruby
ExchangeObservedUtxo
  .where(seen_day: Date.yesterday)
  .count
```

Doit correspondre à :

```
inflow_utxo_count
```

Même principe pour :

```
outflow_utxo_count
```

---

# Test 6 — Rebuild historique

Exécution :

```ruby
InflowOutflowBuilder.call(days_back: 30)
```

Résultat attendu :

* 30 lignes dans `exchange_flow_days`
* aucune duplication
* recalcul correct

---

# Test 7 — Idempotence

Exécuter deux fois :

```ruby
InflowOutflowBuilder.call(day: Date.yesterday)
```

Résultat attendu :

* une seule ligne pour ce jour
* les valeurs sont mises à jour
* pas de duplication

---

# Test 8 — Vérification index unique

Commande :

```ruby
ActiveRecord::Base.connection.indexes(:exchange_flow_days)
```

Résultat attendu :

index unique sur :

```
day
```

---

# Test 9 — Vérification job

Exécution :

```ruby
InflowOutflowBuildJob.perform_now
```

Résultat attendu :

* le job s'exécute sans erreur
* entrée créée dans `job_runs`

---

# Test 10 — Vérification cron

Script exécuté :

```
bin/cron_inflow_outflow_build.sh
```

Log attendu :

```
[inflow_outflow_build] start
[inflow_outflow_build] done
```

---

# Test 11 — Vérification vue

La page :

```
/inflow_outflow
```

doit afficher :

* inflow journalier
* outflow journalier
* netflow
* graphique de flux

---

# Test 12 — Vérification cohérence globale

Comparer :

```
Σ inflow_btc sur période
```

avec :

```
Σ value_btc where seen_day sur la même période
```

Les valeurs doivent être identiques.

---

# Conclusion

Les tests confirment que :

* les inflows sont correctement calculés
* les outflows sont correctement calculés
* le netflow est cohérent
* le builder est idempotent
* le module fonctionne sans rescanner la blockchain


