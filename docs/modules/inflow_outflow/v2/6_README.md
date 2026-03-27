
# Inflow / Outflow — V2

Le module **Inflow / Outflow V2** enrichit l’analyse des flux vers les
adresses `exchange-like`.

Alors que la V1 mesure simplement les volumes :

- inflow BTC
- outflow BTC
- netflow BTC

la **V2 analyse la structure des dépôts entrants**.

---

# Objectif

Comprendre **comment les BTC arrivent sur les exchanges**, pas seulement
combien.

Deux inflows identiques peuvent avoir des significations très différentes :

```

10 000 BTC inflow

```

peut provenir de :

```

2 gros dépôts
ou
20 000 petits dépôts

```

La V2 permet de distinguer ces situations.

---

# Ce que mesure la V2

Pour chaque jour, la V2 calcule :

### Statistiques de dépôts

- `deposit_count`
- `avg_deposit_btc`
- `max_deposit_btc`

Cela permet d’évaluer :

```

activité retail
activité institutionnelle

```

---

# Buckets de taille des dépôts

Les dépôts sont répartis par taille.

Buckets utilisés :

```

< 1 BTC
1 – 10 BTC
10 – 100 BTC
100 – 500 BTC

> 500 BTC

```

Pour chaque bucket la V2 calcule :

- volume BTC
- nombre de dépôts

Exemple :

```

<1 BTC        15 000 dépôts
1–10 BTC       4 200 dépôts
10–100 BTC       350 dépôts
100–500 BTC       20 dépôts

> 500 BTC           3 dépôts

```

---

# Source des données

Le module repose sur :

```

exchange_observed_utxos

```

Chaque ligne représente un UTXO observé sur une adresse classée
`exchange-like`.

Pour les inflows, la V2 utilise :

```

seen_day

```

Cela correspond au moment où l’UTXO apparaît sur une adresse
d’exchange.

---

# Architecture

La V2 ajoute une nouvelle table :

```

exchange_flow_day_details

```

Relation avec la V1 :

```

exchange_flow_days
└ volume journalier

exchange_flow_day_details
└ structure des dépôts

```

Les deux tables sont complémentaires.

---

# Builder

Le calcul est réalisé par :

```

InflowOutflowDetailsBuilder

```

Fonctionnement :

```

1 lire exchange_observed_utxos
2 filtrer seen_day
3 calculer statistiques
4 calculer buckets
5 enregistrer dans exchange_flow_day_details

````

---

# Modes d'exécution

Calcul d’un jour :

```ruby
InflowOutflowDetailsBuilder.call(day: Date.yesterday)
````

Rebuild historique :

```ruby
InflowOutflowDetailsBuilder.call(days_back: 30)
```

---

# Job

Le module possède un job dédié :

```
InflowOutflowDetailsBuildJob
```

Supervisé par :

```
JobRun
```

Ce job peut être exécuté via cron.

---

# Vue dans Bitcoin Monitor

La V2 enrichit la page :

```
/inflow_outflow
```

La page peut afficher :

* statistiques des dépôts
* plus gros dépôt du jour
* composition des buckets
* évolution des dépôts

---

# Interprétation

Quelques exemples de lecture :

### Inflow retail

```
beaucoup de dépôts < 1 BTC
taille moyenne faible
```

Peut indiquer :

```
activité retail
pression vendeuse diffuse
```

---

### Inflow whale

```
peu de dépôts
mais très gros volumes
```

Peut indiquer :

```
activité institutionnelle
mouvements stratégiques
```

---

# Limites actuelles

La V2 ne permet pas encore de savoir :

```
qui dépose exactement
```

Elle décrit **la structure des dépôts**, pas l’identité des acteurs.

Les analyses plus avancées seront introduites dans les versions futures.

---

# Roadmap

Évolutions possibles :

```
V3 = interprétation des flux
```

Exemples :

* score retail / whale
* score de pression de vente
* détection de dépôts institutionnels
* alertes intelligentes

---

# Résumé

```
V1 = combien de BTC entrent ou sortent
V2 = comment ces BTC arrivent sur les exchanges
```

La V2 transforme le module `inflow_outflow` en **outil d’analyse
structurelle des dépôts vers les exchanges**, fournissant des
informations utiles pour comprendre le comportement du marché.

