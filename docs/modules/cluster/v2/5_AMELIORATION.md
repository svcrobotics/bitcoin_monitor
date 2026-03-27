
## Bitcoin Monitor — Cluster V2 — Improvements

Ce document liste les améliorations possibles du module cluster,
classées par priorité et par impact produit.

Objectif :
- guider les itérations
- éviter de partir dans tous les sens
- prioriser ce qui apporte de la vraie valeur

---

# 1. Vision globale

La V2 introduit :
- profils
- classification
- score
- patterns simples

Les améliorations visent à aller vers :
👉 un moteur d’analyse comportementale crédible et utile

---

# 2. Améliorations prioritaires (V2.x)

## I-201 — Affichage en BTC (et non sats)

### Problème
Les montants en sats sont peu lisibles pour l’utilisateur.

### Solution
- afficher en BTC par défaut
- garder sats en secondaire (tooltip ou petit texte)

### Impact
⭐⭐⭐⭐⭐ (très fort UX)

---

## I-202 — Conversion EUR / USD

### Problème
BTC seul ne parle pas à tous les utilisateurs.

### Solution
- ajouter conversion :
  - BTC → EUR
  - BTC → USD
- utiliser `btc_price_days`

### Impact
⭐⭐⭐⭐⭐ (compréhension immédiate)

---

## I-203 — Score visuel (badge / couleur)

### Problème
Le score brut est abstrait.

### Solution
- badge visuel :
  - 🟢 faible
  - 🟡 moyen
  - 🔴 élevé
- ou gradient

### Impact
⭐⭐⭐⭐⭐ (UX + produit)

---

## I-204 — Classification visuelle

### Problème
La classification est textuelle uniquement.

### Solution
- badges :
  - exchange-like
  - service
  - whale
  - retail
- icônes simples

### Impact
⭐⭐⭐⭐⭐

---

## I-205 — Résumé intelligent V2

### Problème
Résumé encore trop générique.

### Solution
générer un résumé basé sur :
- taille cluster
- activité
- score
- patterns

### Exemple
> “Cluster large avec activité régulière et volume élevé, compatible avec une infrastructure de service.”

### Impact
⭐⭐⭐⭐⭐

---

## I-206 — Limiter bruit des linked addresses

### Problème
Liste brute peu exploitable.

### Solution
- ajouter tri :
  - top volume
  - top activité
- ajouter filtre :
  - n’afficher que top 5 / 10

### Impact
⭐⭐⭐⭐

---

## I-207 — Déduplication intelligente des preuves

### Problème
Tx répétées visibles plusieurs fois.

### Solution
- dédupliquer par txid
- limiter à preuves uniques

### Impact
⭐⭐⭐⭐

---

## I-208 — Ajout "Activity span"

### Solution
Afficher :

```

Actif sur : 362 blocs (~2.5 jours)

```

### Impact
⭐⭐⭐⭐

---

## I-209 — Ajout "Cluster density"

### Idée
Mesurer :
- tx / adresse
- volume / adresse

### Impact
⭐⭐⭐⭐

---

## I-210 — Ajout "Dominance ratio"

### Idée
Top adresse vs reste du cluster

### Exemple
```

Top address = 62% du volume

```

### Impact
⭐⭐⭐⭐

---

# 3. Améliorations data / moteur

## I-301 — Améliorer heuristique multi-input

### Problème
Multi-input ≠ vérité absolue

### Solution
- filtrer cas suspects
- détecter patterns faux positifs

### Impact
⭐⭐⭐⭐⭐

---

## I-302 — Détection CoinJoin simple

### V2.x
- sorties égales
- structure répétée

### Impact
⭐⭐⭐⭐⭐

---

## I-303 — Score de confiance cluster

### Idée
Score de qualité du cluster

### Impact
⭐⭐⭐⭐

---

## I-304 — Détection automatisation

### Idée
- patterns répétitifs
- scripts automatisés

### Impact
⭐⭐⭐⭐

---

## I-305 — Ratio unique inputs

### Idée
% inputs uniques vs réutilisés

### Impact
⭐⭐⭐

---

# 4. Améliorations UI

## I-401 — Page cluster dédiée améliorée

### Ajouter :
- score
- classification
- patterns
- stats clés

### Impact
⭐⭐⭐⭐⭐

---

## I-402 — Timeline activité

### Graphique :
- tx dans le temps
- volume dans le temps

### Impact
⭐⭐⭐⭐⭐

---

## I-403 — Vue “cluster explorer”

### Idée
- naviguer entre clusters
- suivre liens

### Impact
⭐⭐⭐⭐

---

## I-404 — Mode “simple / expert”

### Simple
- résumé + score

### Expert
- détails complets

### Impact
⭐⭐⭐⭐⭐

---

# 5. Améliorations performance

## I-501 — Cache profils

### Solution
- cache `cluster_profiles`

### Impact
⭐⭐⭐⭐⭐

---

## I-502 — Limiter requêtes cluster

### Solution
- preload associations
- éviter N+1

### Impact
⭐⭐⭐⭐⭐

---

## I-503 — Batch processing

### Solution
- traiter clusters par batch

### Impact
⭐⭐⭐⭐

---

# 6. Améliorations monitoring

## I-601 — Ajout cluster V2 dans system

### Afficher :
- refresh V2
- fraîcheur profils
- nombre clusters traités

### Impact
⭐⭐⭐⭐⭐

---

## I-602 — KPI V2

### Exemple
- clusters analysés
- patterns détectés
- clusters suspects

### Impact
⭐⭐⭐⭐

---

# 7. Améliorations produit avancées (V3)

## I-701 — Cross modules

Relier clusters avec :
- whales
- inflow/outflow
- exchange flow

### Impact
⭐⭐⭐⭐⭐

---

## I-702 — Risk scoring avancé

### Idée
score composite :
- volume
- patterns
- activité

### Impact
⭐⭐⭐⭐⭐

---

## I-703 — Alertes

### Exemple
- cluster actif soudainement
- volume anormal

### Impact
⭐⭐⭐⭐⭐

---

## I-704 — API publique

### Permettre :
- requêtes cluster
- intégration externe

### Impact
⭐⭐⭐⭐

---

# 8. Roadmap recommandée

## Phase 1 (immédiat)
- BTC display
- score visuel
- classification badge
- résumé intelligent

## Phase 2
- patterns simples
- coinjoin detection basique
- amélioration UI cluster

## Phase 3
- cross modules
- alerting
- risk scoring

---

# 9. Philosophie

Chaque amélioration doit :

- apporter de la valeur utilisateur
- rester compréhensible
- rester prudente
- être observable dans system

---

# 10. Règle d’or

👉 “Si ça n’aide pas à comprendre une adresse avant un transfert,
ce n’est pas prioritaire.”
