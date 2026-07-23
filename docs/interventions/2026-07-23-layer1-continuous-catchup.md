# Fiche d’intervention — Rattrapage continu de Layer1

## Mission

Faire en sorte que Layer1 traite tous les blocs Bitcoin disponibles jusqu’au tip, sans attendre que son retard augmente artificiellement.

## Commit documenté

```text
e9f112d Keep Layer1 caught up to Bitcoin Core
```

## Date

23 juillet 2026

---

## 1. État Git initial

```text
Branche : main
Commit de départ : 649b8bd
Dépôt propre
```

Historique présent avant l’intervention :

```text
649b8bd Document Cluster Coverage deduplication intervention
67f6674 Document ZMQ watcher resilience intervention
da76a4b Deduplicate Cluster Coverage maintenance scheduling
0523809 Reduce ActorProfile strict batch wait
bec7e1a Keep ZMQ watcher alive on broadcast errors
```

---

## 2. Problème observé

Layer1 utilisait une hystérésis entre deux seuils :

```text
TANSA_BACKFILL_LAYER1_START_LAG=10
TANSA_BACKFILL_LAYER1_STOP_LAG=2
```

Le fonctionnement était :

```text
Layer1 rattrape jusqu’à lag 2
        ↓
Priorité donnée aux modules aval
        ↓
Layer1 attend
        ↓
Le retard augmente jusqu’à lag 10
        ↓
Layer1 reprend
        ↓
Retour à lag 2
```

Layer1 ne cherchait donc pas à rester continuellement au niveau de Bitcoin Core.

Un diagnostic réel avait montré :

```text
Bitcoin Core = 959210
Layer1 = 959208
lag = 2
phase = downstream_catchup
aucun job Layer1 actif
```

Layer1 était volontairement arrêté alors que deux blocs restaient disponibles.

---

## 3. Pourquoi ce comportement n’était plus adapté

Sur HDD, Layer1 pouvait prendre environ cinq minutes par bloc.

Après passage au SSD, une mesure sur 46 blocs a donné :

```text
Temps total : 6 min 52,7 s
Temps moyen : 9,0 s
Médiane p50 : 9,1 s
p90 : 10,7 s
Minimum : 0,3 s
Maximum : 13,5 s
```

Le traitement est environ 33 fois plus rapide qu’avant.

Un bloc Bitcoin arrivant en moyenne beaucoup moins souvent que le temps nécessaire à Layer1 pour le traiter, il n’était plus utile de laisser volontairement plusieurs blocs s’accumuler.

---

## 4. Cause exacte

L’hystérésis se trouvait dans :

```text
app/services/system/development_backfill_phase.rb
```

La logique utilisait deux phases :

```text
layer1_catchup
downstream_catchup
```

Ancienne règle :

```text
lag <= stop_lag
→ downstream_catchup

lag >= start_lag
→ layer1_catchup

lag entre les deux seuils
→ conserver la phase précédente
→ reason=hysteresis_hold
```

Avec les valeurs :

```text
stop_lag = 2
start_lag = 10
```

Layer1 pouvait donc rester inactif avec un retard compris entre 2 et 9 blocs.

---

## 5. Chemin de réveil Layer1

Le chemin complet d’un nouveau bloc est :

```text
Bitcoin Core
        ↓
Watcher ZMQ
        ↓
Redis Stream bitcoin.blocks
        ↓
Realtime::BlockStreamConsumerJob
        ↓
Realtime::BlockStreamConsumer
        ↓
StrictPipeline::SchedulerWakeup
        ↓
StrictPipeline::SchedulerJob
        ↓
StrictPipeline::Scheduler
        ↓
Layer1::StrictTipSyncJob
        ↓
Layer1::StrictTipSyncer
        ↓
checkpoint + 1
```

Le signal temps réel existait déjà.

La correction n’a donc pas créé un deuxième moteur Layer1. Elle réutilise le scheduler strict et ses protections de déduplication.

---

## 6. Nouveau contrat de priorité

La nouvelle règle est :

```text
Layer1 lag > 0
→ Layer1 prioritaire

Layer1 lag = 0
→ Cluster et modules aval admissibles
```

L’ancienne zone d’attente volontaire entre lag 2 et lag 10 disparaît.

Les anciens seuils restent présents comme configuration compatible et télémétrie, mais ils ne commandent plus la priorité Layer1.

---

## 7. Nouveau fonctionnement normal

Lorsqu’un nouveau bloc arrive :

```text
Bitcoin Core gagne une hauteur
        ↓
Layer1 passe temporairement à lag 1
        ↓
Le scheduler enfile le bloc suivant
        ↓
Layer1 traite checkpoint + 1
        ↓
Layer1 revient à lag 0
        ↓
Cluster traite le même bloc
        ↓
Cluster revient à lag 0
```

État attendu au repos :

```text
Layer1 lag = 0
Cluster global lag = 0
```

Un lag temporaire de 1 pendant quelques secondes est normal.

---

## 8. Fonctionnement après un arrêt prolongé

Exemple :

```text
Bitcoin Core = 959500
Layer1 = 959400
lag = 100
```

Layer1 doit traiter strictement :

```text
959401
959402
959403
...
959500
```

Il ne s’arrête plus à lag 2.

Il ne rend la priorité à Cluster qu’une fois :

```text
Layer1 processed_height = Bitcoin Core best_height
lag = 0
```

Cluster peut alors rattraper Layer1.

---

## 9. Ordre strict conservé

Le syncer conserve :

```text
from_height = continuous_tip + 1
```

Un test a vérifié :

```text
Bitcoin Core = 959500
checkpoint = 959400
max_blocks = 1
```

Résultat attendu et obtenu :

```text
from_height = 959401
to_height = 959401
```

Layer1 ne saute donc aucune hauteur et ne traite jamais directement le tip si des blocs intermédiaires manquent.

---

## 10. Réveil après chaque bloc

Après chaque segment traité, `Layer1::StrictTipSyncJob` réveille le scheduler dédupliqué.

Si du retard reste :

```text
reason=layer1_block_completed_with_backlog
```

Le prochain bloc est traité.

Si Layer1 atteint le tip :

```text
reason=layer1_caught_up
```

Le scheduler transmet rapidement la priorité à Cluster.

Si les hauteurs sont inconnues :

```text
reason=layer1_catchup_state_unknown
wait=30 secondes
```

Le système ne déclare jamais artificiellement Layer1 à jour lorsque l’état est inconnu.

---

## 11. Gestion de l’état inconnu

L’ancienne version intermédiaire pouvait interpréter une erreur de lecture comme :

```text
lag=0
state=caught_up
```

Cette situation a été corrigée.

La logique finale distingue :

```text
known=true, lag>0
→ continuer

known=true, lag=0
→ caught_up

known=false, lag=nil
→ réessayer dans 30 secondes
```

Une indisponibilité temporaire de Bitcoin Core ou du checkpoint ne peut donc pas faire passer prématurément la priorité à Cluster.

---

## 12. Protections conservées

La mission n’a pas modifié le traitement interne ou la certification Layer1.

Protections conservées :

* concurrence Layer1 inchangée ;
* un seul worker Layer1 strict ;
* ordre `checkpoint + 1` ;
* queue Layer1 dédupliquée ;
* worker actif détecté ;
* Scheduled Set et Retry Set vérifiés ;
* verrou du syncer conservé ;
* lease strict I/O conservée ;
* contrôle des buffers conservé ;
* aucune hauteur sautée ;
* aucun traitement Layer1 simultané ;
* aucun changement de migration ou de données.

Les protections observées restent actives :

```text
already_active
scheduler_transition_in_progress
earlier_pending_wakeup_already_recorded
```

Plusieurs réveils possibles convergent toujours vers une seule décision effective.

---

## 13. Fichiers modifiés

```text
app/jobs/layer1/strict_tip_sync_job.rb
app/services/realtime/block_stream_consumer.rb
app/services/strict_pipeline/scheduler.rb
app/services/system/development_backfill_phase.rb
app/services/system/pipeline_controller.rb
test/jobs/layer1/strict_tip_sync_job_test.rb
test/services/layer1/strict_tip_syncer_test.rb
test/services/realtime/block_stream_consumer_test.rb
test/services/system/development_backfill_phase_test.rb
test/services/system/pipeline_controller_development_backfill_test.rb
```

Aucune migration n’a été créée.

Aucune table n’a été modifiée.

---

## 14. Tests exécutés

### Tests ciblés initiaux

```text
31 tests
130 assertions
0 failure
0 error
```

### Tests voisins complets

Contrôleur, scheduler, réveil, locks, jobs Layer1 et Cluster :

```text
267 tests
967 assertions
0 failure
0 error
```

### Validation complémentaire

```text
72 tests
223 assertions
0 failure
0 error
```

### Tests après correction de l’état inconnu

```text
8 tests
31 assertions
0 échec
```

Scheduler et réveils voisins :

```text
65 tests
178 assertions
0 échec
```

### Validation finale des nouveaux tests

Layer1 continu :

```text
11 tests
39 assertions
0 échec
```

Scheduler et contrôleur :

```text
144 tests
503 assertions
0 échec
```

Contrôles supplémentaires :

```text
git diff --check : OK
RuboCop sur les fichiers directement corrigés : aucune infraction
```

Des offenses de formatage préexistantes existaient dans certains fichiers voisins. Elles n’ont pas été corrigées afin d’éviter un reformatage hors périmètre.

---

## 15. Validation réelle avant le nouveau bloc

Après chargement du correctif :

```text
bitcoin_core=959214
layer1=959214
layer1_lag=0
cluster=959214
cluster_global_lag=0
layer1_queue=0
cluster_queue=0
retries=0
dead=0
```

Derniers temps Layer1 observés :

```text
959214 : 9,191 s
959213 : 9,305 s
959212 : 8,874 s
959211 : 3,500 s
959210 : 8,576 s
```

Le pipeline était entièrement à jour et sans erreur.

---

## 16. Validation réelle sur un nouveau bloc

À `06:21:42`, Bitcoin Core a reçu le bloc `959215`.

Le scheduler a immédiatement observé :

```text
best_height=959215
processed_height=959214
lag=1
action=enqueue
next_height=959215
```

À `06:21:52`, environ dix secondes plus tard :

```text
best_height=959215
processed_height=959215
lag=0
state=caught_up
```

La séquence réelle est donc :

```text
06:21:42 lag=1 action=enqueue
06:21:52 lag=0 state=caught_up
```

La suppression de l’attente volontaire est validée.

---

## 17. Passage de la priorité à Cluster

Après que Layer1 a atteint le tip, Cluster a pris la suite.

État observé :

```text
Layer1 processed_height=959215
Layer1 lag=0

Cluster processed_height=959214
Cluster lag=1
Cluster processing=true
Cluster processing_height=959215
Cluster worker_busy=true
```

Cluster Coverage a été correctement refusé pendant ce traitement :

```text
reason=cluster_strict_priority
```

Le lease strict I/O appartenait à Cluster :

```text
strict_io owner=cluster
```

Cela confirme la séquence :

```text
Layer1 atteint lag 0
→ Cluster traite le bloc
→ les maintenances attendent
```

---

## 18. Fonctionnement avant correction

```text
Nouveau bloc
        ↓
Layer1 peut traiter jusqu’à lag 2
        ↓
Passage en downstream_catchup
        ↓
hysteresis_hold
        ↓
Attente jusqu’à lag 10
        ↓
Nouveau rattrapage
```

---

## 19. Fonctionnement après correction

```text
Nouveau bloc
        ↓
lag=1
        ↓
Layer1 prioritaire immédiatement
        ↓
traitement checkpoint + 1
        ↓
si lag restant > 0
→ traiter le suivant
        ↓
si lag = 0
→ Cluster admissible
```

Après un arrêt important :

```text
lag=100
→ Layer1 traite 100 blocs dans l’ordre
→ lag=0
→ Cluster rattrape
```

---

## 20. Résultat

Avant :

```text
Layer1 maintenait volontairement un retard compris entre 2 et 10 blocs.
```

Après :

```text
Layer1 traite tout retard positif et rend la priorité uniquement à lag zéro.
```

Le pipeline suit maintenant un ordre simple :

```text
Bitcoin Core
→ Layer1 à jour
→ Cluster à jour
→ modules aval
```

---

## 21. Commit

```text
e9f112d Keep Layer1 caught up to Bitcoin Core
```

Le commit contient uniquement le correctif Layer1 continu et ses tests.

---

## 22. État Git après commit

Après création du commit :

```text
e9f112d HEAD -> main
649b8bd origin/main
```

Le dépôt local était propre.

Le commit n’avait pas encore été poussé au moment de la création de cette fiche.

---

## Résumé de la mission

Le problème n’était pas la vitesse de Layer1, mais son orchestration.

Le SSD permet maintenant de traiter un bloc en environ neuf secondes.

La règle d’hystérésis héritée du HDD maintenait inutilement un retard entre deux et dix blocs.

La correction remplace cette règle par un contrat direct :

```text
lag > 0
→ Layer1 travaille

lag = 0
→ Cluster travaille
```

La validation réelle a montré :

```text
lag 1
→ traitement immédiat
→ lag 0 en environ 10 secondes
→ Cluster prend la suite
```
