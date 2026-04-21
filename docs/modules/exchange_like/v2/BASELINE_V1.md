# Exchange Like — V1 — Baseline

Date : YYYY-MM-DD  
Environnement : (dev / prod / autre)

---

# 🎯 Objectif

Capturer l’état actuel du module `exchange_like` avant refactorisation.

Cette baseline servira de référence pour comparer les résultats après migration V2.

---

# 📊 Dataset

## Exchange Addresses

- total_addresses :
- operational_addresses :
- scannable_addresses :

## Évolution récente

- new_addresses_24h :
- updated_addresses_24h :

## Distribution des scores

- avg_confidence :
- max_confidence :
- min_confidence :

---

# 📦 Observed UTXOs

- total_utxos :
- seen_utxos_24h :
- spent_utxos_24h :

---

# ⛓️ Blockchain / Scanner

## Builder

- last_builder_run_at :
- last_builder_success_at :
- last_builder_block :
- builder_lag_blocks :
- builder_duration_ms :

## Scanner

- last_scanner_run_at :
- last_scanner_success_at :
- last_scanner_block :
- scanner_lag_blocks :
- scanner_duration_ms :

---

# ⚙️ Volumétrie (optionnel mais utile)

- blocks_scanned_last_run :
- txs_scanned_last_run :
- outputs_scanned_last_run :

---

# 🚨 Santé

- builder_status : (OK / LATE / FAIL)
- scanner_status : (OK / LATE / FAIL)
- errors_last_24h :

---

# 🧠 Notes

- observations particulières :
- anomalies visibles :
- lenteurs :
- comportements inattendus :

---

# 📌 Comment récupérer les données

## Rails console

Exemples :

```ruby
ExchangeAddress.count
ExchangeAddress.operational.count
ExchangeAddress.scannable.count

ExchangeObservedUtxo.count

ExchangeObservedUtxo.where(seen_day: Date.current).sum(:value_btc)
ExchangeObservedUtxo.where(spent_day: Date.current).sum(:value_btc)
````

## JobRun

```ruby
JobRun.where(job_name: "exchange_address_builder").last
JobRun.where(job_name: "exchange_observed_scan").last
```

## Cursor

```ruby
ScannerCursor.find_by(name: "exchange_address_builder")
ScannerCursor.find_by(name: "exchange_observed_scan")
```

---

# ✅ Validation

* [ ] Dataset cohérent
* [ ] Pas d’anomalie majeure
* [ ] Builder et scanner actifs
* [ ] Curseurs avancent correctement

---

# 🧾 Conclusion

Baseline validée pour démarrer la migration V2.