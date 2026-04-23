# Quand le module BTC a cessé d’être “juste un graphique”

> *Bitcoin Monitor n’a jamais été pensé comme un simple dashboard crypto.*
>
> Très tôt, une idée revenait constamment :
>
> > “si les données deviennent lentes, floues ou incohérentes… alors toute l’analyse devient dangereuse.”

Ce chapitre raconte comment le module BTC est passé :

* d’un affichage de prix relativement simple,
* à un véritable pipeline de données temps réel,
* puis à un module professionnel supervisé,
* testé,
* observable,
* et progressivement optimisé.

---

## 1. Introduction

Au départ, le module BTC semblait simple.

Afficher :

* le prix du Bitcoin,
* la variation,
* quelques métriques,
* un graphique.

Rien d’extraordinaire.

Dans beaucoup d’applications Rails, cela aurait probablement fini dans :

```text
app/controllers/dashboard_controller.rb
```

avec quelques appels API directement dans la vue.

Mais Bitcoin Monitor n’était pas construit comme un “site crypto”.

L’objectif était différent :

> construire une infrastructure d’analyse fiable.

Et cette nuance allait tout changer.

---

## 2. Le besoin initial

Le besoin réel n’était pas :

> “voir le prix du BTC”.

Le besoin était :

* comprendre le contexte marché,
* observer les mouvements,
* détecter les changements de régime,
* visualiser les variations,
* fournir des données suffisamment propres pour les autres modules.

Car rapidement, d’autres composants dépendaient du module BTC :

* Exchange Flow
* Inflow / Outflow
* Cluster analysis
* Whale activity
* Market snapshots

Le prix BTC devenait :

> une donnée centrale du système.

---

## 3. La première approche

La première version utilisait essentiellement :

```text
BtcPriceDay
```

Une table daily.

Simple.

Stable.

Pratique.

Le pipeline ressemblait à ceci :

```text
API externe
   ↓
cron daily
   ↓
btc_price_days
   ↓
dashboard
```

C’était suffisant pour :

* la tendance long terme,
* MA200,
* ATH,
* drawdown,
* contexte global.

Le dashboard affichait déjà :

* prix actuel,
* variation,
* MA200,
* amplitude 30 jours,
* bias marché,
* risk level.

Mais progressivement, une frustration apparaissait.

---

## 4. Les premiers problèmes

Le problème n’était pas technique.

Le problème était visuel.

Le dashboard donnait :

* une vue macro,
* mais aucune lecture intraday.

Impossible de voir :

* les réactions rapides,
* les mouvements de volatilité,
* les rejets,
* les impulsions acheteuses,
* les consolidations.

Et surtout :

> impossible de lire le comportement du marché.

Le besoin des chandeliers est apparu naturellement.

---

## 5. Les erreurs ou limites découvertes

La tentation initiale fut classique :

> “on va juste appeler Binance directement depuis le frontend.”

C’est souvent le premier réflexe.

Mais plusieurs problèmes sont apparus immédiatement.

### 5.1 Dépendance directe au fournisseur

Si Binance ralentissait :

* le dashboard ralentissait.

Si Binance changeait l’API :

* le frontend cassait.

Si l’utilisateur rechargeait plusieurs fois :

* les appels explosaient.

---

### 5.2 Pas de contrôle de fraîcheur

Le frontend ne savait pas :

* si les données étaient fraîches,
* retardées,
* incomplètes,
* manquantes.

Or Bitcoin Monitor devait devenir :

> explicable.

---

### 5.3 Aucune supervision

Aucune visibilité sur :

* les retards,
* les erreurs,
* les trous de données,
* les bougies manquantes.

C’est là qu’un premier déclic architectural est apparu :

> les données de marché sont un pipeline backend.
>
> Pas un simple fetch JavaScript.

---

## 6. Les tensions d’architecture

Le module BTC a commencé à grossir.

Et avec lui, les responsabilités.

Le système devait maintenant :

* récupérer les candles,
* stocker les candles,
* vérifier leur fraîcheur,
* préparer les données,
* alimenter les graphiques,
* superviser les jobs,
* fournir des métriques propres,
* rester rapide.

Très vite, un problème classique des applications Rails est apparu :

> tout commençait à vouloir vivre dans le controller.

---

## 7. Le premier vrai refactoring

Le refactoring n’a pas commencé par “optimiser”.

Il a commencé par :

> clarifier les responsabilités.

Le module a progressivement été découpé.

---

## 8. Le module BTC commence à devenir un vrai module

Une structure plus claire est apparue :

```text
BTC MODULE
│
├── Queries
├── Services
├── Providers
├── Models
├── Presenters
├── Views
├── JS
├── Cron
└── Tests
```

Ce n’était plus :

```text
controller → API → view
```

Mais :

```text
provider
   ↓
ingestion
   ↓
storage
   ↓
queries
   ↓
presenters
   ↓
UI
```

C’est un changement mental majeur.

---

## 9. Les chandeliers changent la manière de penser

L’introduction des chandeliers a été un moment important.

Pas seulement visuellement.

Architecturalement.

Car une bougie OHLC implique :

```text
Open
High
Low
Close
```

Mais aussi :

* un timeframe,
* une cohérence temporelle,
* une fraîcheur,
* une granularité,
* un volume potentiel,
* des règles d’affichage.

Le système devait maintenant gérer :

```text
BTC/USD 5m
BTC/USD 1h
BTC/EUR 5m
BTC/EUR 1h
```

Et bientôt :

```text
1m
15m
4h
1d
```

Le volume de données changeait complètement.

---

## 10. Introduction de `BtcCandle`

Une nouvelle table est apparue :

```ruby
BtcCandle
```

Avec :

* market
* timeframe
* open_time
* close_time
* open
* high
* low
* close
* volume
* source

Cette décision paraît évidente après coup.

Mais elle ne l’était pas au départ.

Car introduire une table dédiée signifie :

* ingestion,
* backfill,
* stockage,
* supervision,
* nettoyage,
* stratégie de cache.

---

## 11. Les jobs commencent à devenir importants

Le pipeline intraday ressemblait maintenant à ceci :

```text
BinanceProvider
    ↓
IntradayBackfill
    ↓
btc_candles
    ↓
CandlesQuery
    ↓
Lightweight Charts
```

Puis les crons sont arrivés :

```text
cron_btc_intraday_5m.sh
cron_btc_intraday_1h.sh
```

Et là, un nouveau problème est apparu.

---

## 12. Les performances

Au début, tout allait bien.

Puis les dashboards ont commencé à :

* recalculer constamment,
* relire PostgreSQL,
* retransformer les payloads,
* recharger les candles,
* recalculer les labels.

Et progressivement :

> le dashboard faisait trop de travail.

Le problème n’était pas dramatique.

Mais il était révélateur.

---

## 13. Le moment où Redis devient logique

Redis n’a pas été introduit “parce que c’est moderne”.

Il a été introduit parce qu’un benchmark a révélé une tension réelle.

Les mesures montraient :

Sans Redis :

```text
SummaryQuery (warm) avg=4.72ms
CandlesQuery (warm) avg=4.40ms
```

Avec Redis :

```text
SummaryQuery (warm) avg=0.06ms
CandlesQuery (warm) avg=0.20ms
```

Le gain devenait massif.

Et surtout :

> le backend cessait de recalculer inutilement.

---

## 14. Ce que Redis a réellement changé

Redis n’a pas “accéléré Rails”.

Redis a changé :

* le coût des lectures répétées,
* la charge PostgreSQL,
* la stabilité du dashboard,
* la fluidité du frontend.

Des caches dédiés sont apparus :

```text
Btc::Cache::SummaryCache
Btc::Cache::RecentCandlesCache
Btc::Cache::CandlesStatusCache
```

Le système commençait à devenir :

> une architecture de lecture optimisée.

---

## 15. L’importance de la fraîcheur

Puis une autre question est arrivée.

> “Comment savoir si les données sont encore fiables ?”

Car une bougie vieille de 2 heures sur un timeframe 5m :

> est dangereuse.

C’est ainsi qu’ont été introduits :

```text
FreshnessChecker
CandlesFreshnessChecker
```

Le système ne montrait plus seulement des données.

Il montrait :

* l’état des données,
* leur confiance,
* leur retard,
* leur fraîcheur.

C’est un changement très “senior”.

---

## 16. Le dashboard System devient indispensable

À ce moment-là, Bitcoin Monitor n’était plus une simple app Rails.

C’était devenu :

> un système de pipelines.

Et les pipelines nécessitent :

* supervision,
* observabilité,
* diagnostics.

Le dashboard `/system` est devenu central.

On y retrouvait :

* les jobs,
* les retards,
* les scanners,
* les locks,
* les runtimes,
* les heartbeat,
* les erreurs,
* les capacités,
* les délais,
* les freshness states.

---

## 17. Le problème des jobs silencieux

Un problème intéressant est apparu avec :

```text
exchange_observed_scan
```

Le job tournait.

Mais la progression restait invisible.

Le dashboard montrait :

```text
RUNNING
runtime: 53s
```

Mais impossible de savoir :

* combien de blocs restaient,
* si le job avançait réellement,
* où il était bloqué.

C’est là qu’un concept très important est apparu :

> un job professionnel doit être observable.

Pas seulement exécutable.

---

## 18. Runtime ≠ progression

C’est une distinction fondamentale.

### Runtime

```text
combien de temps le job tourne
```

### Progression

```text
où le job en est réellement
```

Cette nuance change complètement la supervision.

Le système a commencé à évoluer vers :

```ruby
progress_pct
progress_label
heartbeat
```

Et les jobs sont devenus :

> lisibles.

---

## 19. La pédagogie devient une feature

Un détail intéressant du module BTC :

l’équipe a commencé à ajouter des aides pédagogiques directement dans l’interface.

Par exemple :

* explication des bougies,
* corps verts / rouges,
* mèches hautes,
* mèches basses,
* rejet acheteur,
* pression vendeuse.

Pourquoi ?

Parce qu’un dashboard professionnel n’est pas obligé d’être opaque.

C’est un point souvent négligé.

Bitcoin Monitor essayait progressivement de devenir :

> un système professionnel compréhensible.

---

## 20. L’architecture plus mature

À ce stade, le module BTC ressemblait davantage à ceci :

```text
Provider
   ↓
Ingestion
   ↓
Storage
   ↓
Cache
   ↓
Queries
   ↓
Presenters
   ↓
UI
   ↓
Monitoring
```

Et surtout :

```text
tests
```

Partout.

---

## 21. Les leçons apprises

Le module BTC a enseigné plusieurs choses importantes.

### Une app pro n’est pas une somme de features

Elle devient :

* observable,
* supervisable,
* explicable,
* découpée,
* testable.

---

### Redis devient utile quand un problème réel apparaît

Pas avant.

---

### Les dashboards deviennent critiques

Quand les pipelines grandissent,
la supervision devient un produit en soi.

---

### Les jobs doivent être lisibles

Un job “RUNNING” ne suffit pas.

Il faut :

* progression,
* heartbeat,
* retard,
* capacité,
* durée,
* erreurs.

---

### Les données financières doivent afficher leur fraîcheur

Sinon l’utilisateur peut prendre :

> une mauvaise décision sur des données périmées.

---

## 22. Conclusion

Le module BTC semblait être un simple graphique.

Il est finalement devenu :

* un pipeline,
* un système de cache,
* une architecture de supervision,
* un moteur de données,
* une source de vérité pour d’autres modules.

Et surtout :

> il a changé la manière de penser l’application entière.

Le vrai changement n’était pas technique.

Le vrai changement était mental.

L’équipe ne construisait plus :

> des pages Rails.

Elle construisait :

> un système d’analyse opérationnel.

---

## 23. Glossaire

### OHLC

Structure d’une bougie :

* Open
* High
* Low
* Close

---

### Intraday

Données à granularité fine :

* 1m
* 5m
* 1h
* etc.

---

### Cache Redis

Stockage mémoire ultra rapide utilisé pour éviter les recalculs fréquents.

---

### Freshness

État de fraîcheur des données.

Permet de savoir si les données sont encore fiables.

---

### Heartbeat

Signal envoyé régulièrement par un job indiquant :

> “je suis toujours vivant”.

---

### Progression métier

Indique l’avancement réel d’un job :

```text
421 / 1000 blocs
42%
```

---

### Observabilité

Capacité à comprendre :

* ce que fait le système,
* où il est lent,
* où il échoue,
* où il bloque.

---

### Pipeline de données

Suite d’étapes transformant des données brutes en données exploitables :

```text
API
 ↓
ingestion
 ↓
storage
 ↓
cache
 ↓
queries
 ↓
UI
```
