
# Inflow / Outflow — V3 — Architecture

Ce document décrit l’architecture de la V3 du module `inflow_outflow`.

La progression du module est la suivante :

```text
V1 = volume
V2 = structure des flux
V3 = comportement des flux
````

La V1 calcule :

* inflow BTC
* outflow BTC
* netflow BTC

La V2 ajoute :

* structure des dépôts entrants
* structure des retraits sortants
* buckets par taille
* statistiques de taille moyenne et maximale

La V3 ajoute une couche d’interprétation comportementale.

Elle ne remplace pas les V1 et V2.
Elle s’appuie sur elles.

---

# Objectif de la V3

La V3 vise à répondre à des questions plus proches de l’analyse marché :

* les flux observés ressemblent-ils à une activité retail ?
* les flux observés ressemblent-ils à une activité whale ?
* observe-t-on une concentration forte des dépôts ?
* le comportement du jour ressemble-t-il plutôt à une phase de distribution ?
* ou à une phase d’accumulation ?

La V3 ne cherche pas encore à identifier une entité réelle.
Elle cherche à décrire un comportement observable.

En résumé :

```text
V1 = combien
V2 = comment les flux sont composés
V3 = quel comportement de marché ces flux suggèrent
```

---

# Position dans l’architecture

Le pipeline complet devient :

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
InflowOutflowDetailsBuilder V2
        ↓
exchange_flow_day_details
        ↓
InflowOutflowBehaviorBuilder V3
        ↓
exchange_flow_day_behavior
```

La V3 dépend donc de :

* `exchange_flow_days`
* `exchange_flow_day_details`

et indirectement de :

* `exchange_observed_utxos`

---

# Principe général

La V3 transforme des volumes et des buckets en métriques de comportement.

Exemples :

* part retail des dépôts
* part whale des dépôts
* part institutionnelle estimée
* score de concentration
* score de distribution
* score d’accumulation

La V3 reste fondée sur des heuristiques simples, explicables et transparentes.

---

# Concepts fonctionnels de la V3

## 1. Retail ratio

Mesure la part des petits flux dans le volume ou dans le nombre d’opérations.

Exemple simple :

```text
retail_deposit_ratio =
  (count < 1 BTC + count 1–10 BTC) / deposit_count
```

Version volume possible :

```text
retail_deposit_volume_ratio =
  (volume < 1 BTC + volume 1–10 BTC) / inflow_btc
```

Objectif :

identifier une dominante retail dans les dépôts.

---

## 2. Whale ratio

Mesure la part des gros flux.

Exemple simple :

```text
whale_deposit_ratio =
  (count 100–500 BTC + count >500 BTC) / deposit_count
```

Version volume possible :

```text
whale_deposit_volume_ratio =
  (volume 100–500 BTC + volume >500 BTC) / inflow_btc
```

Objectif :

détecter une dominante whale.

---

## 3. Institutional ratio

Heuristique encore plus restrictive.

Exemple :

```text
institutional_deposit_ratio =
  count >500 BTC / deposit_count
```

ou en volume :

```text
institutional_deposit_volume_ratio =
  volume >500 BTC / inflow_btc
```

La V3 utilise ici une approximation comportementale,
pas une identification d’institution réelle.

---

## 4. Concentration score

Le score de concentration vise à mesurer si les flux sont :

* diffus
* ou concentrés sur peu d’opérations

Première approche V3 :

utiliser la structure des buckets.

Exemple :

```text
concentration_score élevé
si une grande part du volume est dans 100–500 BTC et >500 BTC
```

Approches plus fines possibles plus tard :

* top 10 deposits share
* top 50 deposits share
* Gini-like score

La V3 initiale reste simple.

---

## 5. Distribution score

Le score de distribution cherche à mesurer une pression vendeuse potentielle.

Exemple de logique :

* inflow élevé
* forte part de gros dépôts
* concentration importante
* outflow relativement faible

Interprétation :

```text
des acteurs importants déposent vers les exchanges
```

La V3 ne conclut pas à une vente certaine.
Elle signale une probabilité comportementale plus forte.

---

## 6. Accumulation score

Le score d’accumulation cherche à mesurer un retrait significatif depuis les exchanges.

Exemple de logique :

* outflow élevé
* forte part de gros retraits
* inflow plus faible
* concentration importante côté retraits

Interprétation :

```text
des acteurs importants retirent des BTC des exchanges
```

---

# Table cible V3

Table proposée :

```text
exchange_flow_day_behavior
```

Cette table stocke les indicateurs comportementaux journaliers.

---

## Colonnes proposées

### Clé

| colonne | rôle        |
| ------- | ----------- |
| day     | jour agrégé |

---

### Ratios dépôts

| colonne                            | rôle                                    |
| ---------------------------------- | --------------------------------------- |
| retail_deposit_ratio               | part retail en count                    |
| retail_deposit_volume_ratio        | part retail en volume                   |
| whale_deposit_ratio                | part whale en count                     |
| whale_deposit_volume_ratio         | part whale en volume                    |
| institutional_deposit_ratio        | part institutionnelle estimée en count  |
| institutional_deposit_volume_ratio | part institutionnelle estimée en volume |

---

### Ratios retraits

| colonne                               | rôle                                    |
| ------------------------------------- | --------------------------------------- |
| retail_withdrawal_ratio               | part retail en count                    |
| retail_withdrawal_volume_ratio        | part retail en volume                   |
| whale_withdrawal_ratio                | part whale en count                     |
| whale_withdrawal_volume_ratio         | part whale en volume                    |
| institutional_withdrawal_ratio        | part institutionnelle estimée en count  |
| institutional_withdrawal_volume_ratio | part institutionnelle estimée en volume |

---

### Scores

| colonne                        | rôle                             |
| ------------------------------ | -------------------------------- |
| deposit_concentration_score    | concentration des dépôts         |
| withdrawal_concentration_score | concentration des retraits       |
| distribution_score             | pression de distribution estimée |
| accumulation_score             | pression d’accumulation estimée  |
| behavior_score                 | score synthétique du jour        |

---

### Métadonnées

| colonne     | rôle            |
| ----------- | --------------- |
| computed_at | date de calcul  |
| created_at  | timestamp Rails |
| updated_at  | timestamp Rails |

---

# Pourquoi une table dédiée

La V3 utilise des heuristiques et des scores plus interprétatifs.

Il est donc préférable de garder une table séparée pour :

* préserver la lisibilité des tables V1 et V2
* permettre l’évolution des heuristiques sans casser les bases existantes
* isoler les scores comportementaux des données brutes

Résumé :

```text
exchange_flow_days         = volume
exchange_flow_day_details  = structure
exchange_flow_day_behavior = comportement
```

---

# Service principal V3

Service prévu :

```text
app/services/inflow_outflow_behavior_builder.rb
```

Responsabilités :

* lire `exchange_flow_days`
* lire `exchange_flow_day_details`
* calculer les ratios comportementaux
* calculer les scores
* écrire dans `exchange_flow_day_behavior`

---

# Stratégie de calcul

Pour un jour donné :

1. lire la ligne V1 (`exchange_flow_days`)
2. lire la ligne V2 (`exchange_flow_day_details`)
3. calculer les ratios retail / whale / institution
4. calculer les scores de concentration
5. calculer les scores distribution / accumulation
6. persister le résultat

---

# Modes d’exécution

Comme les V1 et V2, la V3 doit supporter :

## Calcul d’un jour

```ruby
InflowOutflowBehaviorBuilder.call(day: Date.yesterday)
```

## Rebuild d’une période

```ruby
InflowOutflowBehaviorBuilder.call(days_back: 30)
```

## Mode par défaut

Le builder V3 doit recalculer :

* `Date.yesterday`
* `Date.current`

afin de rester cohérent avec les V1 et V2.

---

# Idempotence

La V3 doit être idempotente.

Règle :

* une seule ligne par jour
* si la ligne existe déjà, elle est mise à jour
* pas de doublon

La table doit donc avoir :

```text
index unique sur day
```

---

# Heuristiques V3 initiales

La V3 initiale doit rester simple, explicable et stable.

Exemples de regroupements :

## Retail

Buckets :

* `< 1 BTC`
* `1–10 BTC`

## Whale

Buckets :

* `10–100 BTC`
* `100–500 BTC`

## Institutional estimé

Bucket :

* `> 500 BTC`

Ces choix sont des conventions V3 et doivent être documentés dans `DECISIONS.md`.

---

# Vue V3

La V3 peut s’intégrer dans la page :

```text
/inflow_outflow
```

comme niveau supplémentaire.

Sections possibles :

## Market behavior

* retail deposit ratio
* whale deposit ratio
* institutional deposit ratio

## Withdrawal behavior

* retail withdrawal ratio
* whale withdrawal ratio
* institutional withdrawal ratio

## Behavior scores

* distribution score
* accumulation score
* behavior score

La V3 doit rester lisible et prudente.
Elle ne doit pas sur-promettre une certitude analytique.

---

# Fréquence d’exécution

Comme la V3 dépend uniquement de tables déjà calculées, elle peut être exécutée :

* toutes les heures
* ou juste après la V2

Ordonnancement logique :

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

# Cron et job

Scripts prévus :

```text
bin/cron_inflow_outflow_behavior_build.sh
```

Job prévu :

```text
InflowOutflowBehaviorBuildJob
```

Suivi via :

```text
JobRun
```

---

# Supervision

Le module V3 doit être visible dans `/system` via :

* job `inflow_outflow_behavior_build`
* table `exchange_flow_day_behavior`

Informations minimales :

* dernier run
* dernier jour calculé
* statut
* fraîcheur de la table

---

# Performances

La V3 est peu coûteuse.

Elle ne lit ni la blockchain ni les UTXO bruts directement.

Elle repose sur :

* `exchange_flow_days`
* `exchange_flow_day_details`

Le coût principal est donc faible.

---

# Limites V3

La V3 reste une couche heuristique.

Elle ne permet pas encore de :

* prouver l’identité d’un déposant
* distinguer avec certitude un exchange interne d’une institution
* confirmer une vente future
* confirmer une accumulation certaine

La V3 suggère un comportement probable.
Elle ne fournit pas une vérité absolue.

---

# Évolutions naturelles V4

La V4 pourra ajouter :

* top deposits share
* top withdrawals share
* score de concentration avancé
* clustering source
* détection de transferts internes
* signaux statistiques vs moyenne 30j
* alertes comportementales automatiques

---

# Conclusion

La V3 du module `inflow_outflow` transforme des données de flux et de structure
en indicateurs comportementaux exploitables.

En résumé :

```text
V1 = volume
V2 = structure
V3 = comportement
```

Cette couche constitue une étape importante pour faire de Bitcoin Monitor
un véritable moteur d’analyse on-chain orienté marché.


