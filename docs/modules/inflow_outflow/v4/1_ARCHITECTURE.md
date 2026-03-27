
# Inflow / Outflow — V4 — Architecture

Ce document décrit l’architecture de la V4 du module `inflow_outflow`.

La progression du module devient :

```text
V1 = volume
V2 = structure des flux
V3 = comportement des flux (activity behavior)
V4 = comportement du capital (capital behavior)
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

La V3 ajoute :

* ratios retail / whale / institution en nombre d’opérations
* scores de concentration
* scores distribution / accumulation

La V4 ajoute :

* ratios retail / whale / institution en **volume BTC**
* lecture du comportement du **capital**
* divergence entre activité et capital
* scores de domination du capital

La V4 ne remplace pas les versions précédentes.
Elle les complète.

---

# Objectif de la V4

La V3 répond surtout à :

```text
qui agit le plus souvent ?
```

Mais cette lecture peut être trompeuse.

Exemple :

```text
24 780 dépôts < 1 BTC
→ beaucoup d’activité retail
```

peut représenter moins de capital que :

```text
310 dépôts entre 100 et 500 BTC
```

La V4 répond donc à une question différente :

```text
qui déplace réellement le plus de BTC ?
```

En résumé :

```text
V3 = activity behavior
V4 = capital behavior
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
exchange_flow_day_behaviors
        ↓
InflowOutflowCapitalBehaviorBuilder V4
        ↓
exchange_flow_day_capital_behaviors
```

La V4 dépend principalement de :

* `exchange_flow_days`
* `exchange_flow_day_details`
* éventuellement `exchange_flow_day_behaviors`

Elle ne lit pas directement les UTXO bruts.

---

# Principe général

La V4 transforme les volumes par bucket en lecture du comportement du capital.

Elle cherche à distinguer :

* activité retail forte mais capital faible
* activité whale faible mais capital dominant
* retraits institutionnels concentrés
* divergence entre count et volume

Cette couche est particulièrement utile pour l’analyse marché.

---

# Concepts fonctionnels de la V4

## 1. Retail deposit capital ratio

Mesure la part du volume entrant attribuable aux petits acteurs.

Définition :

```text
retail = < 1 BTC + 1–10 BTC
```

Formule :

```text
retail_deposit_capital_ratio =
  (inflow_lt_1_btc + inflow_1_10_btc) / inflow_btc
```

Objectif :

mesurer la part retail en capital, pas en nombre.

---

## 2. Whale deposit capital ratio

Mesure la part du volume entrant attribuable aux gros acteurs.

Définition :

```text
whale = 10–100 BTC + 100–500 BTC
```

Formule :

```text
whale_deposit_capital_ratio =
  (inflow_10_100_btc + inflow_100_500_btc) / inflow_btc
```

---

## 3. Institutional deposit capital ratio

Mesure la part du volume entrant compatible avec une activité institutionnelle estimée.

Définition :

```text
institutional = > 500 BTC
```

Formule :

```text
institutional_deposit_capital_ratio =
  inflow_gt_500_btc / inflow_btc
```

Important :

comme en V3, il s’agit d’une approximation comportementale,
pas d’une identification réelle.

---

## 4. Withdrawal capital ratios

Même logique côté retraits.

Formules :

```text
retail_withdrawal_capital_ratio
whale_withdrawal_capital_ratio
institutional_withdrawal_capital_ratio
```

Objectif :

identifier qui retire réellement le capital des exchanges.

---

## 5. Capital dominance score

Mesure à quel point le volume total est dominé par des whales / institutions.

Exemple de logique simple :

```text
capital_dominance_score =
  whale_capital_ratio + institutional_capital_ratio
```

Version plus avancée possible :

* pondération distincte whale / institution
* normalisation historique

La V4 initiale reste simple.

---

## 6. Whale distribution score

Mesure une pression de distribution du capital.

Logique typique :

* `whale_deposit_capital_ratio` élevé
* `institutional_deposit_capital_ratio` élevé
* inflow > outflow
* concentration en capital élevée

Interprétation possible :

```text
les gros capitaux arrivent sur exchange
```

Cela suggère une pression de distribution potentielle.

---

## 7. Whale accumulation score

Mesure une accumulation potentielle en capital.

Logique typique :

* `whale_withdrawal_capital_ratio` élevé
* `institutional_withdrawal_capital_ratio` élevé
* outflow > inflow
* concentration en capital élevée

Interprétation possible :

```text
les gros capitaux retirent des BTC des exchanges
```

---

## 8. Count / Volume divergence

C’est l’un des concepts les plus importants de la V4.

Il mesure la différence entre :

* domination en **count**
* domination en **volume**

Exemple :

```text
retail_deposit_ratio élevé
mais
whale_deposit_capital_ratio élevé
```

Lecture :

```text
beaucoup de petits acteurs actifs
mais le capital réel est porté par les whales
```

La V4 doit donc calculer un score de divergence.

Exemple :

```text
count_volume_divergence_score
```

---

# Table cible V4

Table proposée :

```text
exchange_flow_day_capital_behaviors
```

Elle stocke les indicateurs de comportement du capital.

---

## Colonnes proposées

### Clé

| colonne | rôle        |
| ------- | ----------- |
| day     | jour agrégé |

---

### Ratios capital dépôts

| colonne                             | rôle                                            |
| ----------------------------------- | ----------------------------------------------- |
| retail_deposit_capital_ratio        | part retail du volume entrant                   |
| whale_deposit_capital_ratio         | part whale du volume entrant                    |
| institutional_deposit_capital_ratio | part institutionnelle estimée du volume entrant |

---

### Ratios capital retraits

| colonne                                | rôle                                            |
| -------------------------------------- | ----------------------------------------------- |
| retail_withdrawal_capital_ratio        | part retail du volume sortant                   |
| whale_withdrawal_capital_ratio         | part whale du volume sortant                    |
| institutional_withdrawal_capital_ratio | part institutionnelle estimée du volume sortant |

---

### Scores capital

| colonne                       | rôle                                                   |
| ----------------------------- | ------------------------------------------------------ |
| capital_dominance_score       | domination whales / institution du capital             |
| whale_distribution_score      | pression de distribution du capital                    |
| whale_accumulation_score      | pression d’accumulation du capital                     |
| count_volume_divergence_score | divergence entre activity behavior et capital behavior |
| capital_behavior_score        | score synthétique du comportement du capital           |

---

### Métadonnées

| colonne     | rôle            |
| ----------- | --------------- |
| computed_at | date de calcul  |
| created_at  | timestamp Rails |
| updated_at  | timestamp Rails |

---

# Pourquoi une table dédiée

Comme pour V3, les indicateurs V4 sont interprétatifs.

Il est préférable de les séparer pour :

* préserver la lisibilité des tables V1, V2 et V3
* faire évoluer les heuristiques sans casser les couches précédentes
* isoler clairement la lecture du capital

Résumé :

```text
exchange_flow_days               = volume
exchange_flow_day_details        = structure
exchange_flow_day_behaviors      = comportement activité
exchange_flow_day_capital_behaviors = comportement capital
```

---

# Service principal V4

Service prévu :

```text
app/services/inflow_outflow_capital_behavior_builder.rb
```

Responsabilités :

* lire `exchange_flow_days`
* lire `exchange_flow_day_details`
* éventuellement lire `exchange_flow_day_behaviors`
* calculer les ratios capital
* calculer les scores V4
* écrire dans `exchange_flow_day_capital_behaviors`

---

# Stratégie de calcul

Pour un jour donné :

1. lire la ligne V1
2. lire la ligne V2
3. calculer les ratios capital inflow
4. calculer les ratios capital outflow
5. calculer le score de domination du capital
6. calculer les scores whale distribution / whale accumulation
7. calculer la divergence count / volume
8. persister le résultat

---

# Heuristiques V4 initiales

La V4 doit rester simple et explicable.

## Retail capital

Buckets :

* `< 1 BTC`
* `1–10 BTC`

## Whale capital

Buckets :

* `10–100 BTC`
* `100–500 BTC`

## Institutional capital estimé

Bucket :

* `> 500 BTC`

Ces conventions doivent être documentées dans `DECISIONS.md`.

---

# Count vs Volume divergence

La V4 introduit un concept central :

```text
activity ≠ capital
```

Exemple :

* `retail_deposit_ratio` élevé
* `whale_deposit_capital_ratio` élevé

Cela signifie :

```text
les petits acteurs dominent en nombre
mais les whales dominent en capital
```

Cette divergence peut être très informative pour les traders.

---

# Vue V4

La V4 peut être intégrée dans la page :

```text
/inflow_outflow
```

comme niveau supplémentaire.

Sections possibles :

## Capital behavior

* retail deposit capital ratio
* whale deposit capital ratio
* institutional deposit capital ratio

## Withdrawal capital behavior

* retail withdrawal capital ratio
* whale withdrawal capital ratio
* institutional withdrawal capital ratio

## Capital scores

* capital dominance
* whale distribution
* whale accumulation
* count / volume divergence

La V4 doit rester lisible et prudente.

---

# Fréquence d’exécution

Comme la V4 dépend de tables déjà calculées, elle peut être exécutée :

* toutes les heures
* après la V3

Ordonnancement logique :

```text
exchange_observed_scan
        ↓
inflow_outflow_build
        ↓
inflow_outflow_details_build
        ↓
inflow_outflow_behavior_build
        ↓
inflow_outflow_capital_behavior_build
```

---

# Cron et job

Scripts prévus :

```text
bin/cron_inflow_outflow_capital_behavior_build.sh
```

Job prévu :

```text
InflowOutflowCapitalBehaviorBuildJob
```

Suivi via :

```text
JobRun
```

---

# Supervision

Le module V4 doit être visible dans `/system` via :

* job `inflow_outflow_capital_behavior_build`
* table `exchange_flow_day_capital_behaviors`

Informations minimales :

* dernier run
* dernier jour calculé
* statut
* fraîcheur de la table

---

# Performances

La V4 est légère.

Elle repose sur :

* `exchange_flow_days`
* `exchange_flow_day_details`
* éventuellement `exchange_flow_day_behaviors`

Elle ne nécessite ni rescanning blockchain ni relecture des UTXO bruts.

---

# Limites V4

La V4 reste une couche heuristique.

Elle ne permet pas encore de :

* prouver l’identité réelle d’un acteur
* confirmer qu’un flux whale correspond à une vente
* distinguer avec certitude un desk OTC d’un exchange interne
* fournir un signal de trading certain

La V4 suggère un comportement du capital, pas une vérité absolue.

---

# Évolutions naturelles V5

La V5 pourra ajouter :

* top deposit share
* top withdrawal share
* signaux historiques vs 30 jours
* score de domination du capital ajusté au contexte de marché
* détection d’OTC probable
* détection d’accumulation institutionnelle coordonnée

---

# Conclusion

La V4 du module `inflow_outflow` ajoute une lecture du **comportement du capital**.

En résumé :

```text
V1 = volume
V2 = structure
V3 = comportement activité
V4 = comportement capital
```

Cette couche permet de répondre à une question essentielle :

```text
qui déplace réellement le plus de BTC ?
```
