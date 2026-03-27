
# Inflow / Outflow — V3 — Decisions

Ce document décrit les **décisions de conception** prises pour la V3 du module `inflow_outflow`.

La V3 introduit une **analyse comportementale des flux exchange-like**.

Elle s’appuie sur :

* V1 → volume des flux
* V2 → structure des flux
* V3 → interprétation comportementale

```text
V1 = volume
V2 = structure
V3 = comportement
```

La V3 ne modifie pas les tables V1 ou V2.
Elle ajoute une **nouvelle couche analytique indépendante**.

---

# Décision 1 — Table dédiée V3

La V3 utilise une table séparée :

```text
exchange_flow_day_behavior
```

Objectif :

* isoler les **scores comportementaux**
* éviter de polluer les tables V1/V2
* permettre d’améliorer les heuristiques sans casser les données existantes

Architecture finale :

```text
exchange_flow_days
    ↓
exchange_flow_day_details
    ↓
exchange_flow_day_behavior
```

---

# Décision 2 — La V3 repose sur V1 et V2

La V3 ne lit **pas directement** `exchange_observed_utxos`.

Elle utilise :

```text
exchange_flow_days
exchange_flow_day_details
```

Raisons :

1. simplifier le calcul
2. réduire la charge
3. découpler les couches

Pipeline :

```text
exchange_observed_utxos
        ↓
V1 volume
        ↓
V2 structure
        ↓
V3 comportement
```

---

# Décision 3 — Définition des catégories d’acteurs

La V3 ne peut pas identifier une entité réelle.

Elle utilise donc une **classification heuristique basée sur la taille des flux**.

Buckets issus de la V2.

### Retail

```text
< 1 BTC
1 – 10 BTC
```

Hypothèse :

* petits utilisateurs
* dépôts individuels
* activité retail probable

---

### Whale

```text
10 – 100 BTC
100 – 500 BTC
```

Hypothèse :

* acteurs importants
* traders professionnels
* desks OTC
* fonds crypto

---

### Institutional estimé

```text
> 500 BTC
```

Hypothèse :

* institution
* fonds
* market maker
* exchange interne

Important :

la V3 ne prétend **pas identifier une institution réelle**.

Elle signale uniquement :

```text
activité compatible avec des acteurs institutionnels
```

---

# Décision 4 — Distinction volume / count

Chaque ratio existe en deux variantes :

### ratio count

mesure la part **en nombre de transactions**

exemple :

```text
retail_deposit_ratio
```

### ratio volume

mesure la part **en BTC**

exemple :

```text
retail_deposit_volume_ratio
```

Raison :

un seul gros dépôt peut représenter :

* peu d’opérations
* beaucoup de volume

Les deux lectures sont nécessaires.

---

# Décision 5 — Scores simples et explicables

Les scores V3 doivent rester :

* simples
* transparents
* reproductibles

Bitcoin Monitor doit éviter les scores “boîte noire”.

Exemples :

```text
distribution_score
accumulation_score
behavior_score
```

Les formules restent documentées et modifiables.

---

# Décision 6 — Score de concentration

La V3 introduit un **score de concentration**.

Objectif :

mesurer si les flux sont :

```text
diffus
ou
concentrés
```

Approche V3 simple :

forte concentration si le volume est dominé par :

```text
100–500 BTC
>500 BTC
```

Des approches plus avancées sont prévues plus tard :

* top deposits share
* top withdrawals share
* Gini-like score

---

# Décision 7 — Distribution vs Accumulation

Deux scores comportementaux principaux sont introduits.

### Distribution score

Situation typique :

```text
inflow élevé
+
whale deposits élevés
+
concentration élevée
```

Interprétation possible :

```text
pression vendeuse potentielle
```

Mais la V3 **ne conclut pas à une vente certaine**.

---

### Accumulation score

Situation typique :

```text
outflow élevé
+
gros retraits
+
concentration élevée
```

Interprétation possible :

```text
accumulation probable hors exchange
```

---

# Décision 8 — Behavior score synthétique

La V3 propose un score global :

```text
behavior_score
```

Objectif :

résumer le comportement du jour.

Exemple :

```text
Behavior score : 63 / 100
```

Ce score peut intégrer :

* ratios retail
* ratios whale
* concentration
* balance inflow/outflow

Le détail reste visible pour éviter l’effet “boîte noire”.

---

# Décision 9 — Neutralité analytique

Bitcoin Monitor doit rester **neutre**.

Les scores ne doivent pas être présentés comme :

```text
signal de trading
```

mais comme :

```text
indicateur d'observation on-chain
```

Exemple de formulation acceptable :

```text
Distribution pressure elevated
```

Exemple à éviter :

```text
Market will fall
```

---

# Décision 10 — Calcul idempotent

La V3 suit la même logique que V1 et V2 :

* une seule ligne par jour
* recalcul possible
* idempotence

Index requis :

```text
unique index on day
```

---

# Décision 11 — Recalcul jour courant

Comme les V1 et V2, la V3 doit recalculer :

```text
Date.yesterday
Date.current
```

Objectif :

* absorber les retards de scan
* afficher une **journée en cours**

---

# Décision 12 — Fréquence de calcul

La V3 peut être exécutée :

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

# Décision 13 — Présentation UI prudente

La V3 introduit des indicateurs interprétatifs.

La présentation doit rester :

* sobre
* explicable
* prudente

Exemples :

```text
Retail activity elevated
Whale activity moderate
Institutional activity low
```

Pas de langage prédictif.

---

# Décision 14 — Séparation produit V1 / V2 / V3

L’architecture prépare une séparation produit future :

```text
V1 = gratuit
V2 = premium
V3 = premium avancé
```

La structure UI doit permettre cette séparation sans refactor majeur.

---

# Décision 15 — V3 comme base d’indicateurs avancés

La V3 constitue la base pour de futurs modules :

* behavioural alerts
* distribution detection
* accumulation detection
* cycle indicators
* panic retail detector

Ces modules pourront être ajoutés sans modifier les tables V1 ou V2.

---

# Conclusion

La V3 transforme des données de flux en **lecture comportementale du marché**.

Résumé de l’architecture :

```text
V1 → volume
V2 → structure
V3 → comportement
```

Cette couche rapproche Bitcoin Monitor d’un véritable moteur d’analyse on-chain comparable aux plateformes professionnelles.
