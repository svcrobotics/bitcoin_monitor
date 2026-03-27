
# 🟠 Bitcoin Monitor

**Bitcoin Monitor** est une application Ruby on Rails dédiée à l’analyse du marché Bitcoin à partir de données on-chain, de prix et de flux d’exchanges.

👉 Objectif : fournir une **lecture structurée, factuelle et exploitable** du marché — sans bruit, sans biais, sans prédiction.

> ⚠️ Ceci n’est pas un conseil financier.

---

## 📸 Aperçu

### Dashboard principal
![Dashboard](./screenshot-dashboard.png)

---

## 🚀 Pourquoi ce projet ?

Le marché crypto est souvent dominé par :
- des opinions
- des signaux isolés
- du bruit

Bitcoin Monitor propose une approche différente :

- 📊 centraliser des données fiables  
- 🧠 structurer leur interprétation  
- 📉 fournir une lecture claire du contexte  

---

## 🎯 Objectifs

- Centraliser des données Bitcoin (prix, flux, métriques)
- Fournir une synthèse claire du marché
- Aider à répondre à des questions concrètes :
  - Le marché est-il sous pression vendeuse ?
  - Sommes-nous dans une zone de risque ?
  - Faut-il attendre, acheter ou vendre ?

---

## 🧠 Philosophie

- 📊 Données avant opinions  
- 🔍 Multi-indicateurs (pas de signal unique)  
- 🧩 Séparation claire :
  - données brutes  
  - métriques calculées  
  - interprétation  
- 🛠️ Outil compréhensible sans être trader expert  

---

## 🛠️ Stack technique

- Ruby on Rails
- PostgreSQL / SQLite
- Tailwind CSS
- Chart.js
- Jobs / Cron
- Architecture orientée services

---

## ⚡ Quick Start

### Prérequis

- Ruby 3.x
- Rails 7+
- SQLite ou PostgreSQL

### Installation

```bash
git clone https://github.com/svcrobotics/bitcoin_monitor.git
cd bitcoin_monitor
bundle install
bin/rails db:create db:migrate
bin/rails server
````

👉 Ouvrir :
[http://localhost:3000](http://localhost:3000)

---

## 📈 Fonctionnalités

### 🟢 Analyse du prix

* Historique BTC
* Graphiques lisibles
* Données journalières propres

---

### 🟢 Market Snapshot

* MA200
* Cycle (distance ATH)
* Volatilité
* Score de risque

---

### 🟢 Exchange Flow

* Inflow / Outflow
* Netflow
* Analyse pression marché

---

### 🟢 PnL théorique

* Simulation de sortie
* Intégration frais / slippage

---

### 🟢 Alertes

* Basées sur données réelles
* Heuristiques métier
* Lecture simple / trader

---

## ⏱️ Traitement des données

* Ingestion données externes
* Pipelines batch
* Calculs serveur
* Aucun calcul critique côté client

---

## 🧱 Architecture

* Services métiers dédiés
* Logique métier isolée
* Séparation claire responsabilités
* Code orienté maintenabilité

---

## 🔍 Use cases

Bitcoin Monitor est conçu pour :

* traders
* analystes
* développeurs blockchain
* outils internes data

---

## 🚧 Roadmap

* Synchronisation des graphiques
* Overlays de décision
* Historique des alertes
* Export CSV / JSON
* Support multi-actifs

---

## 👨‍💻 À propos

Projet développé par **Victor Perez**

Développeur backend Ruby on Rails spécialisé dans :

* applications métier
* data
* analyse blockchain

---

## 📜 Licence

Projet personnel / expérimental
Licence à définir

## 📸 Screenshots

### 🧭 Dashboard & Market Overview
![Dashboard](./screenshot-address.png)

---

### 🧠 Cluster Analysis
![Cluster Analysis](./screenshot-guides_cluster.png)

---

### ⚙️ System Monitoring
![System](./screenshot-system.png)

---

### 🧪 System Health & Tests
![System Tests](./screenshot-system_tests.png)

---

### 🔐 Vault Interface
![Vault](./screenshot-vault.png)
