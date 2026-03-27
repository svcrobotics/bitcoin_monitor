
# Inflow / Outflow — V1 — Améliorations

Ce document liste les améliorations possibles du module `inflow_outflow`.

La V1 fournit une base stable :

- agrégation journalière
- inflow
- outflow
- netflow
- table persistée

Les améliorations ci-dessous visent à enrichir l’analyse.

---

# Amélioration 1 — Ratio inflow / outflow

Ajouter un indicateur simple :

```

ratio = inflow_btc / outflow_btc

```

Interprétation possible :

| ratio | lecture possible |
|------|------------------|
>1 | plus de BTC entrent que sortent |
<1 | plus de BTC sortent que rentrent |

Utilisation :

- indicateur rapide de pression exchange
- détection de périodes de stress

---

# Amélioration 2 — Moyennes mobiles

Ajouter des moyennes mobiles :

- MA7
- MA30
- MA90

Exemple :

```

MA7 inflow
MA7 outflow
MA7 netflow

```

Objectif :

- lisser la volatilité
- visualiser les tendances

---

# Amélioration 3 — Exchange Pressure Indicator

Créer un indicateur dérivé :

```

exchange_pressure = inflow_btc - outflow_btc

```

ou

```

exchange_pressure_ratio = inflow / outflow

```

Cet indicateur est très utilisé par les traders.

---

# Amélioration 4 — Z-score des flux

Calculer un Z-score des inflows :

```

z = (inflow_today - moyenne_30j) / ecart_type_30j

```

Permet :

- détecter les anomalies
- identifier les événements inhabituels

---

# Amélioration 5 — Détection d'anomalies

Identifier automatiquement :

- inflow exceptionnel
- outflow exceptionnel
- netflow extrême

Exemples :

```

inflow > 3 × moyenne 30j

```

Applications :

- alertes
- signaux de marché

---

# Amélioration 6 — Segmentation des flux

Segmenter les flux par taille de UTXO :

Exemple :

| catégorie | BTC |
|-----------|------|
small | < 1 BTC |
medium | 1–100 BTC |
large | > 100 BTC |

Objectif :

- distinguer retail vs whales
- comprendre l'origine des flux

---

# Amélioration 7 — Segmentation par type d'adresse

Différencier :

- hot wallets
- cold wallets
- clusters exchange

Cela nécessitera :

- un système de classification des adresses
- clustering heuristique

---

# Amélioration 8 — Flux intra-exchange

Identifier les transferts internes :

```

exchange → exchange

```

Ces flux peuvent fausser les analyses.

Solutions possibles :

- heuristiques de clustering
- exclusion des transferts internes

---

# Amélioration 9 — Granularité temporelle

Ajouter d'autres granularités :

- hourly
- block-level

Cela permettrait :

- une analyse haute fréquence
- la détection rapide d’événements.

---

# Amélioration 10 — Visualisation avancée

Améliorer la vue `inflow_outflow` :

Graphiques possibles :

- inflow / outflow stacked
- netflow histogram
- heatmap des flux
- comparaisons historiques

---

# Amélioration 11 — Corrélation avec le prix BTC

Comparer les flux avec :

```

btc_price_days

```

Exemples :

- netflow vs prix
- inflow spikes vs corrections
- outflow spikes vs accumulation

---

# Amélioration 12 — Indicateurs traders

Construire des indicateurs dérivés :

- Exchange Net Position Change
- Exchange Supply Ratio
- Inflow Momentum
- Exchange Liquidity Index

Ces indicateurs sont souvent utilisés dans les plateformes
d'analyse on-chain.

---

# Amélioration 13 — Score de pression vendeuse

Construire un score synthétique :

```

sell_pressure_score

```

Basé sur :

- inflow
- ratio inflow/outflow
- variation 7 jours

Objectif :

produire un indicateur simple à lire.

---

# Améliation 14 — Alertes automatiques

Créer un système d’alertes :

Exemples :

- inflow > 10 000 BTC
- netflow > 5 000 BTC
- ratio > 3

Utilisation :

- notifications
- tableau de surveillance

---

# Amélioration 15 — API interne

Exposer les flux via une API interne :

```

/api/exchange_flows

```

Permet :

- dashboards externes
- intégration mobile
- automatisation

---

# Conclusion

Le module `inflow_outflow` constitue une **brique fondamentale
d'analyse on-chain**.

La V1 fournit :

- un pipeline stable
- des flux journaliers
- une base exploitable

Les futures versions permettront d’ajouter :

- indicateurs avancés
- analyses statistiques
- signaux de marché.
