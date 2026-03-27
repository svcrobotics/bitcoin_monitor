
# Inflow / Outflow — V2 — Architecture

Ce document décrit l’architecture de la V2 du module `inflow_outflow`.

La V1 calcule :

- inflow BTC journalier
- outflow BTC journalier
- netflow BTC journalier

La V2 ajoute une couche d’analyse supplémentaire :

- composition des dépôts
- segmentation par taille
- lecture de la structure de l’inflow
- premiers signaux sur la nature des flux

La V2 ne remplace pas la V1.  
Elle l’enrichit.

---

# Objectif de la V2

La V1 répond à :

- combien de BTC entrent ?
- combien de BTC sortent ?

La V2 doit répondre à des questions plus fines :

- combien de dépôts composent l’inflow ?
- l’inflow est-il concentré ou diffus ?
- les dépôts proviennent-ils surtout de petits ou gros montants ?
- le flux observé ressemble-t-il à une activité retail ou whale ?

En résumé :

```text
V1 = volume
V2 = structure du volume
````

---

# Position dans l’architecture

La V2 reste une couche d’agrégation au-dessus de `exchange_like`.

Pipeline complet :

```text
Bitcoin blockchain
        ↓
ExchangeAddressBuilder
        ↓
exchange_addresses
        ↓
ExchangeObservedScanner
        ↓
exchange_observed_utxos
        ↓
InflowOutflowBuilder V1
        ↓
exchange_flow_days
        ↓
InflowOutflowBuilder V2
        ↓
exchange_flow_day_details
```

Le module V2 lit toujours :

```text
exchange_observed_utxos
```

et s’appuie aussi sur :

```text
exchange_flow_days
```

si nécessaire.

---

# Principe général

La V2 enrichit surtout l’analyse de l’inflow.

Pourquoi ?

Parce qu’un inflow de :

```text
10 000 BTC
```

peut avoir deux significations très différentes :

## Cas A

```text
2 dépôts de 5 000 BTC
```

Lecture possible :

* whale
* desk OTC
* institution
* risque de vente concentrée

## Cas B

```text
20 000 dépôts de 0.5 BTC
```

Lecture possible :

* retail
* activité normale exchange
* bruit de fond utilisateur

Donc la V2 ne regarde pas seulement :

```text
combien entre
```

mais aussi :

```text
comment cela entre
```

---

# Source de données

La V2 s’appuie sur les lignes de `exchange_observed_utxos` où :

```text
seen_day = jour observé
```

Chaque ligne représente un UTXO reçu sur une adresse `exchange-like`.

Pour la V2, chaque ligne est interprétée comme un dépôt élémentaire observé.

---

# Concepts fonctionnels de la V2

## 1. Deposit count

Nombre total de dépôts observés sur un jour.

Formule :

```text
deposit_count(day) = nombre de lignes où seen_day = day
```

---

## 2. Average deposit size

Taille moyenne d’un dépôt.

Formule :

```text
avg_deposit_btc(day) = inflow_btc(day) / deposit_count(day)
```

---

## 3. Largest deposit

Plus gros dépôt observé sur la journée.

Formule :

```text
max_deposit_btc(day) = MAX(value_btc) où seen_day = day
```

---

## 4. Deposit buckets

Segmentation des dépôts par taille.

Buckets proposés pour la V2 :

* `< 1 BTC`
* `1 – 10 BTC`
* `10 – 100 BTC`
* `100 – 500 BTC`
* `> 500 BTC`

Pour chaque bucket, la V2 doit calculer :

* volume BTC du bucket
* nombre de dépôts dans le bucket

Exemples :

```text
inflow_lt_1_btc
inflow_1_10_btc
inflow_10_100_btc
inflow_100_500_btc
inflow_gt_500_btc
```

et

```text
inflow_lt_1_count
inflow_1_10_count
inflow_10_100_count
inflow_100_500_count
inflow_gt_500_count
```

---

# Choix d’architecture V2

## Décision 1 — Séparer V1 et V2

La V2 ne surcharge pas `exchange_flow_days`.

Pourquoi ?

Parce que `exchange_flow_days` contient les agrégats simples et stables de la V1.

La V2 ajoute des métriques plus riches, plus nombreuses, et plus évolutives.

Il est donc préférable de créer une table dédiée.

---

# Table cible V2

Table proposée :

```text
exchange_flow_day_details
```

Cette table contient les enrichissements journaliers.

---

## Colonnes proposées

### Clé

| colonne | rôle        |
| ------- | ----------- |
| day     | jour agrégé |

---

### Dépôts globaux

| colonne            | rôle                                  |
| ------------------ | ------------------------------------- |
| deposit_count      | nombre total de dépôts                |
| avg_deposit_btc    | dépôt moyen                           |
| max_deposit_btc    | plus gros dépôt                       |
| median_deposit_btc | dépôt médian (optionnel V2.1 ou V2.2) |

---

### Buckets BTC

| colonne            | rôle                                   |
| ------------------ | -------------------------------------- |
| inflow_lt_1_btc    | volume des dépôts < 1 BTC              |
| inflow_1_10_btc    | volume des dépôts entre 1 et 10 BTC    |
| inflow_10_100_btc  | volume des dépôts entre 10 et 100 BTC  |
| inflow_100_500_btc | volume des dépôts entre 100 et 500 BTC |
| inflow_gt_500_btc  | volume des dépôts > 500 BTC            |

---

### Buckets counts

| colonne              | rôle                                  |
| -------------------- | ------------------------------------- |
| inflow_lt_1_count    | nombre de dépôts < 1 BTC              |
| inflow_1_10_count    | nombre de dépôts entre 1 et 10 BTC    |
| inflow_10_100_count  | nombre de dépôts entre 10 et 100 BTC  |
| inflow_100_500_count | nombre de dépôts entre 100 et 500 BTC |
| inflow_gt_500_count  | nombre de dépôts > 500 BTC            |

---

### Timestamps

| colonne     | rôle            |
| ----------- | --------------- |
| computed_at | date de calcul  |
| created_at  | timestamp Rails |
| updated_at  | timestamp Rails |

---

# Pourquoi une table dédiée

Cette séparation permet :

* de garder `exchange_flow_days` simple
* de faire évoluer la V2 sans casser la V1
* de monétiser / exposer la V2 séparément dans l’interface
* d’ajouter plus tard des stats supplémentaires sans alourdir la table V1

En résumé :

```text
exchange_flow_days = vue simple
exchange_flow_day_details = vue enrichie
```

---

# Service principal V2

Service prévu :

```text
app/services/inflow_outflow_details_builder.rb
```

Responsabilités :

* lire `exchange_observed_utxos`
* filtrer les lignes d’inflow pour un jour donné
* segmenter les dépôts par bucket
* calculer les statistiques de dépôts
* écrire dans `exchange_flow_day_details`

---

# Modes d’exécution

La V2 doit supporter les mêmes modes que la V1.

## Calcul d’un jour

```ruby
InflowOutflowDetailsBuilder.call(day: Date.yesterday)
```

## Rebuild d’une période

```ruby
InflowOutflowDetailsBuilder.call(days_back: 30)
```

Cela permet :

* alignement V1/V2
* rebuild historique
* recalcul ciblé

---

# Stratégie de calcul

Pour un jour donné :

1. lire les lignes :

```text
ExchangeObservedUtxo.where(seen_day: day)
```

2. extraire `value_btc`
3. compter les lignes
4. sommer par bucket
5. compter par bucket
6. calculer `avg_deposit_btc`
7. calculer `max_deposit_btc`
8. persister dans `exchange_flow_day_details`

---

# Idempotence

Comme la V1, la V2 doit être idempotente.

Règle :

* une seule ligne par `day`
* si le jour existe déjà, il est mis à jour
* pas de doublons

La table doit donc avoir :

```text
index unique sur day
```

---

# Vue V2

La V2 doit être visible dans l’interface, mais séparée de la V1 en termes de niveau produit.

Approche recommandée :

## Page unique

```text
/inflow_outflow
```

avec plusieurs niveaux d’accès :

* V1 visible pour tous
* V2 déverrouillée pour les abonnés premium
* V3 pour les offres plus avancées

---

## Composants visuels V2

### Deposit composition

Graphique de répartition des dépôts par taille.

Exemples :

* part du volume par bucket
* part du nombre de dépôts par bucket

---

### Deposit stats

Cartes ou tableau :

* deposit count
* avg deposit
* max deposit

---

### Deposit profile

Lecture rapide du jour :

* retail-heavy
* mixed
* whale-heavy

Cette qualification peut être calculée plus tard à partir des buckets.

---

# Fréquence d’exécution

Comme la V2 repose sur des agrégats journaliers, elle peut être calculée :

* 1 fois / heure
* ou 1 fois / jour

Pour garder la cohérence avec la V1, une exécution horaire est acceptable.

---

# Cron et job

Scripts prévus :

```text
bin/cron_inflow_outflow_details_build.sh
```

Job prévu :

```text
InflowOutflowDetailsBuildJob
```

Suivi via :

```text
JobRun
```

---

# Supervision

Le module V2 doit être visible dans `/system` via :

* job `inflow_outflow_details_build`
* table `exchange_flow_day_details`

Informations minimales :

* dernier run
* dernier jour calculé
* statut
* fraîcheur de la table

---

# Performances

La V2 est peu coûteuse.

Elle ne relit pas la blockchain et travaille uniquement sur des requêtes journalières.

Les performances dépendront surtout de :

* la taille de `exchange_observed_utxos`
* l’index sur `seen_day`

Comme cet index existe déjà, la V2 doit rester légère.

---

# Limites V2

La V2 apporte une lecture structurelle des dépôts, mais elle ne répond pas encore à :

* quelle adresse source a déposé
* si le dépôt est retail, whale ou transfert interne avec certitude
* si plusieurs dépôts appartiennent au même cluster
* si le flux est lié à un exchange spécifique

La V2 reste une couche de segmentation, pas encore une couche d’identité on-chain.

---

# Évolutions V3 naturelles

La V3 pourra ajouter :

* clustering de sources
* qualification des dépôts (retail / whale / institution)
* détection des transferts internes
* score de pression vendeuse
* score de concentration des dépôts
* analyse des plus gros déposants
* alertes sur spikes de dépôts > X BTC

---

# Conclusion

La V2 du module `inflow_outflow` ne se contente plus de mesurer le volume.

Elle commence à mesurer la structure des flux entrants.

En résumé :

```text
V1 = combien entre / sort
V2 = comment l’inflow est composé
```

C’est cette étape qui transforme un simple module de flux en véritable brique
d’analyse de marché pour Bitcoin Monitor.


