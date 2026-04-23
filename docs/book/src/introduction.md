# Introduction

## Pourquoi raconter la construction de Bitcoin Monitor ?

Pendant longtemps, j’ai pensé que les applications professionnelles naissaient d’une architecture parfaitement pensée dès le départ.

Je pensais qu’un développeur senior :

* savait immédiatement quoi construire,
* choisissait instantanément la bonne architecture,
* anticipait tous les problèmes,
* et écrivait naturellement du “bon code”.

Puis Bitcoin Monitor est arrivé.

Et progressivement, j’ai compris quelque chose d’important :

> les vraies applications professionnelles ne naissent pas parfaites.

Elles évoluent.

---

# Le début du projet

À l’origine, Bitcoin Monitor était un projet relativement simple.

L’objectif principal était de construire :

* un dashboard Bitcoin,
* quelques indicateurs,
* des analyses de marché,
* et une lecture plus rationnelle des comportements blockchain.

Le projet ne devait pas devenir :

* une plateforme complexe,
* un moteur d’intelligence blockchain,
* ni une architecture orientée pipelines massifs.

Et pourtant…

C’est exactement ce qu’il a commencé à devenir.

---

# Pourquoi ce livre existe

Ce livre n’est pas :

* un tutoriel Rails classique,
* une suite de CRUD,
* ni une collection de “best practices” théoriques.

Ce livre raconte :

> l’évolution réelle d’une application Rails qui grandit.

Avec :

* ses erreurs,
* ses hésitations,
* ses refactorings,
* ses problèmes de performance,
* ses mauvaises idées,
* ses découvertes,
* et ses moments de déclic.

---

# Le vrai sujet du livre

Au fil du développement, un changement important est apparu.

Le vrai problème n’était plus :

> “comment coder une fonctionnalité ?”

Mais :

> “comment faire évoluer une application sans qu’elle devienne incontrôlable ?”

Et cette question change complètement la manière de développer.

---

# Ce que Bitcoin Monitor a progressivement révélé

Chaque module du projet a introduit de nouveaux problèmes :

Le module BTC a révélé :

* les problèmes de fraîcheur,
* la montée des responsabilités,
* la nécessité du cache,
* la supervision,
* la séparation des couches.

Le module Exchange Like a révélé :

* les pipelines blockchain,
* les datasets massifs,
* les heuristiques probabilistes,
* les scanners incrémentaux,
* les jobs longs,
* l’observabilité système.

Et chaque nouveau problème a forcé l’architecture à évoluer.

---

# Une application vivante

Très vite, Bitcoin Monitor a cessé d’être :

> “une application Rails”.

Le projet est progressivement devenu :

* un ensemble de pipelines,
* des scanners blockchain,
* des datasets,
* des jobs distribués,
* des systèmes de supervision,
* des caches mémoire,
* des flux de données vivants.

Et surtout :
le projet a commencé à révéler quelque chose d’extrêmement important :

> une application professionnelle est un système vivant.

---

# Pourquoi raconter l’histoire des modules

La plupart des livres techniques montrent :

* le résultat final,
* une architecture propre,
* des exemples simplifiés.

Mais ils montrent rarement :

* comment les problèmes apparaissent,
* pourquoi certaines décisions deviennent nécessaires,
* ou comment une architecture mûrit réellement.

C’est précisément ce que ce livre veut raconter.

Chaque chapitre correspond à :

* un module,
* un problème réel,
* une tension d’architecture,
* un moment d’évolution du système.

---

# Le vrai objectif pédagogique

Le but de ce livre n’est pas seulement d’apprendre :

* Ruby on Rails,
* Redis,
* PostgreSQL,
* Sidekiq,
* Bitcoin Core,
* ou les pipelines blockchain.

Le vrai objectif est plus profond.

Le livre cherche à montrer :

> comment un développeur commence progressivement à penser comme un ingénieur logiciel senior.

---

# Ce que vous allez voir dans ce livre

Au fil des chapitres, nous allons voir apparaître :

* des dashboards qui deviennent des pipelines,
* des jobs qui deviennent des systèmes vivants,
* des heuristiques qui deviennent des moteurs probabilistes,
* des datasets qui explosent,
* des problèmes de performance,
* des besoins de cache,
* des architectures qui doivent devenir observables.

Mais surtout :
nous allons voir comment chaque problème pousse naturellement l’application vers une architecture plus mature.

---

# Une chronique d’ingénierie

Bitcoin Monitor n’est pas présenté ici comme :

> “un projet parfait”.

Au contraire.

Le livre montre :

* les erreurs,
* les refactorings,
* les hésitations,
* les moments où certaines idées semblaient bonnes,
* puis se sont révélées dangereuses.

Et c’est précisément ce qui rend le projet intéressant.

Parce qu’en ingénierie réelle :

> les systèmes évoluent rarement de manière linéaire.

---

# Pour qui est ce livre ?

Ce livre s’adresse :

* aux développeurs Rails,
* aux backend engineers,
* aux développeurs blockchain,
* aux personnes qui construisent des systèmes orientés données,
* et surtout :
* à ceux qui veulent comprendre comment une application devient progressivement professionnelle.

---

# Le principe du livre

Chaque chapitre est écrit :

* après le développement réel du module,
* en se basant sur les vrais fichiers,
* les vrais services,
* les vrais jobs,
* les vrais problèmes rencontrés.

L’objectif est simple :

> raconter l’évolution réelle de Bitcoin Monitor pendant qu’elle se produit.

---

# Bienvenue dans Bitcoin Monitor

Ce livre raconte :

* la construction d’une application,
* mais aussi la transformation progressive de la manière de penser de ses développeurs.

Parce qu’au final :

> construire une application professionnelle change aussi la façon de réfléchir à l’ingénierie logicielle.
