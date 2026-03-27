
# Bitcoin Monitor — Cluster V3 — Tests

## 🎯 Objectif

La V3.1 introduit :

* métriques estimées (cluster_metrics)
* signaux comportementaux simples (cluster_signals)

Les tests doivent garantir :

👉 cohérence des données
👉 stabilité du pipeline
👉 lisibilité produit
👉 utilité réelle

⚠️ Important
La V3.1 est **probabiliste** :

* elle n’identifie pas
* elle n’affirme pas
* elle **indique des comportements**

---

# 1. Périmètre testé

## Inclus

* cluster_metrics
* cluster_signals
* ClusterMetricsBuilder
* ClusterSignalEngine
* ClusterAggregator (⚠️ critique)
* page adresse
* page cluster_signals / top

## Exclu (V3.1)

* cluster_alerts
* whales / exchange mapping
* AML
* attribution identité

---

# 2. Niveaux de tests

## 2.1 Unitaires

* modèles
* calculs métriques
* logique signaux

## 2.2 Services

* MetricsBuilder
* SignalEngine
* Aggregator (🔥 très important)

## 2.3 Intégration

* pipeline complet
* cohérence DB

## 2.4 Produit

* compréhension utilisateur
* utilité avant transfert

---

# 3. Jeux de données

## 3.1 Synthétiques

Créer clusters :

* inactif
* faible activité
* activité stable
* spike activité
* volume extrême

## 3.2 Réels (Bitcoin Monitor)

Tester sur :

* cluster très gros (>10k)
* cluster moyen (10–100)
* cluster petit (1–10)
* cluster actif récent
* cluster inactif

---

# 4. Invariants critiques (🔥 NOUVEAU)

---

## 4.1 Cohérence cluster

Toujours vrai :

```ruby
cluster.addresses.sum(:total_sent_sats)
==
cluster.cluster_profile.total_sent_sats
```

### Attendu

* jamais inférieur
* jamais supérieur

### Si faux

👉 cluster dirty / non recalculé

---

## 4.2 Cohérence UI

La UI ne doit JAMAIS afficher :

👉 adresse > cluster

---

## 4.3 Idempotence globale

Re-run :

```ruby
ClusterAggregator.call(cluster)
ClusterMetricsBuilder.call(cluster)
ClusterSignalEngine.call(cluster)
```

### Attendu

* même résultat
* pas de duplication
* pas de dérive

---

# 5. Tests des modèles

---

## 5.1 ClusterMetric

### Vérifier

* présence cluster_id
* présence snapshot_date

### Cas

* création valide
* update sur même snapshot (pas duplication)
* valeurs cohérentes (>0 si activité)

---

## 5.2 ClusterSignal

### Vérifier

* cluster_id
* signal_type

### Cas

* création valide
* plusieurs signaux OK
* remplacement propre (delete + recreate)

---

# 6. Tests ClusterAggregator (🔥 critique)

---

## 6.1 Agrégation correcte

### Données

cluster avec plusieurs adresses

### Attendu

```ruby
profile.total_sent_sats == sum(addresses)
```

---

## 6.2 Après scan

### Pipeline

scanner → aggregator

### Attendu

* profil à jour
* pas de mismatch

---

## 6.3 Dirty clusters

### Cas

modification adresse

### Attendu

* cluster marqué dirty
* recalcul effectué

---

# 7. Tests ClusterMetricsBuilder

---

## 7.1 Cluster sans profil

### Attendu

* nil
* aucune metric

---

## 7.2 Faible activité

### Attendu

* tx_24h faible
* score faible

---

## 7.3 Cluster actif

### Attendu

* tx_24h > 0
* sent_24h > 0

---

## 7.4 Très actif

### Attendu

* score élevé
* cohérence volume

---

## 7.5 Idempotence

### Attendu

* 1 metric par snapshot
* update OK

---

# 8. Tests ClusterSignalEngine

---

## 8.1 Aucun signal

### Attendu

* 0 signal

---

## 8.2 sudden_activity

### Attendu

* tx_24h >> 7d
* ratio présent

---

## 8.3 volume_spike

### Attendu

* volume élevé
* ratio cohérent

---

## 8.4 large_transfers

### Attendu

* volume élevé
* peu de tx
* severity high

---

## 8.5 cluster_activation

### Attendu

* activité récente
* cluster peu actif avant

---

## 8.6 Anti-bruit

### Attendu

* pas de signal inutile

---

## 8.7 Idempotence

### Attendu

* reset + recreate
* pas de duplication

---

# 9. Tests pipeline V3.1

---

## 9.1 Pipeline complet

```ruby
ClusterAggregator.call(cluster)
ClusterMetricsBuilder.call(cluster)
ClusterSignalEngine.call(cluster)
```

### Attendu

* profil OK
* metrics OK
* signals OK

---

## 9.2 Re-run

### Attendu

* mêmes résultats
* pas d’écart

---

# 10. Tests UI — page adresse

---

## 10.1 Avec signaux

### Attendu

* signaux visibles
* severity claire
* score affiché

---

## 10.2 Sans signaux

### Attendu

* message propre
* pas de vide bizarre

---

## 10.3 Cas critique (bug réel corrigé)

### Cas

adresse > cluster

### Attendu

👉 message :

"Cluster incomplet ou en cours de construction"

---

## 10.4 Lisibilité

### Attendu

* compréhensible en <3 sec
* pas de jargon

---

# 11. Tests UI — cluster_signals

---

## 11.1 Liste

### Attendu

* tri par score
* top 100

---

## 11.2 Top clusters

### Attendu

* pertinence
* diversité

---

## 11.3 Navigation

### Attendu

* lien vers adresse OK
* pas d’erreur

---

# 12. Performance

---

## 12.1 Scanner

### Attendu

* scan rapide
* dirty clusters only

---

## 12.2 Metrics

### Attendu

* rapide
* pas de full recompute

---

## 12.3 Signals

### Attendu

* rapide
* basé sur metrics

---

## 12.4 UI

### Attendu

* pas de N+1
* includes OK

---

# 13. Recette produit

---

## 13.1 Compréhension

👉 Est-ce que ça aide ?

✔️ oui

---

## 13.2 Décision

👉 Avant envoi BTC ?

✔️ oui

---

## 13.3 Prudence

👉 Pas d’affirmation ?

✔️ oui

---

# 14. Définition de terminé — V3.1

* [x] cluster_profiles cohérents
* [x] cluster_metrics fonctionnelles
* [x] cluster_signals générés
* [x] page adresse enrichie
* [x] cohérence cluster fixée (🔥)
* [ ] rake tasks V3
* [ ] monitoring complet
* [ ] UI metrics visibles
* [ ] tests automatisés

---

# 15. Philosophie

Les tests ne cherchent pas :

❌ vérité absolue
❌ identité réelle

Ils garantissent :

✅ cohérence
✅ stabilité
✅ lisibilité
✅ utilité

---

# 16. Règle d’or

👉 Un signal doit être compris en moins de 3 secondes

