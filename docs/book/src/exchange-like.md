# Exchange Like : le moment où Bitcoin Monitor a commencé à lire la blockchain comme un système vivant

> *Le jour où le module “Exchange Like” est apparu, Bitcoin Monitor a changé de nature.*
>
> Avant cela, l’application observait surtout :
>
> * des prix,
> * des variations,
> * des métriques marché.
>
> Après cela, elle a commencé à observer :
>
> > les comportements.

Ce chapitre raconte comment un simple besoin d’identification d’adresses “probablement exchange” a progressivement conduit à :

* des scanners blockchain,
* des pipelines de détection,
* des datasets massifs,
* des curseurs,
* des UTXO observés,
* des caches Redis,
* des jobs longs,
* des problèmes de performance,
* et finalement une architecture bien plus mature.

---

## 1. Introduction

Au départ, Bitcoin Monitor savait :

* lire des blocs,
* calculer des métriques,
* afficher des dashboards.

Mais une question revenait constamment :

> “Comment savoir si les flux viennent réellement des exchanges ?”

C’était un problème beaucoup plus difficile qu’il n’y paraissait.

Car Bitcoin ne fournit pas :

```text
type = exchange
```

dans ses transactions.

Tout devait être inféré.

---

## 2. Le besoin initial

Le besoin initial semblait relativement simple :

> détecter les plateformes d’échange.

Pourquoi ?

Parce que presque tous les futurs modules dépendaient de cette information :

* inflow,
* outflow,
* exchange pressure,
* capitulation,
* accumulation,
* distribution,
* mouvements institutionnels.

Sans “exchange-like” :

> impossible d’interpréter correctement les flux.

---

## 3. La première approche

La première idée était naïve.

Observer les grosses transactions.

Par exemple :

```text
100 BTC
500 BTC
2000 BTC
```

Puis essayer de déterminer :

* si elles entraient sur un exchange,
* ou en sortaient.

Mais rapidement, plusieurs problèmes sont apparus.

---

## 4. Les premiers problèmes

### 4.1 Une adresse ne dit rien

Une adresse Bitcoin seule :

```text
bc1...
```

ne contient aucune information métier.

Impossible de savoir :

* exchange,
* particulier,
* desk OTC,
* cold wallet,
* custodian,
* mixer,
* service.

---

### 4.2 Les exchanges utilisent des milliers d’adresses

Le deuxième choc architectural :

> les plateformes changent constamment d’adresses.

Impossible de maintenir :

```text
exchange_addresses.yml
```

avec quelques listes statiques.

Le dataset devait être :

* dynamique,
* auto-alimenté,
* évolutif.

---

### 4.3 Les heuristiques deviennent inévitables

Très vite, l’équipe a compris :

> il fallait raisonner en comportements.

Pas en labels fixes.

---

## 5. La naissance des heuristiques

Les premières heuristiques étaient simples.

Par exemple :

```ruby
outputs_nonzero_count >= 80
```

→ comportement de batching.

Ou :

```ruby
largest_output_ratio >= 0.95
```

→ probable transfert unique.

Les types sont progressivement apparus :

```ruby
TYPES = %w[
  consolidation
  distribution
  batching
  single_destination
  other
].freeze
```

Puis les scores :

```ruby
exchange_likelihood
score
exchange_hint
```

C’est un moment important dans l’évolution d’une application :

> quand les données deviennent probabilistes.

---

## 6. WhaleAlert devient un pivot du système

Le module WhaleAlert existait déjà.

Au départ, il servait surtout à détecter :

* les gros mouvements,
* les whales,
* les transactions atypiques.

Mais progressivement, un déclic est apparu :

> WhaleAlert pouvait devenir une source d’apprentissage pour Exchange Like.

Les transactions “exchange-like” détectées servaient maintenant à :

* enrichir le dataset,
* apprendre des adresses,
* détecter des patterns.

Le système commençait à devenir :

> récursif.

---

## 7. La première vraie base d’adresses

C’est ainsi qu’est apparue :

```ruby
ExchangeAddress
```

Avec :

```ruby
t.string   :address
t.integer  :confidence
t.integer  :occurrences
t.string   :source
t.datetime :first_seen_at
t.datetime :last_seen_at
```

Au début, cela semblait suffisant.

Mais très vite :

> le volume a explosé.

---

## 8. Les performances commencent à souffrir

Le système devait maintenant :

* scanner des blocs,
* parcourir les transactions,
* lire les outputs,
* détecter les adresses,
* mettre à jour les occurrences,
* recalculer les scores.

Et surtout :

```text
répéter cela continuellement.
```

Les premiers symptômes sont apparus :

* jobs longs,
* scans massifs,
* consommation CPU,
* lenteurs PostgreSQL,
* dashboards qui deviennent lourds.

---

## 9. Le moment où “scanner” devient un métier

Une distinction importante est alors apparue.

Avant :

```text
un job = une tâche
```

Maintenant :

```text
un scanner = un pipeline vivant
```

C’est une différence énorme.

Le système devait maintenant gérer :

* des curseurs,
* des best heights,
* des lags,
* des reprises,
* des backfills,
* des locks,
* des scans incrémentaux.

---

## 10. La naissance des scanners

Des composants spécialisés sont apparus :

```ruby
ExchangeAddressBuilder
ExchangeObservedScanner
```

Le pipeline ressemblait progressivement à ceci :

```text
Bitcoin Core RPC
      ↓
block scan
      ↓
heuristics
      ↓
ExchangeAddress
      ↓
ExchangeObservedUtxo
      ↓
inflow/outflow
```

Et c’est là qu’un autre changement majeur est arrivé.

---

## 11. Les UTXO observés changent tout

L’équipe a compris quelque chose de fondamental :

> suivre uniquement les adresses ne suffisait pas.

Pourquoi ?

Parce qu’une adresse peut :

* recevoir,
* dépenser,
* reshuffler,
* redistribuer,
* consolider.

Ce qui compte réellement :

> ce sont les UTXO observés.

---

## 12. Introduction de `ExchangeObservedUtxo`

Une nouvelle table est apparue :

```ruby
ExchangeObservedUtxo
```

Avec :

```ruby
t.string  :txid
t.integer :vout
t.string  :address
t.decimal :value_btc
t.date    :seen_day
t.date    :spent_day
t.string  :spent_by_txid
```

Le système ne suivait plus seulement :

```text
des adresses
```

Mais :

```text
des pièces observées.
```

C’est une énorme évolution conceptuelle.

---

## 13. Le vrai problème : les volumes

Puis le dataset a commencé à grossir.

Très vite.

Des millions d’UTXO observés.

Par exemple :

```ruby
ExchangeObservedUtxo.count
# => 3_658_495
```

À ce stade, certains problèmes deviennent inévitables :

* scans trop longs,
* requêtes lentes,
* contention DB,
* dashboards lourds,
* jobs qui se chevauchent.

---

## 14. Les jobs longs deviennent un problème d’architecture

Le problème n’était plus :

> “le code fonctionne-t-il ?”

Mais :

> “le système reste-t-il opérationnel ?”

C’est une transition extrêmement importante.

Le système devait maintenant gérer :

* les runtimes,
* les retards,
* les locks,
* les capacités,
* les jobs coincés.

---

## 15. Le dashboard `/system` devient vital

C’est à ce moment que le dashboard système a cessé d’être “optionnel”.

Il devenait impossible de gérer les scanners sans visibilité.

Des métriques sont apparues :

```text
Cursor
Lag
Best block
Runtime
Heartbeat
Capacity
Delay
Missed runs
```

Le système devenait observable.

---

## 16. Une erreur révélatrice : Redis absent

Un incident intéressant est apparu après l’introduction du cache Redis.

Le job :

```text
exchange_observed_scan
```

commençait à échouer avec :

```ruby
NoMethodError:
undefined method `get' for nil:NilClass
```

dans :

```ruby
ExchangeLike::ScannableAddressesCache
```

Pourquoi cette erreur est importante ?

Parce qu’elle révèle un vrai problème d’architecture :

> le système dépendait maintenant d’un composant externe critique.

---

## 17. Le moment où Redis devient nécessaire

Au départ, les adresses scannables étaient relues constamment depuis PostgreSQL.

Le scanner faisait :

```sql
SELECT address
FROM exchange_addresses
WHERE occurrences >= 3
```

encore et encore.

Avec des datasets massifs, cela devenait absurde.

Redis est alors devenu une réponse naturelle :

```ruby
ExchangeLike::ScannableAddressesCache
```

Le but :

* éviter les reloads constants,
* réduire les requêtes SQL,
* accélérer les scans,
* garder les datasets chauds en mémoire.

---

## 18. Le système commence à utiliser la RAM intelligemment

C’est une étape importante dans la maturité backend.

Avant :

```text
PostgreSQL faisait tout
```

Après :

```text
PostgreSQL stocke
Redis accélère
```

Le scanner devenait plus fluide.

Les scans consommaient moins de temps CPU.

Les lectures répétitives disparaissaient.

---

## 19. Les jobs RUNNING deviennent trompeurs

Puis un autre problème est apparu.

Le dashboard affichait :

```text
RUNNING
```

Mais impossible de savoir :

* si le scanner avançait,
* ou s’il était bloqué.

Le runtime seul ne suffisait plus.

---

#"" 20. Runtime ≠ progression

C’est une distinction très “senior”.

### Runtime

```text
combien de temps le job tourne
```

### Progression

```text
où le job en est réellement
```

L’équipe a commencé à vouloir afficher :

```text
421 / 1000 blocs
42%
```

Et là, les jobs sont devenus :

> observables métier.

---

## 21. Exchange Like cesse d’être un module isolé

Un autre changement majeur est apparu.

Au début :

```text
Exchange Like
```

était un module autonome.

Puis progressivement :

```text
WhaleAlert
   ↓
Exchange Like
   ↓
Observed UTXO
   ↓
Inflow / Outflow
   ↓
Market interpretation
```

Le système devenait :

> interconnecté.

---

## 22. Les tensions futures deviennent visibles

À ce stade, plusieurs futurs problèmes étaient déjà visibles :

* scans trop longs,
* besoin de parallélisation,
* mémoire,
* Redis plus critique,
* possibles queues,
* supervision plus avancée,
* backfills massifs,
* découpage des tâches.

Mais cette fois :

> les problèmes étaient compris.

Et ça change tout.

---

## 23. L’architecture plus mature

Le module ressemblait désormais davantage à ceci :

```text
Bitcoin Core
     ↓
RPC block scan
     ↓
heuristics
     ↓
ExchangeAddress
     ↓
Redis cache
     ↓
Observed UTXO
     ↓
Flow analysis
     ↓
Dashboard
     ↓
System monitoring
```

Le système n’était plus :

```text
une app Rails
```

Mais :

```text
une plateforme d’analyse blockchain
```

---

## 24. Les leçons apprises

### Les labels statiques ne suffisent jamais

Les comportements sont plus importants que les listes.

---

### Les scanners deviennent des systèmes vivants

Ils nécessitent :

* supervision,
* progression,
* reprise,
* heartbeat,
* observabilité.

---

### Redis devient naturel quand les datasets grossissent

Pas avant.

---

### Les UTXO sont souvent plus importants que les adresses

Car ils représentent :

> les flux réels.

---

### Une architecture mature accepte les probabilités

```ruby
exchange_likelihood
```

est plus réaliste qu’un simple :

```ruby
is_exchange = true
```

---

## 25. Conclusion

Le module Exchange Like a profondément changé Bitcoin Monitor.

Avant lui :

* l’application observait des données.

Après lui :

* elle commençait à interpréter des comportements.

Et cette nuance a transformé toute l’architecture.

Les développeurs ne construisaient plus seulement :

```text
des dashboards
```

Ils construisaient :

```text
des pipelines d’intelligence blockchain
```

---

## 26. Glossaire

### Exchange-like

Adresse ou comportement probablement associé à une plateforme d’échange.

---

### Heuristique

Règle probabiliste permettant d’inférer un comportement.

---

### UTXO

Unspent Transaction Output.

“Pièce” Bitcoin encore dépensable.

---

### Scanner

Pipeline parcourant la blockchain bloc par bloc.

---

### Cursor

Dernier bloc traité par un scanner.

---

### Lag

Différence entre :

```text
best block
-
last scanned block
```

---

### Heartbeat

Signal indiquant qu’un job est toujours vivant.

---

### Progression métier

État réel d’avancement d’un scanner :

```text
421 / 1000 blocs
42%
```

---

### Observabilité

Capacité à comprendre l’état réel du système.

---

### Backfill

Reconstruction historique d’un dataset à partir des anciens blocs.
