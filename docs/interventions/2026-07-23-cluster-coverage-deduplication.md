# Fiche d’intervention — Déduplication de Cluster Coverage

## Mission

Supprimer les exécutions répétées inutiles de la maintenance Cluster Coverage et garantir qu’un seul prochain essai soit planifié.

## Commit documenté

```text
da76a4b Deduplicate Cluster Coverage maintenance scheduling
```

## Date

23 juillet 2026

---

## 1. État Git initial

```text
Branche : main
Commit de départ : 0523809
Dépôt propre
```

Le correctif Cluster Coverage a été développé dans une mission séparée des interventions précédentes.

Les commits déjà présents étaient :

```text
0523809 Reduce ActorProfile strict batch wait
bec7e1a Keep ZMQ watcher alive on broadcast errors
05922cb Protect test runs from Redis DB 0
```

---

## 2. Problème observé

Le job suivant était exécuté plusieurs fois presque simultanément :

```ruby
Clusters::Coverage::MaintenanceJob
```

Les journaux affichaient plusieurs refus dans la même seconde :

```text
cluster_coverage_maintenance skipped
reason=pipeline_controller_denied
decision.reason=layer1_realtime_priority
retry_in=120
```

Exemple de comportement observé :

```text
11:30:40 tentative refusée
11:30:40 tentative refusée
11:30:40 tentative refusée
11:30:41 tentative refusée
11:30:42 tentative refusée
```

Chaque job recevait correctement un délai de 120 secondes, mais plusieurs copies identiques existaient déjà.

Conséquences :

* répétition inutile des snapshots du pipeline ;
* bruit important dans les journaux ;
* appels répétés à PostgreSQL et Redis ;
* consultations inutiles du contrôleur ;
* maintien d’une grappe permanente de jobs programmés ;
* difficulté à comprendre l’état réel de Cluster Coverage.

---

## 3. État Redis avant correction

Le diagnostic a trouvé :

```text
queue=0
scheduled=24
retry=0
active=0
marker="1403"
```

Les 24 jobs avaient :

* des JID différents ;
* les mêmes arguments ;
* des échéances regroupées dans les mêmes secondes ;
* la même responsabilité de maintenance.

Le problème n’était donc pas un retry Sidekiq en erreur, mais la présence de 24 chaînes indépendantes d’auto-replanification.

---

## 4. Sources d’enqueue identifiées

Deux producteurs existaient.

### Source A — Démarrage du worker

Fichier :

```text
config/initializers/cluster_coverage_startup.rb
```

Conditions :

```text
CLUSTER_COVERAGE_WORKER=1
verrou de démarrage de 60 secondes
```

Ancien comportement :

```ruby
Clusters::Coverage::MaintenanceJob.perform_later
```

La déduplication reposait uniquement sur le verrou de démarrage.

Elle ne vérifiait pas :

* la file `cluster_coverage` ;
* le Scheduled Set ;
* le Retry Set ;
* les jobs actuellement actifs.

### Source B — Auto-replanification

Fichier :

```text
app/jobs/clusters/coverage/maintenance_job.rb
```

Dans le bloc `ensure`, le job se reprogrammait avec :

```text
decision[:retry_in]
```

ou, à défaut :

```text
120 secondes
```

Cette source utilisait un marqueur Redis partagé.

---

## 5. Cause exacte

Le défaut provenait de :

```ruby
clear_schedule_marker
```

Cette méthode était appelée au démarrage de chaque copie du job.

Elle supprimait le marqueur partagé sans vérifier que le job courant en était propriétaire.

Le fonctionnement réel était donc :

```text
Copie 1 démarre
→ supprime le marqueur

Copie 2 démarre
→ supprime le marqueur créé par la copie 1

Copie 3 démarre
→ supprime le marqueur créé par la copie 2
```

Chaque copie consultait ensuite le contrôleur, recevait :

```text
retry_in=120
```

puis créait son propre successeur.

Le délai de 120 secondes était bien respecté individuellement, mais il était appliqué indépendamment par chacune des 24 copies.

Le nombre de jobs restait donc stable :

```text
24 jobs exécutés
→ 24 nouveaux jobs programmés
```

Les schedulers généraux n’étaient pas responsables.

Aucun autre cron, watchdog, callback ou mécanisme de réveil n’enfilait ce job.

---

## 6. Correction appliquée

Le correctif introduit une propriété explicite du marqueur Redis.

### États du marqueur

Un job programmé possède un marqueur :

```text
scheduled:<token>
```

Lorsqu’il commence son exécution, il devient :

```text
active:<job_id>:<token>
```

Le token permet de savoir quel job possède réellement la planification.

### Transitions atomiques

Les transitions sont réalisées avec des scripts Lua dans Redis.

Elles garantissent que :

* seul le propriétaire peut réclamer le marqueur ;
* seul le propriétaire peut le remplacer ;
* seul le propriétaire peut le supprimer ;
* un ancien job ne peut pas supprimer le marqueur d’un job plus récent ;
* plusieurs producteurs concurrents ne peuvent pas acquérir la planification simultanément.

### Enqueue unique

La méthode suivante a été ajoutée :

```ruby
Clusters::Coverage::MaintenanceJob.enqueue_once
```

Elle vérifie l’existence d’un job Cluster Coverage dans :

* la queue ;
* le Scheduled Set ;
* le Retry Set ;
* les travaux Sidekiq actifs.

Puis elle utilise :

```text
SET NX
```

pour arbitrer atomiquement plusieurs demandes concurrentes.

### Auto-replanification unique

Le job courant utilise :

```ruby
reschedule_once
```

pour remplacer son marqueur `active` par un nouveau marqueur `scheduled`.

Cette transition n’est possible que si le job possède toujours le marqueur attendu.

---

## 7. Détection structurelle des jobs

L’ancienne détection pouvait s’appuyer sur une recherche textuelle trop large.

La détection reconnaît maintenant explicitement les champs :

```text
wrapped
class
job_class
args.first["job_class"]
```

Elle supporte :

* les payloads Hash ;
* les payloads JSON Sidekiq ;
* les payloads ActiveJob ;
* les jobs dans la queue ;
* les jobs programmés ;
* les retries ;
* les travaux actifs.

Un simple argument contenant le texte :

```text
Clusters::Coverage::MaintenanceJob
```

ne suffit plus à produire un faux positif.

---

## 8. Gestion du chemin disabled

Lorsqu’un job programmé démarre alors que la maintenance a été désactivée :

```text
CLUSTER_COVERAGE_MAINTENANCE_ENABLED=false
```

il libère uniquement le marqueur correspondant à son propre `schedule_token`.

La suppression reste :

* atomique ;
* conditionnelle ;
* limitée au marqueur possédé.

Le job :

* retourne le résultat `disabled` ;
* ne programme aucun successeur ;
* ne laisse pas de marqueur orphelin ;
* ne peut pas supprimer le marqueur d’un autre job.

---

## 9. Fonctionnement avant correction

```text
Initializer ou job courant
        ↓
Nouveau job programmé
        ↓
Chaque copie supprime le marqueur partagé
        ↓
Chaque copie consulte le contrôleur
        ↓
Chaque copie reçoit retry_in=120
        ↓
Chaque copie programme un successeur
        ↓
24 jobs restent présents
```

---

## 10. Fonctionnement après correction

```text
Demande de planification
        ↓
Inspection queue / scheduled / retry / active
        ↓
Réservation atomique SET NX
        ↓
Un seul job obtient scheduled:<token>
        ↓
Les autres demandes sont refusées
reason=already_scheduled
        ↓
Le job commence
        ↓
scheduled:<token>
devient
active:<job_id>:<token>
        ↓
Le contrôleur refuse temporairement
retry_in=120
        ↓
Le propriétaire remplace atomiquement
active:<...>
par
scheduled:<nouveau_token>
        ↓
Une seule prochaine tentative
```

---

## 11. Journalisation après correction

Lorsqu’une planification est acceptée :

```text
[cluster_coverage_maintenance]
rescheduled=true
retry_in=120
scheduled_at=...
source=job
```

Lorsqu’une demande est refusée comme doublon :

```text
[cluster_coverage_maintenance]
rescheduled=false
reason=already_scheduled
```

Les doublons sortent avant de consulter le contrôleur.

Les snapshots complets du pipeline ne sont donc plus répétés plusieurs fois par seconde.

---

## 12. Fichiers modifiés

```text
app/jobs/clusters/coverage/maintenance_job.rb
config/initializers/cluster_coverage_startup.rb
test/jobs/clusters/coverage/maintenance_job_test.rb
```

Aucun fichier appartenant aux modules suivants n’a été modifié :

* Layer1 ;
* Cluster strict ;
* ActorProfile ;
* ActorBehavior ;
* ActorLabels.

Les règles métier de couverture et les priorités du contrôleur n’ont pas changé.

---

## 13. Tests exécutés

### Tests ciblés

```text
14 tests
56 assertions
0 failure
0 error
```

### Tests voisins

Les tests des jobs Coverage, de la configuration du Procfile et du scheduler strict ont été exécutés avec quatre processus.

```text
74 tests
349 assertions
0 failure
0 error
```

### Contrôles supplémentaires

```text
RuboCop : aucune infraction
Syntaxe Ruby : OK
git diff --check : OK
Résidus Redis test /15 : 0
```

Les tests utilisent une clé Redis unique afin d’éviter les collisions entre processus parallèles.

L’adaptateur ActiveJob est restauré après chaque test.

---

## 14. Validation réelle avant commit

Sans purge de Redis développement et sans redémarrage manuel initial, l’état a convergé naturellement de :

```text
scheduled=24
```

vers :

```text
scheduled=1
```

État observé :

```text
queue=0
scheduled=1
retry=0
active=0
marker="scheduled:04da89ba69bf564fa35eb4cb5c87e79d"
```

Les journaux ont ensuite montré :

```text
04:43:54 tentative refusée
04:43:54 rescheduled=true retry_in=120
scheduled_at=04:45:54

04:45:57 tentative refusée
04:45:57 rescheduled=true retry_in=120
scheduled_at=04:47:57
```

La grappe historique de 24 jobs a donc disparu naturellement.

---

## 15. Validation réelle après redémarrage

Après création du commit, le service Tansa a été redémarré de façon contrôlée :

```text
tansa-dev.service
ActiveState=active
SubState=running
```

État Cluster Coverage observé :

```text
queue=0
scheduled=1
retry=0
marker="scheduled:21ab3f3a1c3af1e00975b3202d22ab79"
```

Séquence après redémarrage :

```text
04:58:18 tentative refusée
04:58:18 successeur planifié pour 05:00:18

05:00:21 initializer refusé
reason=already_scheduled

05:00:29 tentative refusée
05:00:29 successeur planifié pour 05:02:29
```

L’initializer de démarrage n’a donc pas créé de deuxième chaîne.

---

## 16. Résultat

Avant :

```text
24 copies
→ 24 consultations du contrôleur
→ 24 successeurs
→ bruit permanent
```

Après :

```text
1 propriétaire
→ 1 consultation du contrôleur
→ 1 successeur
→ une tentative toutes les 120 secondes
```

Le problème Cluster Coverage est corrigé et validé en conditions réelles.

---

## 17. Commit

```text
da76a4b Deduplicate Cluster Coverage maintenance scheduling
```

Ce commit contient uniquement le correctif Cluster Coverage et ses tests.

---

## 18. État Git final

La fiche ZMQ avait été créée dans une mission documentaire séparée.

Après le commit Cluster Coverage, la documentation a été enregistrée séparément dans :

```text
67f6674 Document ZMQ watcher resilience intervention
```

Puis les commits ont été poussés vers :

```text
origin/main
```

Historique final :

```text
67f6674 Document ZMQ watcher resilience intervention
da76a4b Deduplicate Cluster Coverage maintenance scheduling
0523809 Reduce ActorProfile strict batch wait
bec7e1a Keep ZMQ watcher alive on broadcast errors
05922cb Protect test runs from Redis DB 0
```

Le dépôt était propre et synchronisé après le push.

---

## Résumé de la mission

Cluster Coverage ne souffrait pas d’un mauvais délai de retry.

Le vrai problème était la propriété du marqueur de planification.

Chaque copie supprimait le marqueur partagé, puis recréait sa propre chaîne.

La correction introduit une règle simple :

```text
Un job ne peut modifier que le marqueur qu’il possède.
```

Cette propriété est garantie atomiquement dans Redis.

Le système est passé de 24 chaînes concurrentes à une seule chaîne de maintenance contrôlée.
