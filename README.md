# Bitcoin Monitor

Bitcoin Monitor est une application d’analyse **on-chain Bitcoin** orientée observation,
compréhension et expérimentation des données de la blockchain.

L’objectif n’est pas de prédire le prix, mais de **rendre lisibles les comportements**
des acteurs du réseau Bitcoin à partir des données brutes : blocs, transactions,
UTXOs, tokens et mouvements majeurs.

---

## 🎯 Objectifs du projet

- Observer l’activité réelle sur la blockchain Bitcoin
- Identifier des **patterns de comportement** (whales, services, plateformes)
- Fournir des outils pédagogiques pour comprendre Bitcoin “de l’intérieur”
- Expérimenter des approches d’analyse sans dépendre de services centralisés

Bitcoin Monitor est un outil d’analyse, pas un outil de trading.

---

## 🧩 Fonctionnalités principales

### 📦 Exploration de la blockchain
- Navigation bloc par bloc
- Analyse détaillée des transactions
- Lecture des inputs / outputs / UTXOs
- Connexion directe à un nœud Bitcoin via RPC

---

### 🐋 Whale Alerts
Détection et classification automatique des transactions importantes.

Chaque transaction dépassant un certain seuil est analysée et classée selon son
comportement :

- **Consolidation**  
  Regroupement de nombreux inputs vers une ou deux sorties  
  Souvent lié à une réorganisation de fonds ou du cold storage

- **Distribution**  
  Peu d’inputs vers de nombreuses sorties  
  Typique de paiements multiples ou de dispersion de fonds

- **Batching**  
  Grand nombre de sorties dans une seule transaction  
  Comportement fréquent des plateformes, services ou pools

- **Other**  
  Transaction importante sans pattern clair  
  Représente le bruit normal de la blockchain

Un **score (0–100)** permet de trier les alertes selon leur importance relative
(montant, structure, ratio).

Les Whale Alerts sont :
- scannées automatiquement chaque jour
- purgées automatiquement pour garder une base saine
- filtrables par type, montant et score

---

### 🪙 Analyse BRC-20
- Indexation des événements BRC-20
- Statistiques par bloc et par jour
- Suivi des balances par adresse
- Comptage des holders et des transferts

---

### ⛓️ Analyse Runes
- Indexation des runes et événements associés
- Suivi des balances
- Statistiques journalières
- Analyse de l’activité on-chain liée aux runes

---

### 🔐 Coffres-forts Bitcoin (P2WSH)
- Expérimentation de scripts multisignatures
- Observation des UTXOs et balances
- Connexion à des wallets de surveillance (watch-only)
- Approche éducative autour de la sécurité Bitcoin

---

### 💡 Feature Requests
- Soumission d’idées et améliorations
- Possibilité de soutenir des fonctionnalités via sats (BTCPay Server)
- Canal direct entre utilisateurs et développement

---

## ⚙️ Architecture technique

- Ruby on Rails (application serveur classique, non API-only)
- PostgreSQL
- Connexion directe à un nœud Bitcoin Core via JSON-RPC
- Données issues exclusivement de la blockchain (pas d’API tierce)
- Jobs automatisés via cron
- Frontend simple (HTML + Tailwind CSS)

---

## 🤖 Automatisation

Certaines tâches sont automatisées :

- Scan quotidien des Whale Alerts
- Purge automatique des anciennes alertes
- Synchronisation régulière des données BRC-20

Aucune action manuelle n’est nécessaire une fois l’application déployée.

---

## 🧠 Philosophie

Bitcoin Monitor repose sur quelques principes simples :

- **On-chain first** : la blockchain est la source de vérité
- **Pas de promesse de prix** : observation ≠ prédiction
- **Pédagogie** : rendre les données compréhensibles
- **Expérimentation** : tester, apprendre, améliorer

C’est un outil pour développeurs, analystes, curieux et utilisateurs avancés
souhaitant mieux comprendre Bitcoin.

---

## 🚧 État du projet

Le projet est en développement actif.
Les fonctionnalités évoluent au fil des expérimentations et retours.

---

## 📜 Licence

Projet expérimental / éducatif.  
À adapter selon ton choix de licence.
