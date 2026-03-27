# 🟠 Bitcoin Monitor

**Bitcoin Monitor** est une application Ruby on Rails dédiée à l’analyse du marché Bitcoin à partir de données on-chain, de prix et de flux d’exchanges.

L’objectif n’est pas de prédire le marché, mais de fournir une **lecture structurée, factuelle et exploitable** pour aider à la prise de décision.

> ⚠️ Ceci n’est pas un conseil financier.

---

## 📸 Aperçu

![Bitcoin Monitor Dashboard](./screenshot-dashboard.png)

## 🚀 Pourquoi ce projet ?

Le marché crypto est souvent analysé à travers des opinions ou des indicateurs isolés.

Bitcoin Monitor propose une approche différente :

- 📊 centraliser des données fiables
- 🧠 structurer leur interprétation
- 📉 fournir une lecture claire du contexte de marché

---

## 🎯 Objectifs

- Centraliser des données Bitcoin (prix, flux, métriques)
- Fournir une lecture synthétique du marché
- Aider à répondre à des questions concrètes :
  - Le marché est-il sous pression vendeuse ?
  - Sommes-nous dans une zone de risque élevée ?
  - Faut-il attendre, acheter ou vendre ?

---

## 🧠 Philosophie

- 📊 Données avant opinions  
- 🔍 Lecture multi-indicateurs  
- 🧩 Séparation claire :
  - données brutes
  - métriques calculées
  - interprétation  
- 🛠️ Outil compréhensible, même sans expertise trading

---

## 📈 Fonctionnalités principales

### 🟢 Analyse du prix Bitcoin
- Historique BTC (USD)
- Graphiques lisibles (Chart.js)
- Exclusion des données instables (bougie du jour)

---

### 🟢 Contexte de marché (Market Snapshot)

Calcul périodique via tâches planifiées :

- MA200 (tendance long terme)
- Position dans le cycle
- Volatilité 30 jours
- Score de risque global

Affichage :
- état du marché (bull / bear / neutral)
- cycle
- niveau de risque

---

### 🟢 Flux des exchanges (True Exchange Flow)

- Inflows BTC
- Outflows BTC
- Netflow BTC

Permet d’identifier :
- pression vendeuse
- accumulation
- distribution

---

### 🟢 PnL théorique (Net USD)

- Simulation de sortie quotidienne
- Intégration des frais et slippage
- Identification des points optimaux

---

### 🟢 Alertes heuristiques

Basées sur :
- flux
- contexte marché
- performance

Exemples :
- pression vendeuse confirmée
- absence de signal
- phase neutre

---

## 🖥️ Interface

- Dashboard clair et lisible
- Mode simple / trader
- Graphiques Chart.js
- Responsive

---

## 🏗️ Architecture technique

### Backend
- Ruby on Rails
- Services métiers dédiés :
  - calculs
  - snapshots
  - pipelines de données

### Base de données
- PostgreSQL

### Frontend
- ERB + Tailwind CSS
- JavaScript minimal
- Chart.js (CDN)

---

## ⏱️ Traitement des données

- Ingestion de données externes
- Pré-calcul via jobs / cron
- Agrégation côté serveur
- Aucun calcul critique côté client

---

## 📊 Points techniques clés

- architecture orientée services
- séparation claire des responsabilités
- pipelines de traitement de données
- optimisation des requêtes
- logique métier centralisée

---

## 🚧 État du projet

- ✅ Base stable
- ✅ Fonctionnalités principales opérationnelles
- 🔄 Améliorations continues

---

## 🗺️ Roadmap

- Synchronisation des graphiques
- Overlays de décision
- Historique des alertes
- Export CSV / JSON
- Support multi-actifs

---

## 👨‍💻 À propos

Projet développé par Victor Perez.

Développeur backend Ruby on Rails spécialisé dans les applications métier, la data et l’analyse blockchain.

---

## 📜 Licence

Projet personnel / expérimental.  
Licence à définir.

## Screenshot 

![Bitcoin Monitor Dashboard](./screenshot-address.png)

![Bitcoin Monitor Dashboard](./screenshot-guides_cluster.png)

![Bitcoin Monitor Dashboard](./screenshot-system.png)

![Bitcoin Monitor Dashboard](./screenshot-system_tests.png)

![Bitcoin Monitor Dashboard](./screenshot-vault.png)



