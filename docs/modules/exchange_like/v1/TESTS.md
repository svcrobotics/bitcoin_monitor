
# Exchange Like — V1 — Tests

Ce document décrit les tests effectués pour valider le fonctionnement du module `exchange_like`.

Les tests couvrent :

- le builder
- le scanner
- l'incrémental
- les index
- les cron
- les performances

---

# 1 — Test du ExchangeAddressBuilder

## Objectif

Vérifier que le builder :

- scanne correctement les blocs
- apprend des adresses
- persiste les résultats dans `exchange_addresses`

---

## Test manuel

Exécuter :

```bash
bin/rails runner "ExchangeAddressBuilder.call(blocks_back: 100)"
````

Résultat attendu :

logs similaires à :

```
[exchange_addr_builder] start ...
[exchange_addr_builder] progress ...
[exchange_addr_builder] flush ...
[exchange_addr_builder] done ...
```

---

## Vérification en base

Contrôler le nombre d'adresses :

```bash
bin/rails runner "puts ExchangeAddress.count"
```

Vérifier les plus fréquentes :

```bash
bin/rails runner "puts ExchangeAddress.order(occurrences: :desc).limit(20).pluck(:address, :occurrences)"
```

---

# 2 — Test du flush intermédiaire builder

## Objectif

Vérifier que les agrégats mémoire sont flushés.

---

## Test

Exécuter :

```bash
bin/rails runner "ExchangeAddressBuilder.call(blocks_back: 100)"
```

Résultat attendu :

présence de logs :

```
flush flush_no=1
flush flush_no=2
```

---

# 3 — Test du mode incrémental builder

## Objectif

Vérifier que le builder reprend au dernier bloc traité.

---

## Test

Première exécution :

```bash
bin/rails runner "ExchangeAddressBuilderJob.perform_now"
```

Deuxième exécution :

```bash
bin/rails runner "ExchangeAddressBuilderJob.perform_now"
```

Résultat attendu :

```
nothing to scan
```

---

## Vérification du curseur

```bash
bin/rails runner "p ScannerCursor.find_by(name: 'exchange_address_builder')&.attributes"
```

Résultat attendu :

```
last_blockheight != nil
```

---

# 4 — Test du scanner observé

## Objectif

Vérifier que le scanner :

* détecte les UTXO
* met à jour `exchange_observed_utxos`

---

## Test manuel

Exécuter :

```bash
bin/rails runner "ExchangeObservedScanJob.perform_now"
```

Résultat attendu :

```
[exchange_observed_scan] start ...
[exchange_observed_scan] progress ...
```

---

# 5 — Test du mode incrémental scanner

## Objectif

Vérifier que le scanner reprend au dernier bloc observé.

---

## Test

Exécuter :

```bash
bin/rails runner "ExchangeObservedScanJob.perform_now"
```

puis exécuter à nouveau.

Résultat attendu :

```
nothing to scan
```

---

## Vérification du curseur

```bash
bin/rails runner "p ScannerCursor.find_by(name: 'exchange_observed_scan')&.attributes"
```

---

# 6 — Test du set scanné

## Objectif

Vérifier que le scanner utilise `ExchangeAddress.scannable`.

---

## Test

Exécuter :

```bash
bin/rails runner "puts ExchangeAddress.scannable.count"
```

puis :

```bash
bin/rails runner "ExchangeObservedScanner.call(last_n_blocks: 1)"
```

Résultat attendu :

```
exchange_set_size = <scannable.count>
```

---

# 7 — Test des index `exchange_addresses`

## Objectif

Vérifier l'index unique sur `address`.

---

## Test

```bash
bin/rails runner "p ActiveRecord::Base.connection.indexes(:exchange_addresses).map { |i| [i.name, i.columns, i.unique] }"
```

Résultat attendu :

```
index_exchange_addresses_on_address
unique = true
```

---

# 8 — Test des index `exchange_observed_utxos`

## Objectif

Vérifier les index nécessaires pour les performances.

---

## Test

```bash
bin/rails runner "p ActiveRecord::Base.connection.indexes(:exchange_observed_utxos).map { |i| [i.name, i.columns] }"
```

Index attendus :

* txid + vout
* address
* address + seen_day
* seen_day
* spent_day
* spent_by_txid

---

# 9 — Test des cron

## Objectif

Vérifier l'exécution automatique des jobs.

---

## Vérification

```bash
crontab -l
```

Entrées attendues :

* builder
* scanner
* autres modules

---

## Vérification logs

```bash
grep exchange_observed_scan log/cron.victor.log
```

Résultat attendu :

```
start
done
```

---

# 10 — Test de reprise après redémarrage

## Objectif

Vérifier la résilience du module.

---

## Procédure

1. arrêter les services
2. redémarrer la machine
3. attendre l'exécution cron

---

## Résultat attendu

Le module reprend automatiquement grâce aux curseurs :

```
exchange_address_builder
exchange_observed_scan
```

Aucun rescanning complet n'est effectué.

---

# 11 — Test des performances

## Builder

Scan de 100 blocs :

durée typique :

```
~15 à 180 secondes
```

selon la densité des blocs.

---

## Scanner

Scan incrémental :

durée typique :

```
< 1 minute
```

si plusieurs blocs.

```
< 1 seconde
```

si rien à scanner.

---

# Conclusion

Les tests montrent que :

* le builder fonctionne
* le builder est incrémental
* le scanner fonctionne
* le scanner est incrémental
* les index sont en place
* les cron exécutent correctement les jobs
* le module est résilient aux redémarrages

