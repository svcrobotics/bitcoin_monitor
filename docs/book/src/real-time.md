# Le passage au temps réel dans Bitcoin Monitor

> Pendant longtemps, Bitcoin Monitor fonctionnait selon un modèle classique :
>
> des scans périodiques,
>
> des cron,
>
> des traitements batch.
>
> Puis une question est apparue :
>
> > “Pourquoi attendre plusieurs minutes alors que la blockchain évolue en permanence ?”

---

## 1. Le problème du modèle batch

Au départ, les modules fonctionnaient avec des tâches planifiées :

```text
cron
↓
scan
↓
mise à jour base
↓
dashboard
```

Ce modèle fonctionne bien :

* pour des volumes modestes,
* des analyses lentes,
* des dashboards non critiques.

Mais progressivement, les limites sont apparues.

---

## 2. Bitcoin ne dort jamais

La blockchain Bitcoin produit un nouveau bloc environ toutes les 10 minutes.

Chaque bloc peut :

* créer de nouveaux clusters,
* modifier des signaux,
* déplacer des milliers d’UTXO,
* changer les flux exchange-like,
* invalider certaines hypothèses de marché.

Attendre un cron de 15 minutes devenait incohérent.

---

## 3. Le vrai problème : la fraîcheur des données

Le problème n’était pas seulement :

```text
la vitesse.
```

Le problème était :

```text
la fraîcheur analytique.
```

Un système d’intelligence blockchain doit être capable de répondre :

> “Que vient-il de se passer ?”

Pas uniquement :

> “Que s’est-il passé il y a 20 minutes ?”

---

## 4. La réflexion d’architecture

Le premier réflexe aurait pu être :

```text
mettre tout en temps réel.
```

Mais cela aurait été une erreur.

La vraie réflexion a été :

> Quel module mérite réellement le temps réel maintenant ?

La réponse :

```text
Blockchain Event Stream
```

---

## 5. Le choix du module temps réel

Le système retenu :

```text
bitcoind
↓
nouveau bloc détecté
↓
Realtime::BlockWatcher
↓
Sidekiq
↓
ClusterScanner incrémental
↓
refresh async
↓
signals
↓
dashboard
```

L’idée était fondamentale :

> le temps réel ne devait pas remplacer le système existant,
> mais devenir une couche d’accélération.

---

## 6. Pourquoi Cluster a été choisi

Le module Cluster était déjà :

* découpé,
* parallélisé,
* compatible Sidekiq,
* basé sur Redis,
* structuré en pipeline.

Il était donc le candidat idéal.

---

## 7. L’approche progressive

Le système n’a pas été basculé brutalement.

La stratégie retenue :

### Étape 1

Détecter un nouveau bloc.

### Étape 2

Lancer un job Sidekiq.

### Étape 3

Scanner uniquement le dernier bloc.

### Étape 4

Mettre à jour les clusters touchés.

### Étape 5

Conserver les cron comme sécurité.

Cette approche limitait les risques.

---

## 8. Le premier watcher temps réel

Le premier composant fut :

```text
bin/realtime_block_watcher
```

Son rôle :

```text
boucle infinie
↓
lecture du height Bitcoin
↓
détection nouveau bloc
↓
enqueue Sidekiq
```

Simple.

Mais extrêmement puissant.

---

## 9. Le premier job temps réel

Le premier worker :

```text
Realtime::ProcessLatestBlockJob
```

Responsabilité :

* récupérer le dernier bloc,
* lancer ClusterScanner,
* déclencher le refresh async.

---

## 10. Le premier vrai pipeline event-driven

Pour la première fois :

```text
nouveau bloc
→ événement
→ job async
→ pipeline distribué
```

Bitcoin Monitor cessait progressivement d’être :

```text
une application Rails classique.
```

---

## 11. Le problème découvert immédiatement

Très vite, un problème apparaît.

Le même bloc pouvait être traité plusieurs fois.

Exemple observé :

```text
height=946547 traité 2 fois
```

Premier passage :

* clusters créés,
* liens générés,
* dirty clusters.

Second passage :

* aucun changement,
* déjà traité.

---

## 12. Le verrou blockchain

Une protection devient nécessaire :

```text
ScannerCursor
```

Le système enregistre :

* dernier height,
* dernier hash,
* timestamp.

Avant chaque traitement :

```text
déjà traité ?
→ skip
```

Le pipeline devient idempotent.

---

## 13. Pourquoi l’idempotence est critique

En blockchain :

* les redémarrages arrivent,
* les retries arrivent,
* les jobs doublons arrivent.

Un pipeline temps réel doit être capable de :

```text
rejouer sans casser les données.
```

C’est une règle fondamentale.

---

## 14. Le rôle central de Sidekiq

Le temps réel n’aurait pas été viable sans :
Sidekiq

Pourquoi ?

Parce que les événements blockchain :

* ne doivent pas bloquer Rails,
* doivent être parallélisés,
* doivent être retryables,
* doivent être supervisables.

---

## 15. Redis devient le cœur du pipeline

Avec :
Redis

Bitcoin Monitor obtient :

* des queues,
* des workers,
* de la coordination,
* de la réactivité.

Le système devient réellement événementiel.

---

## 16. Le watcher devient observable

Un autre changement majeur apparaît :
la supervision.

Le watcher écrit désormais son état dans :

```text
ScannerCursor
```

Le système connaît :

* le dernier bloc vu,
* le dernier bloc traité,
* le hash,
* l’âge des données.

---

## 17. Naissance d’un vrai monitoring temps réel

Une nouvelle section apparaît dans `/system` :

```text
Realtime block stream
```

Avec :

* Watcher,
* Processor,
* Last height,
* Age,
* Hash,
* Status OK / STALE.

Le temps réel devient visible.

---

## 18. Le système commence à “vivre”

Avant :

```text
cron → attente → refresh
```

Après :

```text
nouveau bloc
↓
réaction immédiate
↓
pipeline incrémental
↓
dashboard mis à jour
```

La plateforme devient vivante.

---

## 19. Le rôle conservé des cron

Les cron n’ont pas disparu.

Ils restent :

* le filet de sécurité,
* le système de rattrapage,
* la garantie de cohérence.

Le temps réel accélère.
Les cron sécurisent.

C’est une architecture hybride.

---

## 20. Pourquoi cette approche est importante

Beaucoup de systèmes blockchain tentent :

```text
100% temps réel immédiatement.
```

C’est souvent une erreur.

Bitcoin Monitor a choisi :

```text
temps réel incrémental
+
batch de sécurité
+
supervision forte
```

Architecture beaucoup plus robuste.

---

## 21. Le vrai changement

Le vrai changement n’était pas :

```text
technique.
```

Le vrai changement était :

```text
architectural.
```

Avant :

```text
application Rails
```

Après :

```text
plateforme événementielle blockchain
```

---

# 22. Ce que cela rend possible

Ce pipeline ouvre la porte à :

* alertes live,
* exchange flow live,
* clusters live,
* dashboards temps réel,
* Turbo Streams,
* WebSockets,
* ZMQ Bitcoin,
* pipelines distribués multi-workers.

---

## 23. Leçons apprises

### Le temps réel doit être progressif

Pas brutal.

---

### Les cron restent utiles

Ils sécurisent le système.

---

### L’idempotence est obligatoire

Sans elle :
le pipeline devient dangereux.

---

### Redis + Sidekiq changent l’architecture

Les jobs deviennent :

* distribués,
* observables,
* résilients.

---

### La supervision est aussi importante que le code

Un pipeline invisible est un pipeline dangereux.

---

## 24. Conclusion

Le passage au temps réel a marqué un tournant majeur dans Bitcoin Monitor.

L’application ne se contente plus :

* d’analyser la blockchain.

Elle commence désormais :

* à réagir à la blockchain.

Et cette différence change profondément :

* l’architecture,
* les performances,
* la supervision,
* et la philosophie même du projet.

