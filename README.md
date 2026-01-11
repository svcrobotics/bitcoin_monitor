# 🟠 Bitcoin Monitor

Bitcoin Monitor est une application **Ruby on Rails** dédiée à l’analyse du marché Bitcoin à partir de **données on-chain, prix et flux d’exchanges**.

L’objectif n’est **pas de prédire le marché**, mais de fournir une **lecture structurée et factuelle** pour aider à la prise de décision (achat / vente / attente).

> ⚠️ Ceci n’est pas un conseil financier.

---

## 🎯 Objectifs du projet

- Centraliser des **données Bitcoin fiables** (prix, flux, métriques)
- Fournir une **lecture synthétique du contexte de marché**
- Aider à répondre à des questions concrètes :
  - Le marché est-il sous pression vendeuse ?
  - Sommes-nous dans une zone de risque élevée ?
  - Faut-il attendre, acheter ou vendre ?

---

## 🧠 Philosophie

- 📊 **Données avant opinions**
- 🔍 **Lecture multi-indicateurs**, pas un seul signal
- 🧩 **Séparation claire** entre :
  - données brutes
  - métriques calculées
  - interprétation humaine
- 🛠️ Outil conçu pour être **compréhensible**, même sans être trader pro

---

## 📈 Fonctionnalités principales

### 1️⃣ Prix Bitcoin
- Historique des prix BTC (USD)
- Graphique simple et lisible
- Exclusion de la bougie du jour (données non stables)

### 2️⃣ Contexte de marché (Market Snapshot)
Calculé périodiquement via cron :

- **MA200** (filtre de tendance long terme)
- **Position dans le cycle** (distance au plus haut)
- **Volatilité 30 jours**
- **Risque global** (low / medium / high)

Affiché sous forme de cartes :
- Marché (bull / bear / neutral)
- Cycle
- Risque

---

### 3️⃣ Flux vers les exchanges (True Exchange Flow)
- Inflows BTC
- Outflows BTC
- Netflow BTC
- Alignement prix ↔ flux

Permet d’identifier :
- pression vendeuse potentielle
- absorption par le marché
- phases de distribution ou d’accumulation

---

### 4️⃣ PnL théorique (Net USD)
- Évolution de la valeur nette si la position était liquidée chaque jour
- Intègre frais et slippage estimés
- Identification du meilleur / pire point de sortie

---

### 5️⃣ Alertes trader (heuristiques)
Alertes générées à partir :
- du contexte de marché
- des flux
- de la performance
- du risque

Exemples :
- ventes confirmées
- pression vendeuse potentielle
- pas de signal significatif

---

## 🖥️ Interface

- Dashboard clair et lisible
- Mode **simple** / **trader**
- Graphiques **Chart.js** (sans Chartkick)
- Responsive (desktop / tablette / mobile)

---

## 🏗️ Architecture technique

### Backend
- Ruby on Rails (standard, non API)
- SQLite (par défaut, facilement migrable)
- Services dédiés pour :
  - calculs de métriques
  - snapshots
  - alignements prix / flux

### Frontend
- ERB + Tailwind CSS
- Chart.js (via CDN)
- JavaScript minimal et maîtrisé
- Aucun framework JS lourd

---

## ⏱️ Données & calculs

- Prix : données journalières (source externe)
- Snapshots : pré-calculés via tâche planifiée
- Logique métier centralisée côté serveur
- Aucun calcul critique côté navigateur

---

## 🚧 État du projet

- ✅ Base stable
- ✅ Graphiques fonctionnels
- ✅ Moteur de lecture marché opérationnel
- 🔄 En évolution continue

---

## 🗺️ Roadmap (idées)

- Synchronisation des curseurs entre graphiques
- Ajout d’overlays (zones de décision)
- Historique et scoring des alertes
- Export des données (CSV / JSON)
- Support multi-actifs (après validation BTC)

---

## ⚠️ Avertissement

Bitcoin Monitor est un **outil d’aide à la réflexion**, pas un oracle.

Les décisions de trading comportent des risques.
L’auteur ne pourra être tenu responsable des pertes financières.

---

## 📜 Licence

Projet personnel / expérimental.  
Licence à définir selon l’évolution du projet.
