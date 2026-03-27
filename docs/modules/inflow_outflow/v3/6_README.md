
# Inflow / Outflow — V3

La **V3 du module `inflow_outflow`** introduit une **analyse comportementale des flux vers et depuis les exchanges**.

Elle s’appuie sur les versions précédentes :

```text
V1 = volume des flux
V2 = structure des flux
V3 = comportement des flux
```

Objectif :

transformer les données on-chain en **indicateurs de comportement du marché**.

---

# Rappel des versions

## V1 — Volume

La V1 calcule les flux globaux vers les exchanges.

Indicateurs :

* inflow BTC
* outflow BTC
* netflow BTC

Exemple :

```text
Inflow : 12 000 BTC
Outflow : 9 000 BTC
Netflow : +3 000 BTC
```

Lecture possible :

```text
pression vendeuse potentielle
```

Mais la V1 ne dit pas **qui agit**.

---

## V2 — Structure

La V2 décrit **la composition des flux**.

Elle analyse :

* le nombre de dépôts
* la taille moyenne
* le plus gros dépôt
* la répartition par taille

Buckets utilisés :

```text
< 1 BTC
1 – 10 BTC
10 – 100 BTC
100 – 500 BTC
> 500 BTC
```

Cela permet de distinguer :

* petits dépôts
* gros dépôts
* dépôts institutionnels probables

Mais la V2 ne produit pas encore d’interprétation comportementale.

---

# V3 — Comportement du marché

La V3 transforme les données V1 et V2 en **indicateurs comportementaux**.

Elle cherche à répondre à des questions comme :

* les dépôts sont-ils majoritairement retail ?
* les dépôts sont-ils dominés par des whales ?
* observe-t-on une forte concentration ?
* observe-t-on une activité compatible avec une distribution ?
* observe-t-on une accumulation hors exchanges ?

La V3 ne prétend pas prédire le marché.

Elle fournit **des indices comportementaux**.

---

# Indicateurs V3

La V3 calcule plusieurs types d’indicateurs.

---

## Ratios d’activité

### Retail ratio

Part des flux attribuables à de petits acteurs.

Définition :

```text
retail = <1 BTC + 1–10 BTC
```

Mesures :

```text
retail_deposit_ratio
retail_deposit_volume_ratio
```

---

### Whale ratio

Part des flux attribuables à de gros acteurs.

Définition :

```text
whale = 10–100 BTC + 100–500 BTC
```

Mesures :

```text
whale_deposit_ratio
whale_deposit_volume_ratio
```

---

### Institutional ratio

Activité compatible avec des institutions.

Définition :

```text
> 500 BTC
```

Mesures :

```text
institutional_deposit_ratio
institutional_deposit_volume_ratio
```

Important :

cela reste **une estimation comportementale**.

---

# Ratios retraits

Les mêmes ratios sont calculés côté retraits :

```text
retail_withdrawal_ratio
whale_withdrawal_ratio
institutional_withdrawal_ratio
```

Ces ratios permettent d’observer :

* accumulation hors exchanges
* retraits importants

---

# Scores comportementaux

La V3 introduit également plusieurs scores.

---

## Deposit concentration score

Mesure si les dépôts sont dominés par quelques grosses transactions.

Un score élevé suggère :

```text
activité concentrée
```

---

## Withdrawal concentration score

Même logique côté retraits.

Permet d’identifier :

```text
retraits importants concentrés
```

---

## Distribution score

Mesure une pression de distribution potentielle.

Situation typique :

```text
inflow élevé
+
dépôts whales
+
forte concentration
```

Interprétation possible :

```text
acteurs importants envoyant des BTC vers les exchanges
```

Mais ce n’est **pas une preuve de vente**.

---

## Accumulation score

Mesure une accumulation potentielle hors exchanges.

Situation typique :

```text
outflow élevé
+
retraits whales
+
forte concentration
```

Interprétation possible :

```text
acteurs importants retirant des BTC des exchanges
```

---

## Behavior score

Score synthétique du comportement du marché.

Exemple :

```text
Behavior score : 63 / 100
```

Ce score résume :

* structure des flux
* ratios d’acteurs
* concentration
* balance inflow / outflow

---

# Architecture technique

Pipeline complet :

```text
Bitcoin blockchain
        ↓
exchange_addresses
        ↓
exchange_observed_utxos
        ↓
V1 → exchange_flow_days
        ↓
V2 → exchange_flow_day_details
        ↓
V3 → exchange_flow_day_behavior
```

La V3 dépend uniquement de :

```text
exchange_flow_days
exchange_flow_day_details
```

Elle ne lit pas directement les UTXO bruts.

---

# Table V3

Les indicateurs V3 sont stockés dans :

```text
exchange_flow_day_behavior
```

Une ligne par jour.

Contenu :

* ratios retail / whale / institution
* ratios volume
* scores comportementaux

---

# Fréquence de calcul

Le builder V3 peut être exécuté :

```text
toutes les heures
```

Ordonnancement recommandé :

```text
exchange_observed_scan
↓
inflow_outflow_build
↓
inflow_outflow_details_build
↓
inflow_outflow_behavior_build
```

---

# Interprétation prudente

La V3 fournit des **indices comportementaux**.

Elle ne permet pas de :

* identifier un acteur réel
* confirmer une vente
* prédire un mouvement de prix

Les indicateurs doivent être interprétés avec prudence.

Bitcoin Monitor adopte une approche :

```text
data first
interpretation second
```

---

# Objectif de la V3

La V3 rapproche Bitcoin Monitor des outils d’analyse on-chain professionnels.

Elle permet de passer de :

```text
flux bruts
```

à :

```text
lecture comportementale du marché
```

Cette couche constitue une base pour des modules futurs :

* alertes comportementales
* détection de distribution
* détection d’accumulation
* analyse de cycle de marché.

