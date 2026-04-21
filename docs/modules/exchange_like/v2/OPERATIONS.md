# Exchange Like — V2 — Operations

## Objectif

Ce document décrit :

* comment exploiter le module `exchange_like`
* comment lancer les moteurs
* comment interpréter le monitoring
* comment diagnostiquer les problèmes

---

# 1. Vue d’ensemble

Le module repose sur deux moteurs :

## Builder

* découvre des adresses exchange-like
* alimente `exchange_addresses`

## Scanner

* observe les UTXO de ces adresses
* alimente `exchange_observed_utxos`

---

# 2. Commandes principales

## Builder

### Mode incrémental (production)

```bash
bin/rails runner "ExchangeAddressBuilder.call"
```

* reprend depuis le dernier curseur
* scanne uniquement les nouveaux blocs
* met à jour `exchange_address_builder`

---

### Mode backfill court

```bash
bin/rails runner "ExchangeAddressBuilder.call(blocks_back: 100)"
```

---

### Mode par jours

```bash
bin/rails runner "ExchangeAddressBuilder.call(days_back: 7)"
```

---

### Reset dataset

```bash
bin/rails runner "ExchangeAddressBuilder.call(reset: true)"
```

⚠️ Effets :

* supprime toutes les adresses
* reconstruit un dataset partiel
* impacte le scanner

---

## Scanner

### Mode incrémental

```bash
bin/rails runner "ExchangeObservedScanner.call"
```

---

### Scan court

```bash
bin/rails runner "ExchangeObservedScanner.call(last_n_blocks: 50)"
```

---

### Scan par jours

```bash
bin/rails runner "ExchangeObservedScanner.call(days_back: 3)"
```

---

# 3. Ordre recommandé d’exécution

## Initialisation

```bash
ExchangeAddressBuilder.call(reset: true)
ExchangeObservedScanner.call(last_n_blocks: 100)
```

---

## En production

1. Builder
2. Scanner

---

## Fréquence recommandée

* Builder : toutes les 5–10 minutes
* Scanner : toutes les 1–5 minutes

---

# 4. Monitoring

## Page dédiée

```
/exchange_like
```

Permet de voir :

* dataset
* activité
* évolution
* top adresses

---

## Monitoring global

```
/system
```

Section :

```
Exchange Like
```

---

# 5. Interprétation des statuts

## OK

* lag faible (≈ 0–3 blocs)
* updated_at récent

## LATE

* lag modéré
* moteur en retard mais fonctionnel

## STALE

* updated_at ancien (> 12h)
* moteur probablement stoppé

## FAIL

* curseur absent
* ou incohérence majeure

---

# 6. Métriques importantes

## Dataset

* `addresses_total`
* `operational`
* `scannable`
* `observed_utxo`

---

## Activité récente

* `new_addresses_24h`
* `seen_24h`
* `spent_24h`

---

## Synchronisation

* `builder lag`
* `scanner lag`
* `best block`

---

# 7. Diagnostics

## Builder en retard

Symptômes :

* lag élevé
* status = LATE ou FAIL

Actions :

```bash
ExchangeAddressBuilder.call
```

---

## Scanner en retard

Symptômes :

* lag élevé
* seen/spent stagnent

Actions :

```bash
ExchangeObservedScanner.call
```

---

## Dataset vide ou faible

Causes possibles :

* reset récent
* mauvais paramètres
* fenêtre de scan trop courte

Actions :

```bash
ExchangeAddressBuilder.call(days_back: 7)
```

---

## Seen / Spent = 0

Causes :

* set scannable trop petit
* pas d’activité sur la fenêtre

---

# 8. Bonnes pratiques

## Ne pas reset en production sans raison

* casse la continuité historique
* fausse les métriques 24h

---

## Toujours lancer builder avant scanner

Sinon :

* scanner utilise un dataset incomplet

---

## Surveiller le lag

* lag builder ≠ lag scanner
* ils ont des rôles différents

---

## Garder une cohérence de fenêtre

* builder et scanner doivent couvrir des périodes similaires

---

# 9. Évolutions futures

* cache Redis pour scannable set
* distinction inflow / outflow
* clustering d’adresses
* classification exchange vs service
* alerting temps réel

---

# 10. Résumé

Le module `exchange_like` est :

* stable
* monitoré
* exploitable en production

Il fournit :

* un dataset exchange-like
* une observation UTXO fiable
* une base pour les modules analytiques

---

## Redis

Le module utilise Redis pour mettre en cache le set `scannable` :

- clé : `exchange_like:scannable_addresses`
- rôle : éviter une requête DB répétée à chaque scan
- invalidation : après chaque run du builder
- fallback : rechargement depuis PostgreSQL si cache vide

## Performance — Redis cache

Le set des adresses scannables est mis en cache Redis.

Résultat mesuré :

- sans cache : ~175s
- avec cache : ~48s
- gain : ~72%

Conclusion :
le cache Redis est critique pour les performances du scanner.