# Chapitre — Cluster Events, temps réel et ClickHouse

> « À partir du moment où un système produit des événements, il cesse d’être une simple base de données. Il devient un organisme vivant. »

## Introduction

Le module cluster de Bitcoin Monitor a commencé de manière relativement simple.

L’objectif initial était surtout de :

* scanner les transactions Bitcoin,
* relier les adresses,
* construire des clusters,
* détecter des relations entre entités.

À cette époque, le système fonctionnait principalement comme un moteur d’analyse statique.

On construisait :

* des profils,
* des statistiques,
* des agrégats,
* des graphes.

Mais progressivement, un problème est apparu.

Le système savait stocker des données.

Mais il ne savait pas raconter ce qui se passait.

Et cette différence est énorme.

---

## Le problème des données statiques

Au début, les clusters étaient essentiellement représentés par :

* Cluster,
* ClusterProfile,
* ClusterMetric,
* ClusterSignal.

Le système pouvait répondre à des questions comme :

* combien d’adresses possède un cluster,
* combien de transactions il a effectué,
* quel volume il a transféré,
* quand il a été vu pour la première fois.

Mais une application blockchain analytique ne peut pas rester purement statique.

Car la blockchain est un flux vivant.

À chaque bloc :

* des clusters fusionnent,
* des whales deviennent actives,
* des flux massifs apparaissent,
* des comportements changent,
* des entités se réveillent après des mois d’inactivité.

Et à ce moment-là, quelque chose devient évident :

les utilisateurs ne veulent pas seulement consulter des données.

Ils veulent voir des événements.

---

## Le moment où tout change

L’une des plus grandes transformations de Bitcoin Monitor a été cette prise de conscience :

le système devait devenir événementiel.

Au lieu de simplement construire des tables analytiques,
il fallait produire des signaux temps réel.

Cela change complètement la manière de penser l’architecture.

Avant :

```text
scanner -> PostgreSQL -> dashboard
```

Après :

```text
blockchain -> Layer 1 -> classifier -> events -> analytics -> dashboards
```

Le système ne stocke plus seulement des états.

Il produit des événements interprétables.

---

## Pourquoi PostgreSQL commençait à montrer ses limites

Au début, PostgreSQL suffisait largement.

Mais lorsque les événements sont devenus plus nombreux, plusieurs problèmes sont apparus :

* lectures analytiques répétitives,
* dashboards temps réel,
* événements append-only,
* gros volumes de signaux,
* tris chronologiques permanents,
* filtres rapides par source ou sévérité.

PostgreSQL restait excellent pour :

* les données relationnelles,
* les profils,
* les clusters,
* les relations d’adresses.

Mais pour les événements analytiques temps réel, une autre approche devenait pertinente.

C’est là que ClickHouse est entré dans le projet.

---

## Pourquoi ClickHouse était intéressant

ClickHouse est particulièrement adapté aux systèmes analytiques temps réel.

Ce qui le rend extrêmement intéressant pour Bitcoin Monitor :

* lectures ultra rapides,
* agrégations massives,
* stockage append-only,
* compression,
* requêtes temporelles,
* dashboards live.

Et surtout :

le modèle événementiel devient naturel.

Au lieu de mettre constamment à jour des lignes,
le système écrit simplement de nouveaux événements.

Cette différence simplifie énormément l’architecture.

---

## La naissance de cluster_events

Une nouvelle table est apparue :

```text
cluster_events
```

Cette table devient le journal vivant du système cluster.

Chaque ligne représente un événement.

Par exemple :

```text
event_time
cluster_id
signal_type
severity
score
amount_btc
tx_count
address_count
source
```

Le système commence alors à produire des événements comme :

* whale_cluster_activity,
* large_outflow,
* large_inflow,
* cluster_merge,
* large_link_creation,
* cluster_reactivation,
* activity_spike.

Et à partir de ce moment-là,
Bitcoin Monitor cesse d’être uniquement un scanner blockchain.

Il devient un moteur d’événements analytiques.

---

## Séparer signaux techniques et signaux métier

Très rapidement, un autre problème apparaît.

Tous les événements n’ont pas la même nature.

Certaines alertes sont purement techniques.

D’autres sont interprétables métier.

Cette distinction devient très importante.

---

## Les signaux techniques

Les signaux techniques décrivent l’évolution du graphe.

Par exemple :

```text
cluster_merge
large_link_creation
```

Ces événements signifient :

* le cluster grandit,
* des liens apparaissent,
* deux groupes d’adresses semblent connectés.

Ils sont utiles pour :

* comprendre la structure du graphe,
* améliorer les heuristiques,
* observer les merges.

Mais ce ne sont pas forcément des signaux marché.

---

## Les signaux métier

Les signaux métier sont beaucoup plus interprétables.

Par exemple :

```text
whale_cluster_activity
large_outflow
cluster_reactivation
```

Cette fois, l’objectif est différent.

Le système tente de détecter :

* des comportements importants,
* des mouvements anormaux,
* des activités significatives.

On commence alors à entrer dans une logique proche des plateformes professionnelles d’analyse blockchain.

---

## Le pipeline temps réel

L’architecture du système évolue progressivement.

Le Layer 1 devient la source canonique.

Il fournit :

* les transactions,
* les UTXO,
* les spent outputs,
* les données blockchain brutes.

Puis les modules Layer 2 consomment cet état.

Le module cluster ne lit plus directement Bitcoin Core.

Il consomme le Layer 1.

Cette séparation devient fondamentale.

---

## Realtime et batch

Le système cluster finit par posséder deux pipelines distincts.

### Realtime

Le pipeline realtime traite les nouveaux blocs immédiatement.

Objectifs :

* faible latence,
* alertes rapides,
* signaux immédiats,
* dashboards live.

---

### Batch

Le pipeline batch travaille plus lentement.

Objectifs :

* recalculs,
* scans complets,
* merges,
* reconstruction analytique.

Cette séparation améliore énormément :

* la stabilité,
* la résilience,
* l’observabilité,
* les performances.

---

## Les cluster reactivations

L’un des événements les plus intéressants ajoutés au système est :

```text
cluster_reactivation
```

L’idée paraît simple.

Un cluster peut rester silencieux pendant longtemps,
puis redevenir soudainement actif.

Mais un problème important apparaît immédiatement.

Bitcoin Monitor utilise un node Bitcoin pruned.

Donc il est impossible de reconstruire parfaitement tout l’historique ancien.

Le système doit devenir pragmatique.

---

## Une approche progressive

La solution choisie a été très intéressante architecturalement.

Plutôt que de vouloir reconstruire le passé complet,
Bitcoin Monitor commence à suivre les clusters à partir de maintenant.

Une nouvelle table apparaît :

```text
ClusterActivityState
```

Elle stocke progressivement :

* last_seen_height,
* last_active_height,
* inactive_blocks,
* inactive_seconds.

Le système apprend donc progressivement le comportement des clusters.

C’est une approche incrémentale.

Et c’est souvent ce type d’approche qui permet réellement de faire avancer les projets complexes.

---

## Transformer les événements techniques en langage humain

Une autre transformation importante a eu lieu dans les dashboards.

Au début, les événements étaient affichés tels quels :

```text
large_link_creation
```

Mais cela restait trop technique.

Le système devait devenir lisible.

Les événements commencent alors à être traduits :

```text
Expansion du graphe
```

Puis enrichis :

* score,
* sévérité,
* analyse,
* interprétation,
* pistes de vérification.

Par exemple :

```text
Lecture :
évolution du graphe. Deux groupes d’adresses semblent reliés.
```

À ce moment-là,
Bitcoin Monitor commence réellement à devenir un produit analytique.

---

## Le dashboard Cluster Events

Une nouvelle interface apparaît :

```text
/system/clusters/events
```

Cette page devient une console d’observabilité cluster.

Elle regroupe :

* les signaux techniques,
* les alertes métier,
* les whales,
* les outflows,
* les merges,
* les réactivations.

Et surtout :

elle permet de lire le système en temps réel.

---

## L’importance des scores et de la sévérité

Rapidement, tous les événements deviennent trop nombreux.

Il faut alors hiérarchiser.

Le système introduit :

* low,
* medium,
* high.

Mais aussi un score numérique.

Par exemple :

```text
score 88
```

Ce score permet :

* de filtrer,
* de prioriser,
* de détecter les événements majeurs.

L’observabilité devient progressivement exploitable à grande échelle.

---

## Les dashboards opérationnels

Le projet commence ensuite à évoluer vers quelque chose de beaucoup plus ambitieux.

Les dashboards ne montrent plus uniquement :

* des données,
* des tables,
* des métriques.

Ils montrent :

* l’état du système,
* les pipelines,
* les jobs actifs,
* les locks,
* les lags,
* les buffers,
* les événements temps réel.

L’application commence alors à ressembler à une véritable plateforme de données blockchain.

---

## Ce que cette architecture change

Cette architecture ouvre énormément de possibilités.

Par exemple :

* alertes live,
* notifications,
* APIs analytiques,
* dashboards professionnels,
* détection comportementale,
* monitoring whales,
* observabilité blockchain,
* analyses institutionnelles.

Et surtout :

le système devient extensible.

De nouveaux signaux peuvent être ajoutés facilement.

---

## Ce que ce travail m’a appris

Avant ce module,
je pensais surtout en termes de tables et de modèles.

Aujourd’hui,
je pense davantage en termes de flux et d’événements.

Cette différence change complètement la manière de concevoir une application.

Un système analytique moderne n’est pas seulement :

* une base de données,
* un backend,
* un dashboard.

C’est un moteur d’événements.

---

## Conclusion

Le module Cluster Events a profondément transformé Bitcoin Monitor.

Avant :

* les clusters étaient passifs,
* les données étaient statiques,
* les dashboards étaient descriptifs.

Après :

* le système devient vivant,
* les événements apparaissent en temps réel,
* les comportements deviennent visibles,
* les signaux deviennent interprétables.

Et surtout :

Bitcoin Monitor commence progressivement à devenir une véritable plateforme d’observabilité blockchain temps réel.
