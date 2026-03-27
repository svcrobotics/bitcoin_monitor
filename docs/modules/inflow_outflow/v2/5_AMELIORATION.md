
# Inflow / Outflow — V2 — Améliorations futures

Ce document liste les améliorations possibles pour les versions futures
du module `inflow_outflow`.

La V2 introduit une analyse structurelle des dépôts entrants :

- nombre de dépôts
- taille moyenne
- plus gros dépôt
- répartition par buckets

Les améliorations suivantes visent à enrichir l'analyse tout en gardant
une architecture modulaire.

---

# 1 — Médiane des dépôts

La moyenne (`avg_deposit_btc`) peut être fortement influencée par
quelques dépôts très importants.

Une amélioration possible est d’ajouter :

```text
median_deposit_btc
````

Intérêt :

* meilleure lecture du comportement retail
* moins sensible aux whales
* indicateur statistique plus robuste

---

# 2 — Score de concentration des dépôts

Calculer un indicateur simple de concentration.

Exemple :

```text
top_5_deposits_btc / inflow_btc
```

ou

```text
top_10_share
```

Objectif :

identifier si l’inflow provient :

```text
- de quelques gros dépôts
- d’un grand nombre de petits dépôts
```

---

# 3 — Retail vs Whale Score

Créer un indicateur simple :

```text
retail_score
whale_score
```

Basé sur :

* proportion des dépôts < 1 BTC
* proportion des dépôts > 100 BTC
* concentration du volume

Exemple d’interprétation :

```text
Retail dominant
Mixed activity
Whale-heavy deposits
```

---

# 4 — Détection de dépôts institutionnels

Les institutions déposent souvent :

* des montants très élevés
* via peu de transactions
* sur un court intervalle de temps

Une heuristique possible :

```text
> 1000 BTC sur < 10 transactions
```

Sortie possible :

```text
possible_institutional_deposit
```

---

# 5 — Détection des transferts internes exchange

Une partie des flux peut correspondre à :

```text
reshuffle interne d'exchange
```

Objectif :

éviter d’interpréter ces flux comme des dépôts réels.

Approches possibles :

* analyse des patterns
* clusters d'adresses
* délais de dépense courts

---

# 6 — Analyse temporelle intra-day

La V2 est basée sur un agrégat journalier.

Une V3 pourrait analyser :

```text
flux par heure
```

Objectif :

détecter :

* événements rapides
* dépôts massifs soudains
* réactions de marché

---

# 7 — Détection de spikes d’inflow

Créer un indicateur :

```text
inflow_vs_30d_avg
```

Exemple :

```text
inflow_today / inflow_avg_30d
```

Permet d’identifier :

```text
inflow anormalement élevé
```

---

# 8 — Corrélation avec le prix BTC

Croiser les flux avec les données de prix :

```text
BTC price change
```

Objectif :

détecter des patterns :

```text
inflow spike → price drop
outflow spike → price rally
```

---

# 9 — Score de pression de vente

Créer un indicateur synthétique :

```text
sell_pressure_score
```

Basé sur :

* inflow BTC
* concentration des dépôts
* taille moyenne des dépôts

Objectif :

fournir un signal interprétable pour l'utilisateur.

---

# 10 — Alertes intelligentes

Créer des alertes automatiques :

Exemples :

```text
Whale deposit detected
Inflow spike detected
Large exchange inflow
```

Intégration possible :

* dashboard
* notifications
* log système

---

# 11 — Analyse multi-exchange

Si l’identification d’exchange devient plus précise,
il sera possible d’ajouter :

```text
inflow_by_exchange
```

Exemples :

```text
Binance inflow
Coinbase inflow
Kraken inflow
```

Cela permettrait :

* une lecture beaucoup plus fine du marché.

---

# 12 — Clustering des sources de dépôts

Objectif futur :

identifier les types de déposants.

Exemples :

```text
miner
institution
retail
exchange internal
```

Approche :

* heuristiques on-chain
* clustering
* analyse comportementale

---

# Conclusion

La V2 constitue une première étape vers une analyse structurelle
des flux vers les exchanges.

L'évolution naturelle du module est :

```text
V1 = volume de flux
V2 = composition des dépôts
V3 = interprétation des flux
```

Ces améliorations permettront progressivement de transformer
le module `inflow_outflow` en **véritable moteur d'analyse on-chain
du comportement des acteurs du marché**.

