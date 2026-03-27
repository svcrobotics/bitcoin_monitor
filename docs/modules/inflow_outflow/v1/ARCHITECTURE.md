
# Inflow / Outflow — V1 — Architecture

Ce document décrit l’architecture interne du module `inflow_outflow`.

Le module a pour objectif :

agréger l’activité observée sur les adresses `exchange-like` afin de reconstruire
les flux entrants et sortants des exchanges.

Le module ne rescane pas directement la blockchain.
Il s’appuie sur les données produites par le module `exchange_like`.

---

# Vue générale

Le module fonctionne comme une couche d’agrégation au-dessus de `exchange_like`.

Pipeline :

```text
Blockchain
↓
ExchangeAddressBuilder
↓
exchange_addresses
↓
ExchangeObservedScanner
↓
exchange_observed_utxos
↓
InflowOutflowBuilder
↓
exchange_flow_days
````

Le module `inflow_outflow` commence à partir de :

```text
exchange_observed_utxos
```

---

# Position du module dans le système

Le rôle de `exchange_like` est de :

* découvrir les adresses exchange-like
* observer leurs UTXO
* stocker les événements élémentaires

Le rôle de `inflow_outflow` est de :

* agréger ces événements par jour
* calculer les flux entrants et sortants
* produire une lecture exploitable pour le dashboard et les indicateurs

En résumé :

```text
exchange_like = détection + observation
inflow_outflow = agrégation + interprétation
```

---

# Source de données

Le module consomme :

```text
exchange_observed_utxos
```

Cette table contient déjà les deux événements utiles :

* `seen_day` : un UTXO a été vu sur une adresse exchange-like
* `spent_day` : ce même UTXO a été ensuite dépensé

Le module n’a donc pas besoin de relire les blocs Bitcoin.

---

# Définitions fonctionnelles

## Inflow

Un inflow correspond à un UTXO reçu par une adresse exchange-like.

Dans la V1, un inflow est calculé à partir de :

* `seen_day`
* `value_btc`

Formellement :

```text
inflow(day) = somme(value_btc) des lignes où seen_day = day
```

---

## Outflow

Un outflow correspond à un UTXO précédemment observé sur une adresse exchange-like,
puis dépensé.

Dans la V1, un outflow est calculé à partir de :

* `spent_day`
* `value_btc`

Formellement :

```text
outflow(day) = somme(value_btc) des lignes où spent_day = day
```

---

## Netflow

Le netflow représente la différence entre flux entrants et flux sortants.

Formule :

```text
netflow(day) = inflow(day) - outflow(day)
```

Interprétation simple :

* netflow positif : davantage de BTC entrent sur les adresses exchange-like
* netflow négatif : davantage de BTC sortent des adresses exchange-like

---

# Composants

Le module V1 repose sur un service principal.

| composant            | rôle                             |
| -------------------- | -------------------------------- |
| InflowOutflowBuilder | calcule les agrégats journaliers |

À terme, le module pourra aussi inclure :

| composant          | rôle                              |
| ------------------ | --------------------------------- |
| InflowOutflowJob   | exécution supervisée via `JobRun` |
| vue inflow/outflow | affichage dashboard / analytics   |

---

# InflowOutflowBuilder

Service prévu :

```text
app/services/inflow_outflow_builder.rb
```

Objectif :

calculer les agrégats journaliers à partir de `exchange_observed_utxos`.

---

## Logique générale

Pour un jour donné `D`, le builder calcule :

* `inflow_btc`
* `outflow_btc`
* `netflow_btc`
* `inflow_utxo_count`
* `outflow_utxo_count`

Le builder écrit ensuite une ligne dans une table journalière dédiée.

---

## Principe de calcul

### Inflow

Source :

```text
exchange_observed_utxos.seen_day
```

Agrégations :

* somme de `value_btc`
* nombre de lignes

---

### Outflow

Source :

```text
exchange_observed_utxos.spent_day
```

Agrégations :

* somme de `value_btc`
* nombre de lignes

---

### Netflow

Calcul :

```text
inflow_btc - outflow_btc
```

---

# Table cible

Table prévue :

```text
exchange_flow_days
```

Cette table stocke les agrégats journaliers.

---

## Colonnes proposées

| colonne            | description            |
| ------------------ | ---------------------- |
| day                | jour agrégé            |
| inflow_btc         | total BTC entrant      |
| outflow_btc        | total BTC sortant      |
| netflow_btc        | inflow - outflow       |
| inflow_utxo_count  | nombre d’UTXO entrants |
| outflow_utxo_count | nombre d’UTXO sortants |
| computed_at        | date de calcul         |
| created_at         | timestamp Rails        |
| updated_at         | timestamp Rails        |

---

## Clé logique

Une ligne par jour :

```text
day
```

La table doit donc avoir une unicité sur `day`.

---

# Mode de calcul

La V1 peut supporter deux modes.

## 1. Build d’un jour précis

Exemple :

```text
InflowOutflowBuilder.call(day: Date.yesterday)
```

Utilisation :

* cron journalier
* recalcul ciblé
* correction ponctuelle

---

## 2. Rebuild d’une fenêtre

Exemple :

```text
InflowOutflowBuilder.call(days_back: 30)
```

Utilisation :

* initialisation
* recalcul historique
* validation des chiffres

---

# Stratégie de persistance

La table `exchange_flow_days` doit être mise à jour de manière idempotente.

Cela signifie :

* si le jour existe déjà, il est mis à jour
* sinon, il est créé

La persistance peut utiliser :

* `find_or_initialize_by(day: ...)`
* ou `upsert_all` si on batch plusieurs jours

Pour la V1, un upsert par jour est suffisant.

---

# Données dérivées possibles

La V1 se concentre sur les flux bruts.

Mais l’architecture permet déjà d’ajouter plus tard :

* moyenne mobile 7 jours
* moyenne mobile 30 jours
* ratio inflow/outflow
* z-score
* anomalie vs historique
* variation jour/jour

Ces données peuvent rester soit :

* calculées à la volée dans la vue
* soit persistées plus tard dans une V2

---

# Dépendances

Le module dépend de :

## Tables amont

* `exchange_observed_utxos`

## Infrastructure

* PostgreSQL / SQLite selon environnement
* Rails ActiveRecord

## Modules liés

* `exchange_like`

Il ne dépend pas directement de :

* `WhaleAlert`
* APIs externes
* market data

---

# Fréquence d’exécution

Le module peut être exécuté :

* quotidiennement pour calculer `J`
* ou plus fréquemment si une vue quasi temps réel est souhaitée

Pour la V1, une exécution :

```text
1 fois / heure
```

ou

```text
1 fois / jour
```

est suffisante selon le niveau de fraîcheur souhaité.

---

# Cron

Script prévu :

```text
bin/cron_inflow_outflow_build.sh
```

Job prévu :

```text
InflowOutflowBuildJob
```

La V1 doit privilégier :

* un job simple
* un log clair
* un suivi via `JobRun`

---

# Supervision

Le module doit être supervisable via :

* `JobRun`
* `/system`

Les informations minimales à exposer sont :

* dernier run
* statut
* durée
* dernier jour calculé

---

# Résilience

Le module `inflow_outflow` est résilient par nature car :

* il ne dépend pas du scan en temps réel direct
* il relit une table déjà persistée (`exchange_observed_utxos`)
* un recalcul d’un jour ou d’une fenêtre est toujours possible

En cas de crash ou de reboot :

* aucun état blockchain intermédiaire n’est perdu dans ce module
* un rebuild peut corriger les agrégats

---

# Performances

Le module est peu coûteux par rapport au scanner blockchain.

La charge dépend principalement de :

* la taille de `exchange_observed_utxos`
* les index sur `seen_day`
* les index sur `spent_day`

Comme ces index existent déjà, la V1 doit rester rapide.

---

# Index utiles

Pour de bonnes performances, la table source doit disposer au minimum de :

* index sur `seen_day`
* index sur `spent_day`

La table cible `exchange_flow_days` devra avoir :

* index unique sur `day`

---

# Limites V1

La V1 reste volontairement simple.

Limitations :

* agrégation journalière uniquement
* pas encore de segmentation par type d’adresse
* pas encore de cluster exchange
* pas encore d’indicateur avancé
* interprétation marché minimale

---

# Évolutions naturelles V2

Le module pourra ensuite évoluer vers :

* `Exchange Pressure Index`
* `Inflow / Outflow ratio`
* détection d’anomalies
* comparatif 7j / 30j
* heatmaps temporelles
* segmentation par adresses très actives
* séparation hot / cold wallets
* agrégation horaire

---

# Conclusion

Le module `inflow_outflow` V1 constitue la première couche d’interprétation
marché au-dessus de `exchange_like`.

Il transforme des événements unitaires on-chain (`seen` / `spent`) en
séries journalières lisibles et exploitables.

En résumé :

```text
exchange_like produit les événements
inflow_outflow produit les flux
```