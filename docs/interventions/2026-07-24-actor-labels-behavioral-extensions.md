# Mission : enrichir les sorties ActorLabels

## Résumé

Tansa présentait quatre contrats de sortie ActorLabels :

- Exchange Flow ;
- Whale Flow ;
- Service Flow ;
- ETF Flow.

La mission ajoute deux sorties comportementales observables :

- Retention Flow avec `high_retention_behavior` ;
- Spend-Through Flow avec `high_spend_through_behavior`.

Ces labels décrivent des comportements Bitcoin observés. Ils ne constituent pas une identification de dépositaire, de service de paiement ou d’entité économique.

## Problème

Quatre catégories ne suffisaient pas à représenter les comportements disponibles dans les données certifiées de Tansa.

Les familles Mining, Custody, Payment et Privacy ont été étudiées, mais les faits actuellement disponibles ne permettent pas encore de les publier de manière suffisamment fiable.

## État Git initial

- Branche : `main`
- Commit initial : `0748ac4`
- Dépôt propre
- Aucun fichier modifié ou non suivi

## Analyse de l’existant

L’audit a distingué :

- les signaux internes ;
- les candidats ;
- les comportements confirmés ;
- les identités vérifiées ;
- les quatre contrats de sortie affichés.

Données observées pendant l’audit :

- 48 ActorLabels initialement persistés ;
- 32 566 snapshots strict_v2 certifiés lors du premier relevé ;
- strict_v2 conservé comme moteur actif ;
- Heavy conservé comme mécanisme de confirmation séparé.

Les catégories Mining, Custody, Payment et Privacy ont été écartées du premier lot faute de preuves certifiées suffisantes.

## Calibration

Population cohérente utilisée :

- 31 368 snapshots ActorBehavior strict_v2 courants et certifiés ;
- aucun fingerprint invalide ;
- aucun fait financier manquant ;
- aucune divergence entre snapshot et profil.

Seuils retenus :

### high_retention_behavior

- `balance_btc / total_received_btc >= 0,80` ;
- `inflow_count >= 20`.

Interprétation :

Au moins 80 % du volume reçu demeure dans les UTXO du cluster, avec au moins 20 transactions reçues.

Ce label décrit une forte rétention observée, pas une identité de dépositaire.

### high_spend_through_behavior

- `total_sent_btc / total_received_btc >= 0,95` ;
- `outflow_count >= 20`.

Interprétation :

Au moins 95 % du volume reçu a déjà été consommé par des transactions de dépense, avec au moins 20 transactions de dépense.

Ce label décrit une forte redépense historique. Il ne prouve pas une distribution vers plusieurs bénéficiaires.

## Implémentation

Chaîne ajoutée :

`ActorBehaviors::CertifiedScope`
→ `BehavioralExtensionRuleSet`
→ `BehavioralExtensionWriter`
→ `BehavioralExtensionBatch`

Source dédiée :

`actor_labels_from_behavioral_extension_v1`

Les deux labels sont isolés de strict_v2 et de Heavy.

Le batch reste manuel et fonctionne en dry-run par défaut. Aucun scheduler, aucune queue et aucune migration n’ont été ajoutés.

## Fichiers applicatifs

Créés :

- `app/services/actor_labels/behavioral_extension_rule_set.rb`
- `app/services/actor_labels/behavioral_extension_writer.rb`
- `app/services/actor_labels/behavioral_extension_batch.rb`
- `test/services/actor_labels/behavioral_extension_test.rb`

Modifiés :

- `app/models/actor_label.rb`
- `app/views/questions/answers/_actor_labels.html.erb`
- `test/views/actor_labels_view_test.rb`

## Réconciliation

La première activation a révélé qu’un label associé à un snapshot sorti de CertifiedScope pouvait rester persisté.

Cause :

Le batch parcourait uniquement les snapshots encore présents dans CertifiedScope. Une sortie liée à un ancien snapshot n’était donc jamais présentée au writer pour suppression.

Correction :

À la fin d’un scan complet, le batch :

1. reconstruit l’ensemble global attendu ;
2. crée ou actualise les sorties manquantes ;
3. supprime les sorties obsolètes ;
4. limite toutes les mutations à sa source dédiée.

La réconciliation fonctionne également lorsque le curseur se trouve déjà à la fin du scope et que la page courante est vide.

## Tests

Résultat final :

- 14 tests ;
- 135 assertions ;
- 0 failure ;
- 0 error.

Les tests couvrent notamment :

- seuils exacts ;
- snapshots certifiés et courants ;
- idempotence ;
- traçabilité ;
- source isolée ;
- préservation de strict_v2 et Heavy ;
- dry-run sans mutation ;
- page finale vide ;
- création des sorties absentes ;
- suppression des sorties obsolètes ;
- échec du scan global sans mutation ;
- absence de scheduler ;
- contrats affichés dans la vue.

## Validation réelle

Dry-run final avec curseur en fin de scope :

- page courante : 0 snapshot ;
- ensemble global correctement recalculé ;
- aucune écriture en dry-run.

Réconciliation réelle finale :

- ensemble attendu au moment du batch : 628 labels ;
- high_retention_behavior persistés : 4 ;
- high_spend_through_behavior persistés : 624 ;
- total persisté : 628 ;
- doublons : 0 ;
- preuves manquantes : 0 ;
- métadonnées manquantes : 0 ;
- erreurs : 0.

strict_v2 et Heavy sont restés inchangés par l’extension.

## Résultat dans l’interface

Deux cartes ont été ajoutées :

- Retention Flow → `high_retention_behavior` ;
- Spend-Through Flow → `high_spend_through_behavior`.

État affiché :

`Shadow · observation active`

Les compteurs sont lus exclusivement depuis la source comportementale dédiée.

## Limites

- aucun scheduler n’actualise automatiquement ces labels ;
- les compteurs peuvent évoluer avec le pipeline ;
- aucun module aval ne consomme encore ces sorties ;
- la rétention ne prouve pas une activité de custody ;
- la redépense ne prouve pas une distribution économique ;
- Mining, Payment, Privacy et Institutional nécessitent encore de nouveaux faits ou des preuves externes.

## Commit applicatif

`40f5941 Add shadow ActorLabels behavioral extensions`

## État Git avant documentation

- Branche : `main`
- Dépôt propre
- main en avance d’un commit sur origin/main
