
# Inflow / Outflow — V1

Le module `inflow_outflow` calcule les flux entrants et sortants des adresses
`exchange-like`.

Il s’appuie directement sur les données produites par le module `exchange_like`
et transforme les événements unitaires observés sur la blockchain en séries
de flux journaliers.

Ce module constitue la première couche d’interprétation du comportement
des exchanges dans Bitcoin Monitor.

---

# Objectif

L’objectif du module est de reconstruire les flux suivants :

- BTC entrant vers les exchanges
- BTC sortant des exchanges
- solde net des flux

Ces flux permettent de mesurer l’activité exchange et de produire
des indicateurs utiles pour l’analyse du marché.

---

# Position dans l’architecture

Le module `inflow_outflow` se situe au-dessus de `exchange_like`.

Pipeline global :

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
InflowOutflowBuilder
        ↓
exchange_flow_days
````

Le module ne lit pas directement la blockchain.

Il exploite la table :

```text
exchange_observed_utxos
```

qui contient déjà les événements nécessaires.

---

# Définitions

## Inflow

Un inflow correspond à un UTXO reçu par une adresse exchange-like.

Formellement :

```text
inflow(day) = somme(value_btc) où seen_day = day
```

Cela correspond généralement à :

* dépôts d’utilisateurs
* transferts vers exchanges
* mouvements entrants d’infrastructure

---

## Outflow

Un outflow correspond à un UTXO dépensé depuis une adresse exchange-like.

Formellement :

```text
outflow(day) = somme(value_btc) où spent_day = day
```

Cela correspond généralement à :

* retraits utilisateurs
* transferts internes
* sorties vers d’autres plateformes

---

## Netflow

Le netflow représente la différence entre flux entrants et sortants.

Formule :

```text
netflow = inflow - outflow
```

Interprétation simple :

| netflow | lecture possible                           |
| ------- | ------------------------------------------ |
| positif | davantage de BTC entrent sur les exchanges |
| négatif | davantage de BTC sortent des exchanges     |

---

# Table produite

Le module écrit ses résultats dans la table :

```text
exchange_flow_days
```

Chaque ligne représente un agrégat journalier.

Exemple :

| day        | inflow_btc | outflow_btc | netflow_btc |
| ---------- | ---------- | ----------- | ----------- |
| 2026-03-01 | 5320       | 4100        | 1220        |
| 2026-03-02 | 3100       | 5200        | -2100       |

---

# Données calculées

Pour chaque jour :

* inflow_btc
* outflow_btc
* netflow_btc
* inflow_utxo_count
* outflow_utxo_count

Ces données peuvent ensuite être utilisées dans :

* dashboards
* graphiques
* indicateurs de marché

---

# Composants principaux

Le module repose sur un service principal :

```text
InflowOutflowBuilder
```

Responsabilités :

* lire `exchange_observed_utxos`
* agréger les flux par jour
* écrire dans `exchange_flow_days`

---

# Modes d’exécution

Le builder peut fonctionner de deux façons.

## Calcul d’un jour

Exemple :

```ruby
InflowOutflowBuilder.call(day: Date.yesterday)
```

Utilisation :

* cron journalier
* recalcul ponctuel

---

## Rebuild d’une période

Exemple :

```ruby
InflowOutflowBuilder.call(days_back: 30)
```

Utilisation :

* initialisation du module
* recalcul historique

---

# Dépendances

Le module dépend uniquement de :

```text
exchange_like
```

et plus précisément de la table :

```text
exchange_observed_utxos
```

Il ne dépend pas :

* d’APIs externes
* de données de marché
* d’oracles

---

# Interprétation des flux

Les flux exchange peuvent fournir des signaux utiles.

### Inflow élevé

Possibles interprétations :

* dépôts massifs
* préparation à vendre
* activité exchange accrue

### Outflow élevé

Possibles interprétations :

* accumulation
* retrait vers self-custody
* réduction de la pression vendeuse

Ces interprétations restent contextuelles et doivent être combinées
avec d’autres indicateurs.

---

# Limites V1

La V1 reste volontairement simple.

Limitations :

* agrégation journalière uniquement
* pas de segmentation par exchange
* pas de clustering d’adresses
* pas d’indicateur avancé
* pas d’analyse comportementale

---

# Évolutions possibles

Les versions futures pourront ajouter :

* ratio inflow / outflow
* indicateur Exchange Pressure
* moyenne mobile
* z-score des flux
* détection d’anomalies
* segmentation des adresses

---

# Conclusion

Le module `inflow_outflow` transforme les événements observés
sur les adresses exchange-like en flux journaliers exploitables.

Il constitue la première couche d’analyse marché basée sur
l’infrastructure `exchange_like`.

En résumé :

```text
exchange_like détecte et observe
inflow_outflow agrège et interprète
```

