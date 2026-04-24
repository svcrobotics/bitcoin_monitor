# Cron vers Sidekiq : le moment où Bitcoin Monitor a cessé d’être une simple application Rails

> *Au début, les jobs de Bitcoin Monitor étaient simples.*
>
> Quelques scripts cron.
>
> Quelques tâches Rails.
>
> Quelques scanners lancés périodiquement.
>
> Et honnêtement :
>
> cela fonctionnait plutôt bien.
>
> Mais progressivement, quelque chose a changé.
>
> Les modules devenaient plus lourds.
>
> Les scans plus longs.
>
> Les datasets plus massifs.
>
> Les dépendances entre pipelines plus complexes.
>
> Et un jour, une question est apparue :
>
> > “Est-ce que cron est encore suffisant pour faire tourner Bitcoin Monitor ?”

---

## 1. Les débuts : cron partout

Comme beaucoup d’applications Rails orientées backend, Bitcoin Monitor utilisait au départ :

```text
cron
+
rake tasks
+
scripts shell
```

Le modèle était simple :

```text
*/10 * * * * scan_exchange.sh
0 * * * * whales_scan.sh
15 * * * * market_snapshot.sh
```

Chaque tâche :

* démarrait,
* exécutait un scan,
* écrivait dans PostgreSQL,
* puis quittait.

Simple.

Prévisible.

Facile à comprendre.

---

## 2. Pourquoi cron fonctionnait au début

Au départ :
les volumes étaient modestes.

Les jobs :

* terminaient rapidement,
* ne dépendaient pas fortement les uns des autres,
* ne nécessitaient pas de coordination avancée.

Et surtout :

> le système n’était pas encore “vivant”.

---

## 3. Le changement progressif

Puis les modules ont commencé à grossir.

D’abord :

* Whale Scan,
* puis Exchange Like,
* puis Cluster.

Et progressivement :
les scanners sont devenus :

* plus longs,
* plus lourds,
* plus dépendants les uns des autres.

---

## 4. Le premier symptôme

Un jour, quelque chose d’important est apparu dans `/system` :

```text
late
stuck
delay
runtime élevé
```

Au début :
cela semblait ponctuel.

Mais progressivement :
les retards s’accumulaient.

---

## 5. Le vrai problème n’était pas le code

Le vrai problème était :

> l’orchestration.

Cron ne sait pas :

* gérer les dépendances métier,
* coordonner des pipelines,
* suivre précisément les jobs,
* relancer intelligemment,
* distribuer les tâches,
* gérer des queues.

---

## 6. Les scanners deviennent des pipelines

C’est une transition fondamentale.

Avant :

```text
job = script
```

Après :

```text
job = pipeline vivant
```

Et cela change tout.

---

## 7. Cluster a révélé les limites

Le module Cluster a été l’un des premiers vrais signaux d’alerte.

Pourquoi ?

Parce qu’il combinait :

* scans massifs,
* merges,
* recalculs,
* métriques,
* signaux,
* refreshs.

Le runtime explosait.

Et surtout :
les jobs devenaient difficiles à superviser.

---

## 8. Le problème des jobs longs

Avec cron :
un job long pose plusieurs problèmes.

### Exemple

```text
*/10 * * * * cluster_scan
```

Mais si :

```text
cluster_scan
```

dure :

```text
18 minutes
```

alors :

* les exécutions se chevauchent,
* les locks deviennent critiques,
* les retards s’accumulent,
* le système dérive progressivement.

---

## 9. Les locks shell deviennent partout

Pour éviter les doubles exécutions :

des mécanismes comme :

```bash
flock
```

ont commencé à apparaître.

Par exemple :

```bash
flock -n /tmp/cluster_scan.lock ...
```

Cela fonctionnait.

Mais quelque chose devenait évident :

> le système essayait déjà de se comporter comme un orchestrateur de jobs.

---

## 10. Le dashboard `/system` devient central

À ce moment-là :
Bitcoin Monitor commence à développer une vraie supervision.

Le dashboard système affiche :

* runtimes,
* delays,
* jobs critiques,
* jobs en retard,
* freshness,
* recovery readiness.

Le système commence à vouloir répondre à une question :

> “Le pipeline est-il réellement sain ?”

---

## 11. Runtime ≠ progression

Un autre problème majeur apparaît.

Cron sait uniquement :

```text
le job tourne
```

Mais il ne sait pas :

* où le job en est,
* s’il progresse,
* ou s’il est bloqué.

Et cette nuance devient extrêmement importante.

---

## 12. Les jobs deviennent observables

Des métriques apparaissent progressivement :

```text
Cursor
Lag
Heartbeat
Delay
Progression
Capacity
```

Le système cesse progressivement d’être :

```text
des scripts shell.
```

Il devient :

```text
une plateforme observable.
```

---

## 13. Les dépendances entre modules explosent

Un autre problème apparaît rapidement.

Les modules commencent à dépendre les uns des autres :

```text
Whale Scan
   ↓
Exchange Like
   ↓
Observed UTXO
   ↓
Inflow / Outflow
   ↓
Signals
```

Avec cron :
la coordination devient fragile.

---

## 14. Les backfills deviennent dangereux

Les backfills massifs révèlent un autre problème.

Lorsqu’un scanner doit retraiter :

* des milliers de blocs,
* des millions d’UTXO,
* des datasets énormes,

cron devient difficile à piloter.

Pourquoi ?

Parce qu’il ne possède pas :

* de queue,
* de priorités,
* de retry intelligent,
* de contrôle distribué.

---

## 15. Redis apparaît naturellement

Progressivement :
un autre composant commence à devenir logique :

Redis

Pourquoi ?

Parce que Bitcoin Monitor commence à avoir besoin :

* de queues,
* de cache RAM,
* de coordination,
* de pipelines plus réactifs.

---

## 16. Le déclic Sidekiq

Puis un moment important arrive.

L’équipe réalise que :

> les jobs ne sont plus “secondaires”.

Ils sont devenus :

* le cœur du système,
* le moteur des pipelines,
* la colonne vertébrale de l’application.

Et à ce moment-là :
Sidekiq devient une évidence.

---

## 17. Pourquoi Sidekiq change tout

Avec Sidekiq :
les jobs deviennent :

* distribués,
* supervisables,
* retryables,
* parallélisables,
* priorisables.

Le modèle mental change complètement.

Avant :

```text
cron lance des scripts
```

Après :

```text
le système orchestre des pipelines
```

---

## 18. La transition mentale la plus importante

Le vrai changement n’était pas technique.

Le vrai changement était conceptuel.

Avant :

```text
Rails application
```

Après :

```text
data platform
```

Et cette différence change :

* l’architecture,
* le monitoring,
* les performances,
* les choix techniques.

---

## 19. Les futurs pipelines deviennent possibles

Grâce à Sidekiq :
plusieurs évolutions deviennent réalistes :

```text
bitcoind ZMQ
     ↓
new block
     ↓
enqueue incremental jobs
     ↓
cluster updates
     ↓
signals
     ↓
live dashboard
```

Le temps réel commence à devenir envisageable.

---

## 20. Les jobs cessent d’être synchrones

Une autre transformation importante apparaît.

Avant :
tout était relativement :

```text
séquentiel.
```

Après :
le système commence à penser :

```text
queues
workers
pipelines
events
```

C’est une énorme évolution d’architecture.

---

## 21. Redis ne sert plus seulement au cache

Au départ :
Redis semblait surtout utile pour :

* accélérer des lectures,
* stocker des datasets chauds.

Mais progressivement :
il devient aussi :

* coordinateur,
* broker,
* moteur de queues,
* infrastructure pipeline.

---

## 22. Les scanners deviennent distribuables

Avec Sidekiq :
un futur devient possible :

```text
ClusterScanWorker
ClusterMetricsWorker
ClusterSignalsWorker
```

potentiellement répartis :

* sur plusieurs processus,
* plusieurs machines,
* plusieurs queues spécialisées.

Le système devient scalable.

---

## 23. Le vrai objectif

L’objectif n’était pas :

```text
“utiliser Sidekiq parce que c’est moderne”
```

L’objectif était :

> permettre à Bitcoin Monitor de survivre à sa propre croissance.

---

## 24. Les leçons apprises

### Cron est excellent au début

Simple.
Fiable.
Parfait pour les petits pipelines.

---

### Les pipelines blockchain grossissent très vite

Beaucoup plus vite qu’on l’imagine.

---

### Les jobs longs changent complètement l’architecture

Ils nécessitent :

* supervision,
* progression,
* queues,
* orchestration.

---

### Runtime ≠ santé du système

Un job qui tourne n’est pas forcément :

```text
un job utile.
```

---

### Redis devient naturel dans les pipelines data

Pas uniquement pour le cache.

---

### Sidekiq représente souvent un changement de maturité

Passer à Sidekiq signifie souvent :

> que l’application devient un vrai système backend.

---

## 25. Conclusion

Le passage de cron vers Sidekiq a profondément changé Bitcoin Monitor.

Avant :

* l’application exécutait des scripts.

Après :

* elle orchestrait des pipelines blockchain complexes.

Et cette évolution a transformé :

* les scanners,
* la supervision,
* la résilience,
* les performances,
* et la manière même de penser le projet.

Parce qu’au final :

> une application blockchain sérieuse finit presque toujours par devenir un système distribué miniature.
