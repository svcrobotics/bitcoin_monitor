
# Inflow / Outflow — V1 — Decisions

Ce document liste les décisions d’architecture prises pour le module
`inflow_outflow`.

L’objectif est de garder une trace claire des choix faits lors de la
conception de la V1.

---

# Décision 1 — Ne pas rescanner la blockchain

Le module `inflow_outflow` **ne scanne pas la blockchain directement**.

Il s’appuie uniquement sur les données produites par le module
`exchange_like`.

Source utilisée :

```

exchange_observed_utxos

```

Raisons :

- éviter la duplication de logique RPC
- réduire la charge de scan blockchain
- réutiliser l’infrastructure déjà en place

Pipeline retenu :

```

Blockchain
↓
exchange_like (scan)
↓
exchange_observed_utxos
↓
inflow_outflow (agrégation)

```

---

# Décision 2 — Agrégation journalière

Les flux sont agrégés **par jour**.

Granularité retenue :

```

1 ligne = 1 jour

```

Exemple :

| day | inflow_btc | outflow_btc |
|-----|-----------|-------------|
2026-03-01 | 5320 | 4100

Raisons :

- simplifier la visualisation
- limiter le volume de données
- suffisant pour les indicateurs macro

Granularités possibles dans le futur :

- hourly
- block-level
- rolling windows

---

# Décision 3 — Source des inflows

Les inflows sont calculés depuis :

```

exchange_observed_utxos.seen_day

```

Règle :

```

inflow = somme(value_btc) des UTXO observés ce jour

```

Interprétation :

UTXO reçus par une adresse exchange-like.

Cela correspond généralement à :

- dépôts utilisateurs
- transferts vers exchanges
- mouvements internes d'infrastructure

---

# Décision 4 — Source des outflows

Les outflows sont calculés depuis :

```

exchange_observed_utxos.spent_day

```

Règle :

```

outflow = somme(value_btc) des UTXO dépensés ce jour

```

Interprétation :

UTXO quittant une adresse exchange-like.

Cela correspond généralement à :

- retraits utilisateurs
- sorties vers cold wallets
- transferts vers d’autres plateformes

---

# Décision 5 — Netflow simple

Le netflow est défini comme :

```

netflow = inflow_btc - outflow_btc

```

Interprétation simple :

| netflow | lecture possible |
|--------|------------------|
positif | BTC entrant vers exchanges |
négatif | BTC sortant des exchanges |

La V1 ne fait **aucune interprétation automatique**.

Bitcoin Monitor reste neutre.

---

# Décision 6 — Table dédiée

Les agrégats sont stockés dans une table dédiée :

```

exchange_flow_days

```

Raisons :

- éviter recalculs répétés
- accélérer les dashboards
- simplifier les requêtes

Structure :

```

day
inflow_btc
outflow_btc
netflow_btc
inflow_utxo_count
outflow_utxo_count
computed_at

```

---

# Décision 7 — Calcul idempotent

Le builder doit être **idempotent**.

Cela signifie :

- recalculer un jour ne crée pas de doublons
- une ligne par jour

Implémentation :

```

upsert sur day

```

---

# Décision 8 — Mode rebuild

Le module supporte un mode rebuild :

```

InflowOutflowBuilder.call(days_back: 30)

```

Utilisation :

- initialisation du module
- recalcul historique
- correction de bugs

---

# Décision 9 — Job séparé

Le calcul est exécuté via un job Rails :

```

InflowOutflowBuildJob

```

Avantages :

- traçabilité via `JobRun`
- intégration avec cron
- possibilité de backfill contrôlé

---

# Décision 10 — Découplage des modules

Le module `inflow_outflow` reste volontairement séparé de :

- `exchange_like`
- `true_flow`
- `whale_alerts`

Raisons :

- séparation des responsabilités
- architecture modulaire
- facilité de maintenance

---

# Décision 11 — Neutralité d'interprétation

Bitcoin Monitor **ne donne pas de conseil financier**.

Les flux sont fournis comme **données brutes**.

L’interprétation appartient à l’utilisateur.

Principe appliqué :

```

data first
interpretation later

```

---

# Décision 12 — Module conçu pour évoluer

La V1 constitue une base.

Les versions futures pourront ajouter :

- ratios inflow/outflow
- indicateurs de pression exchange
- anomalies de flux
- segmentation par type d’adresse
- modèles statistiques

Ces fonctionnalités feront l’objet de versions ultérieures.

Exactement 👍
Chaque fois qu’on modifie **le comportement fonctionnel d’un module**, il faut laisser une trace dans la doc.
Dans ton cas, ce n’est **ni une amélioration future** ni **une tâche**, c’est une **décision d’architecture**.

Donc la bonne place est :

```text
docs/modules/inflow_outflow/v1/DECISIONS.md
```

---

## Décision — Recalcul du jour courant

Le builder `InflowOutflowBuilder` ne calcule pas uniquement les flux du jour précédent.

Il recalcule systématiquement :

- `Date.yesterday`
- `Date.current`

### Raison

Les UTXOs observés peuvent être écrits dans `exchange_observed_utxos`
avec un léger retard dû :

- au scanner blockchain
- à l’ordre d’exécution des jobs
- aux blocs arrivant pendant le calcul

Recalculer `Date.yesterday` permet donc de corriger
les agrégats si des événements tardifs apparaissent.

### Mise à jour intra-journalière

Le calcul de `Date.current` permet d’afficher une estimation
du flux en cours de journée.

Cela permet à la page `inflow_outflow` d’évoluer pendant la journée
et d’offrir une lecture quasi temps réel des flux vers les exchanges.

### Conséquence interface

Lorsque `day == Date.current`,
la vue indique explicitement :

```

journée en cours

````

afin de signaler que les valeurs ne représentent
pas encore une journée complète.

### Résumé

```text
builder default mode :

calculate:
- yesterday
- today
````

---

# Pourquoi c’est important de documenter ça

Dans 6 mois, quelqu’un (toi 😄) pourrait se demander :

```text
pourquoi le builder recalcul hier et aujourd'hui ?
````

Sans la doc, ça ressemble à du code étrange.

Avec la doc, c’est clair :

```text
c'est volontaire pour absorber les retards de scan
et fournir un flux quasi temps réel
```

