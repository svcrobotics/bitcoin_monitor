
# Inflow / Outflow — V2 — Decisions

Ce document liste les décisions d’architecture prises pour la V2 du module
`inflow_outflow`.

La V1 calcule les flux journaliers simples :

- inflow BTC
- outflow BTC
- netflow BTC

La V2 enrichit l’analyse des inflows en décrivant leur composition.

---

# Décision 1 — La V2 enrichit la V1 sans la remplacer

La V2 ne remplace pas `exchange_flow_days`.

Elle ajoute une couche complémentaire de lecture des dépôts.

Principe retenu :

```text
V1 = volume journalier
V2 = composition du volume entrant
````

Conséquence :

* la V1 reste simple, stable et lisible
* la V2 porte les métriques plus riches
* la montée en gamme produit devient possible

---

# Décision 2 — Créer une table dédiée V2

Les statistiques enrichies sont stockées dans une table distincte :

```text
exchange_flow_day_details
```

Pourquoi :

* éviter d’alourdir `exchange_flow_days`
* garder la V1 stable
* faire évoluer la V2 sans casser la V1
* préparer une séparation claire V1 / V2 / V3 dans l’interface

Conséquence :

```text
exchange_flow_days         = agrégats simples
exchange_flow_day_details  = enrichissements V2
```

---

# Décision 3 — La V2 se concentre d’abord sur l’inflow

La V2 analyse prioritairement la structure des dépôts entrants.

Pourquoi :

* un inflow élevé peut avoir des significations très différentes
* il est utile de distinguer un inflow retail diffus d’un inflow concentré whale
* la lecture marché est souvent plus riche côté dépôts que côté volume brut

Exemple :

```text
10 000 BTC
```

peut signifier :

* 2 gros dépôts
* ou 20 000 petits dépôts

Ce ne sont pas les mêmes signaux.

---

# Décision 4 — Chaque ligne `seen_day` est traitée comme un dépôt observé

La V2 se base sur :

```text
exchange_observed_utxos.where(seen_day: day)
```

Chaque ligne est traitée comme un dépôt élémentaire observé sur une adresse
`exchange-like`.

Pourquoi :

* simplicité
* cohérence avec la V1
* coût faible
* pas de rescanning blockchain

Limite assumée :

* cela ne permet pas encore d’identifier la source réelle du dépôt
* cela ne résout pas les cas complexes multi-input / multi-output

---

# Décision 5 — Segmentation par buckets de taille

La V2 segmente les dépôts par taille.

Buckets retenus :

* `< 1 BTC`
* `1 – 10 BTC`
* `10 – 100 BTC`
* `100 – 500 BTC`
* `> 500 BTC`

Pourquoi :

* lecture simple
* séparation naturelle retail / gros déposants
* utile pour l’analyse marché
* facilement visualisable

Conséquence :

la V2 calcule pour chaque jour :

* volume BTC par bucket
* nombre de dépôts par bucket

---

# Décision 6 — Calculer des statistiques simples avant toute intelligence avancée

La V2 calcule d’abord :

* `deposit_count`
* `avg_deposit_btc`
* `max_deposit_btc`

Pourquoi :

* très forte valeur analytique
* implémentation simple
* peu coûteux
* facile à expliquer à l’utilisateur

Les métriques plus complexes comme :

* médiane
* concentration score
* whale score

sont reportées à plus tard.

---

# Décision 7 — La V2 reste indépendante d’une identité source

La V2 ne cherche pas encore à répondre à :

```text
qui dépose exactement ?
```

Pourquoi :

* question complexe on-chain
* risque d’interprétation abusive
* besoin futur de clustering et heuristiques de source

La V2 répond plutôt à :

```text
comment l’inflow est composé ?
```

Conséquence :

* lecture structurelle
* pas encore lecture identitaire

---

# Décision 8 — La V2 conserve les modes `day:` et `days_back:`

Comme la V1, la V2 doit supporter :

* calcul d’un jour précis
* rebuild d’une période

Pourquoi :

* cohérence de l’architecture
* facilité de test
* simplicité d’exploitation
* correction possible après évolution du scanner

---

# Décision 9 — La V2 recalcule par défaut hier + aujourd’hui

Le builder V2 doit recalculer par défaut :

* `Date.yesterday`
* `Date.current`

Pourquoi :

* absorber les éventuels retards d’écriture amont
* garder une vue vivante en journée
* alignement avec la V1 enrichie

Conséquence UI :

si `day == Date.current`, la vue doit afficher clairement :

```text
journée en cours
```

---

# Décision 10 — Job et cron séparés

La V2 utilise :

* un job dédié
* un cron dédié

Pourquoi :

* supervision fine dans `JobRun`
* isolation des erreurs
* meilleure lisibilité dans `/system`

Conséquence :

la V2 ne doit pas être cachée dans le job V1.

---

# Décision 11 — La V2 doit être visible dans `/system`

Le module V2 doit apparaître dans la supervision via :

* le job `inflow_outflow_details_build`
* la table `exchange_flow_day_details`

Pourquoi :

* éviter les modules silencieux
* supervision claire
* cohérence avec le reste de Bitcoin Monitor

---

# Décision 12 — La V2 prépare une montée en gamme produit

La V2 est conçue pour pouvoir être exposée comme niveau premium.

Approche retenue :

* une même page `inflow_outflow`
* V1 visible simplement
* V2 déverrouillable
* V3 encore plus avancée plus tard

Pourquoi :

* meilleure UX qu’une multiplication des pages
* meilleure base commerciale
* architecture plus propre

---

# Décision 13 — La V2 reste neutre dans l’interprétation

Comme la V1, la V2 fournit des données et des structures de flux, mais ne transforme
pas encore cela en signal automatique de trading.

Pourquoi :

* préserver la neutralité de Bitcoin Monitor
* éviter la surinterprétation
* laisser la V3 ou d’autres modules calculer des scores dérivés

Exemple :

la V2 peut montrer :

* dépôts > 500 BTC
* gros dépôt du jour
* volume concentré

mais ne conclut pas automatiquement :

```text
vente imminente
```

---

# Décision 14 — Les indicateurs avancés sont reportés à la V3

Sont explicitement repoussés :

* clustering source
* score retail / whale
* score de concentration
* détection de transfert interne
* qualification institutionnelle
* alertes intelligentes

Pourquoi :

* garder la V2 simple
* livrer vite une vraie valeur
* éviter une explosion de complexité trop tôt

---

# Conclusion

La V2 du module `inflow_outflow` a pour but d’ajouter une lecture structurelle
des dépôts entrants.

En résumé :

```text
V1 = combien entre / sort
V2 = comment les dépôts entrants sont composés
```

Cette décision transforme le module d’un simple agrégateur de flux en
véritable outil d’analyse on-chain exploitable pour Bitcoin Monitor.

