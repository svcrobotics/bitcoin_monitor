
# Inflow / Outflow — V4 — Decisions

Ce document décrit les décisions architecturales et conceptuelles prises pour la **V4 du module inflow_outflow**.

La progression du module devient :

```text
V1 = volume
V2 = structure des flux
V3 = comportement des acteurs (activity behavior)
V4 = comportement du capital (capital behavior)
```

La V4 introduit une nouvelle dimension d’analyse :

```text
activity ≠ capital
```

Un grand nombre de transactions ne signifie pas nécessairement un grand volume de BTC.

---

# Décision 1 — Introduire l’analyse du capital

La V3 analyse les comportements en fonction du **nombre d’opérations**.

Exemple :

```text
retail_deposit_ratio = 92 %
```

Cela signifie que la majorité des dépôts sont faits par des petits acteurs.

Mais cela ne dit rien sur :

```text
qui déplace réellement le capital
```

Exemple réel :

| Bucket      | Deposits | Volume     |
| ----------- | -------- | ---------- |
| < 1 BTC     | 24 780   | 2 339 BTC  |
| 100–500 BTC | 310      | 52 727 BTC |

Donc :

```text
activité dominée par retail
capital dominé par whales
```

La V4 a été créée pour résoudre ce problème.

---

# Décision 2 — Séparer activity behavior et capital behavior

Les analyses V3 et V4 sont volontairement séparées.

Tables distinctes :

```text
exchange_flow_day_behaviors
exchange_flow_day_capital_behaviors
```

Motivations :

* garder les modèles simples
* permettre d’améliorer les heuristiques indépendamment
* faciliter la maintenance
* conserver la lisibilité du pipeline

---

# Décision 3 — Réutiliser les données V2

La V4 ne lit pas directement :

```text
exchange_observed_utxos
```

Elle utilise :

```text
exchange_flow_day_details
```

qui contient déjà :

```text
inflow_lt_1_btc
inflow_1_10_btc
inflow_10_100_btc
inflow_100_500_btc
inflow_gt_500_btc
```

Avantages :

* pas de rescanning blockchain
* calcul rapide
* dépendance claire dans le pipeline

---

# Décision 4 — Conserver les mêmes buckets

La V4 utilise les mêmes buckets que la V2.

```text
< 1 BTC
1–10 BTC
10–100 BTC
100–500 BTC
> 500 BTC
```

Ces buckets ont été conservés pour :

* cohérence du modèle
* lisibilité de l’analyse
* éviter une multiplication des catégories

---

# Décision 5 — Définition des catégories capital

Pour la V4, les catégories suivantes sont utilisées.

### Retail capital

```text
< 1 BTC
1–10 BTC
```

### Whale capital

```text
10–100 BTC
100–500 BTC
```

### Institutional capital (estimé)

```text
> 500 BTC
```

Important :

ces catégories ne représentent pas des identités réelles.

Elles sont utilisées comme **approximation comportementale**.

---

# Décision 6 — Capital ratios

La V4 calcule des ratios basés sur les volumes BTC.

Exemple :

```text
retail_deposit_capital_ratio =
(inflow_lt_1_btc + inflow_1_10_btc) / inflow_btc
```

Même logique pour :

* whale capital
* institutional capital
* withdrawals

Objectif :

identifier la **répartition réelle du capital déplacé**.

---

# Décision 7 — Capital dominance score

La V4 introduit un score de domination du capital.

Concept :

```text
capital_dominance_score
```

But :

mesurer si le volume du marché est dominé par :

* retail
* whales
* institutions estimées

Une domination whale peut être significative pour l’analyse marché.

---

# Décision 8 — Whale distribution score

La V4 introduit un score estimant une **distribution potentielle**.

Heuristique :

```text
whale deposits élevés
+ inflow élevé
```

Lecture possible :

```text
les gros capitaux arrivent sur les exchanges
```

Cela peut indiquer une pression de vente.

Mais ce score reste **indicatif**.

---

# Décision 9 — Whale accumulation score

Inverse du score précédent.

Heuristique :

```text
whale withdrawals élevés
+ outflow élevé
```

Lecture possible :

```text
les gros capitaux retirent des BTC des exchanges
```

Cela peut indiquer une accumulation.

---

# Décision 10 — Count / Volume divergence

La V4 introduit un concept clé :

```text
divergence entre activité et capital
```

Exemple :

```text
retail_deposit_ratio = 92 %
whale_deposit_capital_ratio = 70 %
```

Lecture :

```text
les petits acteurs dominent en nombre
mais les whales dominent en capital
```

Cette divergence peut être très informative pour les traders.

Un score dédié est introduit :

```text
count_volume_divergence_score
```

---

# Décision 11 — Conserver des heuristiques simples

Les scores V4 utilisent volontairement des formules simples.

Objectifs :

* transparence
* reproductibilité
* facilité d’explication
* maintenance simplifiée

Des modèles plus complexes pourront être introduits ultérieurement.

---

# Décision 12 — Table dédiée V4

La V4 utilise une table spécifique :

```text
exchange_flow_day_capital_behaviors
```

Raisons :

* séparer clairement les couches analytiques
* isoler les heuristiques
* éviter la surcharge des tables V1 / V2 / V3

Structure du pipeline :

```text
exchange_flow_days                → V1
exchange_flow_day_details         → V2
exchange_flow_day_behaviors       → V3
exchange_flow_day_capital_behaviors → V4
```

---

# Décision 13 — Calcul horaire

La V4 est calculée :

```text
toutes les heures
```

Elle dépend uniquement de données déjà agrégées.

Le pipeline devient :

```text
exchange_observed_scan
→ inflow_outflow_build
→ inflow_outflow_details_build
→ inflow_outflow_behavior_build
→ inflow_outflow_capital_behavior_build
```

---

# Décision 14 — Neutralité analytique

Bitcoin Monitor vise à fournir des informations neutres.

Les scores V4 :

* ne constituent pas un conseil d’investissement
* ne prédisent pas le marché
* décrivent un comportement probable du capital

L’utilisateur reste responsable de son interprétation.

---

# Décision 15 — Évolution future

La V4 constitue une base pour des analyses plus avancées.

Améliorations possibles :

* dominance historique du capital
* analyse glissante 30 jours
* détection OTC probable
* concentration des dépôts
* top deposit share
* clustering des whales

Ces évolutions sont documentées dans `AMELIORATION.md`.

---

# Conclusion

La V4 introduit une dimension essentielle :

```text
qui agit
vs
qui contrôle réellement le capital
```

Cette distinction permet une lecture beaucoup plus fine du marché.

Résumé :

```text
V1 = volume
V2 = structure
V3 = activité
V4 = capital
```


