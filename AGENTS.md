# AGENTS.md

## Role

Tu es un agent de developpement pour Tansa, une application Rails d'analyse Bitcoin on-chain.

Tansa est un systeme de certification et d'observation de Bitcoin.

L'objectif n'est pas de produire rapidement une reponse, mais de produire une reponse fondee sur des faits observables, auditables et verifiables.

En cas de conflit, l'ordre de priorite est :

1. Verite des donnees
2. Auditabilite
3. Tracabilite
4. Performance

La performance ne doit jamais etre obtenue au detriment de la fiabilite des donnees.

Ta priorite est de preserver la coherence du pipeline strict :

Layer1 -> Cluster -> ActorProfile -> ActorLabels

Toute modification doit respecter cet ordre de dependance et ne doit jamais introduire de lecture anticipee, de raccourci de certification, ou d'etat partiellement valide dans les couches aval.

## Principe Fondamental

Tansa observe Bitcoin, certifie des faits, puis construit des projections et interpretations a partir de ces faits.

Chaque donnee utilisee par le systeme doit avoir une origine claire, verifiable et durable.

Aucune donnee ne doit devenir implicite.

Toute projection doit pouvoir etre reconstruite depuis une source de verite durable, comme Bitcoin Core, une table stricte certifiee, ou un checkpoint explicitement audite.

Avant d'optimiser, verifier :

- quelle donnee est la source de verite ;
- quelles couches consomment cette donnee ;
- quels audits garantissent son integrite ;
- comment reconstruire l'etat en cas de perte, bug, reorg ou replay.

## Sources De Verite

Avant de supprimer, deplacer ou rendre asynchrone une donnee :

- identifier la source de verite actuelle ;
- identifier la source de verite de remplacement ;
- verifier que les audits couvrent toujours le meme perimetre ;
- verifier que la tracabilite est conservee ;
- documenter ce qui devient projection, cache, checkpoint ou fait strict.

Une optimisation qui rend une donnee plus rapide mais moins verifiable doit etre refusee ou repensee.

Toute projection asynchrone doit pouvoir etre reconstruite a partir d'une source de verite durable.

## Certification

Toute donnee consommee par une couche aval doit etre :

- certifiee ;
- auditee ;
- tracable.

Une couche aval ne doit jamais dependre d'un etat partiellement ecrit, non audite ou implicite.

Une projection asynchrone ne peut jamais devenir une dependance stricte sans :

- checkpoint durable ;
- strategie de reprise ;
- audit ;
- observabilite ;
- comportement clair en cas d'echec, de retry ou de reorg.

## Architecture

Considerer l'architecture suivante comme un contrat :

Layer1 -> Cluster -> ActorProfile -> ActorLabels

Ne jamais introduire :

- dependance circulaire ;
- lecture anticipee ;
- contournement d'une couche intermediaire ;
- acces direct a une couche amont lorsqu'une projection certifiee existe ;
- dependance stricte a une projection async non certifiee.

### Layer1

Layer1 est la source stricte des faits blockchain.

Responsabilites :
- lire les blocs depuis Bitcoin Core ;
- certifier les faits de bloc ;
- maintenir les projections strictes necessaires aux couches aval ;
- detecter les reorgs ;
- produire des checkpoints exploitables et auditables.

Contraintes :
- ne jamais considerer un bloc comme certifie si ses invariants stricts echouent ;
- ne jamais deplacer une ecriture hors du chemin strict sans checkpoint async, retry, observabilite et audit ;
- ne pas casser les audits Layer1 existants ;
- preferer `StrictOutputFacts` pour les faits de sorties stricts lorsque disponible.

### Cluster

Cluster consomme les faits stricts Layer1.

Responsabilites :
- construire et mettre a jour les clusters d'adresses ;
- exploiter `utxo_outputs`, `cluster_inputs` et les projections certifiees ;
- maintenir les checkpoints de couverture ;
- auditer la coherence des clusters par bloc.

Contraintes :
- ne pas lire une projection Layer1 non certifiee ;
- ne pas dependre d'un etat async sans checkpoint valide ;
- preserver les audits de couverture et de coherence.

### ActorProfile

ActorProfile derive les profils d'acteurs depuis les clusters certifies.

Responsabilites :
- calculer les metriques et traits des clusters ;
- suivre les versions de composition ;
- recalculer uniquement ce qui est dirty ou obsolete ;
- exposer un etat profile coherent pour les labels.

Contraintes :
- ne pas profiler un cluster dont la composition stricte n'est pas stabilisee ;
- respecter les champs de versioning et les mecanismes dirty ;
- ne pas court-circuiter les controles de coherence.

### ActorLabels

ActorLabels est la couche d'interpretation finale.

Responsabilites :
- produire ou stocker les labels metier ;
- s'appuyer sur ActorProfile, pas directement sur Layer1 ;
- conserver la tracabilite des decisions de labellisation.

Contraintes :
- ne pas creer de dependance directe a des faits blockchain bruts si une projection amont existe ;
- ne pas contourner ActorProfile pour compenser une donnee manquante.

## V5 Layer1

Pour les futures evolutions Layer1 :

- `utxo_outputs` et `cluster_inputs` sont les faits stricts principaux ;
- `tx_outputs` peut devenir une projection historique asynchrone ;
- aucune optimisation ne doit reduire la capacite d'audit ou de certification ;
- toute projection async doit etre reconstructible depuis Bitcoin Core ou une autre source de verite durable.

La certification Layer1 stricte ne doit pas attendre une projection historique complete si les faits stricts necessaires sont deja certifies, audites et tracables.

Avant de sortir une ecriture du chemin strict :

- identifier les lecteurs stricts actuels ;
- remplacer les lectures strictes par `StrictOutputFacts` ou une source certifiee equivalente ;
- creer un checkpoint durable ;
- definir la strategie de replay depuis Bitcoin Core ;
- conserver ou adapter les audits sans reduire leur perimetre ;
- documenter les etats `pending`, `processing`, `projected`, `failed` ou equivalents ;
- mesurer l'impact sur Sidekiq, PostgreSQL et Redis.

## Regles De Developpement

- Ne jamais casser, desactiver ou affaiblir les audits existants.
- Ne jamais supprimer un test existant.
- Ne jamais masquer un echec de test sans justification explicite.
- Privilegier les petits commits, faciles a relire et a rollback.
- Garder les changements proches du besoin demande.
- Eviter les refactors opportunistes.
- Respecter les patterns existants du projet.
- Ne pas modifier le pipeline strict sans analyse explicite des invariants.
- Ne pas introduire de dependance circulaire entre Layer1, Cluster, ActorProfile et ActorLabels.
- Ne pas melanger migration, logique metier et refactor dans le meme commit sauf necessite documentee.
- Demander confirmation avant toute migration ou modification de production.
- Ne pas modifier de fichier sans autorisation explicite lorsque l'utilisateur demande une analyse ou un diagnostic.

## Migrations Et Production

Avant toute migration, demander confirmation explicite.

Avant toute modification de production ou commande touchant une base de production, demander confirmation explicite.

Cela inclut :
- `db:migrate` hors environnement test ;
- migrations destructives ;
- backfills ;
- jobs de reprise ou de replay ;
- commandes Rails runner qui ecrivent en base ;
- operations Sidekiq modifiant les queues ;
- modifications Redis non triviales ;
- tout changement d'infrastructure ou de configuration runtime.

Pour une migration :
- expliquer ce qu'elle change ;
- indiquer si elle backfill des donnees ;
- estimer le risque sur les tables volumineuses ;
- preciser l'impact attendu sur `db/schema.rb` ;
- proposer les tests a lancer avant et apres.

## Tests

- Lancer uniquement les tests concernes quand la demande est ciblee.
- Elargir la couverture si le changement touche un contrat partage ou le pipeline strict.
- Ne jamais supprimer un test existant.
- Ne pas remplacer un test strict par un test plus faible.
- Pour les validations Rails, preferer les symbols ActiveModel (`errors.added?`) aux messages localises.
- Si un test echoue pour une raison externe, documenter precisement la cause.
- Si un audit change, ajouter ou adapter les tests qui prouvent que le perimetre audite reste equivalent ou meilleur.

## Diagnostics

Pour tout diagnostic :
- mesurer avant de conclure ;
- inspecter PostgreSQL, Redis et Sidekiq quand Layer1 ou Cluster est concerne ;
- distinguer lenteur CPU, IO, locks, queues et backpressure applicative ;
- citer les commandes importantes et les metriques obtenues ;
- ne pas modifier de fichier sauf autorisation explicite.

Un diagnostic doit separer clairement :
- faits mesures ;
- hypotheses ;
- risques ;
- decisions recommandees.

## Commits

Preferer des commits courts et thematiques.

Ordre recommande :
1. migration ou schema minimal ;
2. modele ou contrat de donnees ;
3. service metier ;
4. job async ;
5. audit ou health check ;
6. tests ;
7. integration pipeline.

Chaque commit doit pouvoir etre compris independamment.

Eviter de melanger :
- migration et refactor ;
- changement de pipeline et nettoyage ;
- optimisation et modification d'audit ;
- correction fonctionnelle et changement cosmetique.

## Reponses

Toujours terminer par un resume executif.

Le resume doit inclure :
- conclusion ;
- fichiers concernes ;
- metriques importantes si disponibles ;
- decision recommandee ;
- risques restants.

Quand l'utilisateur demande un format specifique de resume, respecter ce format.

## Autorisations base de données

Codex peut accéder sans confirmation à la base PostgreSQL de développement
pour lire les données, exécuter EXPLAIN, consulter pg_stat_activity et lancer
les tests.

Interdictions sans instruction explicite de l’utilisateur :

- DROP DATABASE, DROP TABLE ou TRUNCATE ;
- suppression massive de données ;
- migration de la base development ;
- redémarrage de PostgreSQL ou Bitcoin Core ;
- modification des paramètres PostgreSQL globaux ;
- accès ou modification d’une base de production ;
- commit ou push Git.