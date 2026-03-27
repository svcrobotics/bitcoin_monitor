
# Bitcoin Monitor — Module Cluster V2

Le module **Cluster V2** est une évolution du moteur de clustering V1.

Il ne remplace pas la V1 :
👉 il ajoute une couche d’analyse, de compréhension et de lisibilité.

---

## 1. Objectif

Permettre à un utilisateur de :

👉 comprendre rapidement une adresse Bitcoin  
👉 avant d’envoyer des fonds  

En répondant à des questions simples :

- Cette adresse est-elle isolée ou liée à d’autres ?
- Est-elle liée à une infrastructure importante ?
- Le comportement observé est-il normal ou particulier ?
- Quel est le niveau d’activité du cluster ?

---

## 2. Principe

### V1 (existant)
La V1 construit la structure brute :

- addresses
- address_links (multi-input)
- clusters

👉 Résultat : graphe implicite des relations entre adresses

---

### V2 (nouveau)

La V2 ajoute :

- profils
- classification
- score
- patterns simples
- meilleure UI

👉 Résultat : interprétation du graphe

---

## 3. Architecture

### 3.1 Tables V1 (source de vérité)

- `addresses`
- `address_links`
- `clusters`

---

### 3.2 Tables V2

#### `cluster_profiles`
Résumé d’un cluster

Contient :
- taille
- activité
- volume
- first_seen / last_seen
- classification
- score

---

#### `cluster_patterns`
Patterns détectés

Contient :
- coinjoin_detected
- repeated_structures
- automated_behavior_score

---

#### `address_profiles`
Résumé d’une adresse

Contient :
- tx_count
- total_sent_sats
- active_span
- reuse_score

---

## 4. Pipeline V2

Le pipeline V2 s’exécute indépendamment du scan blockchain.

### Étapes

1. Aggregation
→ construit `cluster_profiles`

2. Classification
→ détermine le type de cluster

3. Scoring
→ calcule un score simple

4. Pattern detection
→ détecte structures particulières

---

### Commande

```bash
bin/rails cluster:v2_refresh
````

---

## 5. Page adresse (point central)

La page adresse est le cœur du module.

### Elle affiche :

#### V1

* observed / non observé
* cluster id
* cluster size
* tx count
* first seen / last seen
* total sent

#### V2

* classification
* score
* résumé intelligent
* patterns simples
* adresses liées (filtrées)
* preuves multi-input

---

## 6. Classification (V2)

Types principaux :

* `exchange_like`
* `service`
* `whale`
* `retail`
* `unknown`

⚠️ Important :
Ce sont des **heuristiques**, pas des certitudes.

---

## 7. Score (V2)

Score simple basé sur :

* taille du cluster
* activité
* volume

Objectif :
👉 donner une lecture rapide

⚠️ Ce n’est PAS un score AML.

---

## 8. Patterns (V2)

Détection simple :

* structures répétées
* activité automatisée
* CoinJoin (basique)

Objectif :
👉 donner du contexte, pas accuser

---

## 9. Philosophie produit

Le module cluster V2 repose sur 3 piliers :

### 1. Contexte

Donner des informations utiles sur l’environnement d’une adresse

### 2. Interprétation

Aider à comprendre ce que signifient les données

### 3. Prudence

Ne jamais sur-interpréter

---

## 10. Ce que V2 n’est pas

* ❌ un outil AML complet
* ❌ un système d’identification certaine
* ❌ un oracle de vérité

---

## 11. Cas d’usage

### 1. Avant envoi BTC

👉 comprendre à qui on envoie

### 2. Analyse wallet

👉 voir si un wallet est isolé ou intégré

### 3. Analyse marché

👉 détecter comportements globaux

### 4. Sécurité

👉 repérer activité anormale

---

## 12. Monitoring

Le module V2 est visible dans `/system` :

* état du scan V1
* état des profils V2
* fraîcheur des données
* status jobs

---

## 13. Roadmap

### V2.1

* profils cluster
* classification simple
* score simple
* UI enrichie

### V2.2

* patterns améliorés
* coinjoin detection basique
* score plus fin

### V3

* cross modules (whales, inflow/outflow)
* alertes
* risk scoring avancé

---

## 14. Exemple concret

Adresse analysée :

```
Cluster size: 17,807
Tx count: 5
Total sent: 182 BTC
```

Lecture V2 :

👉 Cluster large
👉 activité observée
👉 compatible avec une infrastructure
👉 aucune anomalie majeure détectée

---

## 15. Règle d’or

👉 “Aider à comprendre, sans jamais prétendre savoir.”
