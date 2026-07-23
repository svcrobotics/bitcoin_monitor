# Fiche d’intervention — Résilience du watcher ZMQ

## Mission

Empêcher une erreur d’affichage Turbo de tuer le watcher chargé d’écouter les nouveaux blocs Bitcoin.

## Commit documenté

```text
bec7e1a Keep ZMQ watcher alive on broadcast errors
```

## Date

23 juillet 2026

---

## 1. État Git initial

```text
Branche : main
Commit de départ : 05922cb
Dépôt propre avant l’intervention ZMQ
```

La modification préexistante de `Procfile.dev` a été volontairement laissée hors du commit ZMQ.

---

## 2. Problème observé

Le service utilisateur suivant recevait correctement les nouveaux blocs Bitcoin :

```text
zmq-block-watcher.service
```

À chaque nouveau bloc, le watcher appelait :

```ruby
Realtime::BlockEventBroadcaster.call
```

Le broadcaster demandait le partial :

```text
system/realtime/latest_block
```

Mais le fichier correspondant n’existait pas :

```text
app/views/system/realtime/_latest_block.html.erb
```

Rails levait alors :

```text
ActionView::MissingTemplate
```

L’exception sortait de la boucle principale du watcher.

Conséquence :

```text
Nouveau bloc Bitcoin
        ↓
Événement ZMQ reçu
        ↓
Diffusion Turbo
        ↓
Partial absent
        ↓
Watcher arrêté
        ↓
Redémarrage automatique par systemd
```

---

## 3. Cause exacte

L’erreur provenait de deux éléments combinés :

1. le partial Turbo demandé par le broadcaster n’existait pas ;
2. l’appel au broadcaster n’était pas isolé du reste de la boucle ZMQ.

Une erreur appartenant uniquement à la couche d’affichage pouvait donc interrompre un processus chargé d’une fonction plus importante : écouter les événements Bitcoin Core.

---

## 4. Correction appliquée

### Partial ajouté

Création du fichier :

```text
app/views/system/realtime/_latest_block.html.erb
```

Le partial affiche :

* la hauteur du bloc ;
* un hash abrégé ;
* le hash complet dans l’attribut `title` ;
* l’heure de réception ;
* la racine HTML `#latest_block_live`.

### Diffusion Turbo rendue non fatale

Le script :

```text
bin/zmq_block_watcher
```

a été encapsulé dans le module :

```ruby
ZmqBlockWatcher
```

L’appel au broadcaster passe maintenant par :

```ruby
ZmqBlockWatcher.broadcast_block_event
```

Cette méthode capture uniquement les erreurs provenant de la diffusion Turbo.

En cas d’erreur :

* la classe de l’erreur est journalisée ;
* le message est journalisé ;
* la hauteur et le hash sont journalisés ;
* le watcher continue son traitement ;
* le prochain bloc peut toujours être reçu.

Les erreurs liées aux éléments suivants restent volontairement fatales et visibles :

* socket ZMQ ;
* RPC Bitcoin Core ;
* mise à jour du curseur ;
* production de l’événement Redis Stream ;
* enqueue Sidekiq.

---

## 5. Fonctionnement après correction

```text
Nouveau bloc Bitcoin
        ↓
Watcher ZMQ reçoit le hash
        ↓
Curseur PostgreSQL mis à jour
        ↓
Événement écrit dans Redis Stream
        ↓
Diffusion Turbo tentée
        ↓
Succès : interface mise à jour
Erreur : erreur journalisée
        ↓
Job consommateur enfilé
        ↓
Watcher attend le bloc suivant
```

La couche d’affichage ne peut plus interrompre l’écoute de Bitcoin Core.

---

## 6. Fichiers modifiés

```text
bin/zmq_block_watcher
app/views/system/realtime/_latest_block.html.erb
test/bin/zmq_block_watcher_test.rb
test/services/realtime/block_event_broadcaster_test.rb
test/views/system/realtime/latest_block_test.rb
```

Le fichier suivant n’a pas été inclus dans le commit :

```text
Procfile.dev
```

Sa modification appartenait à une autre intervention.

---

## 7. Tests exécutés

### Tests ciblés

```text
3 tests
17 assertions
0 échec
```

### Tests voisins temps réel et watcher

```text
17 tests
76 assertions
0 échec
```

### Total

```text
20 tests
93 assertions
0 échec
```

Contrôles supplémentaires :

```text
RuboCop ciblé : aucune infraction
Syntaxe Ruby : OK
git diff --check : OK
```

---

## 8. Validation réelle

Après le redémarrage contrôlé du service :

```text
MainPID=18538
NRestarts=0
ActiveState=active
SubState=running
```

Le bloc suivant a été reçu :

```text
Hauteur : 959203
Hash : 00000000000000000002048be8e7e35dc50544f7cff35c5ea5a57a6979e91029
```

Le curseur PostgreSQL a été mis à jour avec cette hauteur et ce hash.

L’événement a également été retrouvé dans le Redis Stream :

```text
bitcoin.blocks
```

Le processus était ensuite dans l’état :

```text
do_sys_poll
```

Cela signifie qu’il avait terminé le traitement et attendait normalement le bloc suivant.

Aucun nouveau message de ce type n’a été observé :

```text
ActionView::MissingTemplate
Main process exited
Failed with result
Scheduled restart job
```

---

## 9. Résultat

Avant :

```text
Erreur Turbo
→ watcher tué
→ redémarrage systemd à chaque bloc
```

Après :

```text
Erreur Turbo éventuelle
→ erreur journalisée
→ watcher toujours actif
→ écoute du bloc suivant
```

Le problème ZMQ est corrigé et validé en conditions réelles.

---

## 10. Commit

```text
bec7e1a Keep ZMQ watcher alive on broadcast errors
```

Le commit contient uniquement la correction ZMQ et ses tests.

---

## 11. État Git final de l’intervention

Après le commit ZMQ, une modification indépendante restait dans :

```text
Procfile.dev
```

Elle a ensuite été enregistrée dans un commit séparé :

```text
0523809 Reduce ActorProfile strict batch wait
```

Les deux missions sont donc séparées dans l’historique Git.

---

## Résumé de la mission

Le watcher ZMQ recevait correctement les blocs Bitcoin, mais une erreur dans la couche d’affichage Turbo arrêtait tout le processus.

L’intervention a séparé les responsabilités :

```text
Écoute Bitcoin Core = critique
Affichage Turbo = non critique
```

Une erreur d’interface ne peut désormais plus interrompre la réception des nouveaux blocs.
