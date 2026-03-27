
# Inflow / Outflow — V4 — README

Le module **Inflow / Outflow V4** introduit une nouvelle dimension dans l’analyse des flux Bitcoin :

```text
capital behavior
```

La V4 cherche à répondre à une question essentielle :

```text
qui déplace réellement le capital sur le marché ?
```

---

# Contexte

Les versions précédentes du module analysent déjà plusieurs dimensions des flux.

### V1 — Volume

Mesure les flux globaux.

```text
inflow BTC
outflow BTC
netflow BTC
```

Table :

```text
exchange_flow_days
```

---

### V2 — Structure des flux

Analyse la structure des dépôts et retraits.

Buckets utilisés :

```text
< 1 BTC
1–10 BTC
10–100 BTC
100–500 BTC
> 500 BTC
```

Table :

```text
exchange_flow_day_details
```

---

### V3 — Activity behavior

Analyse le comportement des acteurs **en nombre d’opérations**.

Exemples :

```text
retail deposit ratio
whale deposit ratio
institutional deposit ratio
```

Table :

```text
exchange_flow_day_behaviors
```

---

# Limite des versions précédentes

Une activité élevée ne signifie pas nécessairement un volume élevé.

Exemple réel :

| Bucket      | Deposits | Volume BTC |
| ----------- | -------- | ---------- |
| < 1 BTC     | 24 780   | 2 339 BTC  |
| 100–500 BTC | 310      | 52 727 BTC |

Lecture :

```text
activité dominée par retail
capital dominé par whales
```

La V4 est conçue pour résoudre ce problème.

---

# Objectif de la V4

La V4 analyse les flux **en volume de BTC**, pas seulement en nombre d’opérations.

Elle introduit :

```text
capital behavior
```

Cela permet de distinguer :

```text
qui agit
vs
qui contrôle réellement le capital
```

---

# Principe de la V4

La V4 utilise les volumes déjà calculés dans V2.

Exemple :

```text
inflow_lt_1_btc
inflow_1_10_btc
inflow_10_100_btc
inflow_100_500_btc
inflow_gt_500_btc
```

Ces données sont transformées en ratios de capital.

---

# Capital ratios

La V4 calcule :

### Retail deposit capital ratio

```text
(< 1 BTC + 1–10 BTC) / inflow BTC
```

---

### Whale deposit capital ratio

```text
(10–100 BTC + 100–500 BTC) / inflow BTC
```

---

### Institutional deposit capital ratio

```text
> 500 BTC / inflow BTC
```

Même logique côté retraits.

---

# Scores introduits par la V4

La V4 introduit plusieurs indicateurs.

---

## Capital dominance score

Mesure si le volume du marché est dominé par :

```text
whales
ou
institutions estimées
```

Plus le score est élevé, plus les gros capitaux dominent.

---

## Whale distribution score

Estime si les whales envoient du capital vers les exchanges.

Lecture possible :

```text
pression de vente potentielle
```

---

## Whale accumulation score

Estime si les whales retirent du capital des exchanges.

Lecture possible :

```text
accumulation potentielle
```

---

## Count / Volume divergence

Concept central de la V4.

Exemple :

```text
retail_deposit_ratio = 92 %
whale_deposit_capital_ratio = 70 %
```

Lecture :

```text
beaucoup de petits acteurs actifs
mais le capital est dominé par les whales
```

---

# Table V4

Les résultats sont stockés dans :

```text
exchange_flow_day_capital_behaviors
```

Cette table contient :

* capital ratios dépôts
* capital ratios retraits
* capital dominance score
* whale distribution score
* whale accumulation score
* divergence activity / capital

---

# Pipeline complet

Le module `inflow_outflow` fonctionne en plusieurs couches.

```text
Bitcoin blockchain
      ↓
exchange_observed_utxos
      ↓
InflowOutflowBuilder
      ↓
exchange_flow_days
      ↓
InflowOutflowDetailsBuilder
      ↓
exchange_flow_day_details
      ↓
InflowOutflowBehaviorBuilder
      ↓
exchange_flow_day_behaviors
      ↓
InflowOutflowCapitalBehaviorBuilder
      ↓
exchange_flow_day_capital_behaviors
```

Chaque version enrichit la précédente.

---

# Fréquence de calcul

La V4 peut être recalculée :

```text
toutes les heures
```

Elle dépend uniquement de données déjà agrégées.

Le pipeline devient :

```text
scan
→ inflow_outflow_build
→ inflow_outflow_details_build
→ inflow_outflow_behavior_build
→ inflow_outflow_capital_behavior_build
```

---

# Utilisation dans l’interface

La V4 ajoute une section **Capital behavior** dans la page :

```text
/inflow_outflow
```

Les éléments affichés peuvent inclure :

* capital ratios
* capital dominance
* whale distribution
* whale accumulation
* divergence activity vs capital

---

# Limites

La V4 repose sur des heuristiques simples.

Elle ne permet pas :

* d’identifier avec certitude les acteurs
* de confirmer une vente future
* de distinguer parfaitement les transferts OTC
* de prédire le prix

Elle fournit uniquement **une lecture probable du comportement du capital**.

---

# Évolutions futures

La V4 constitue une base pour des analyses plus avancées :

* dominance historique du capital
* whale clusters
* détection OTC probable
* top deposit share
* divergence prix / capital
* analyse par exchange
* signaux de stress de marché

Ces améliorations sont décrites dans :

```text
AMELIORATION.md
```

---

# Conclusion

La V4 introduit une dimension essentielle dans Bitcoin Monitor :

```text
activité ≠ capital
```

Résumé du module :

```text
V1 = volume
V2 = structure
V3 = activité
V4 = capital
```
