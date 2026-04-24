# Cluster : le jour où Bitcoin Monitor a commencé à relier les adresses entre elles

> *Au début, Bitcoin Monitor observait des transactions.*
>
> Puis un nouveau problème est apparu :
>
> > une transaction seule ne raconte presque rien.
>
> Ce chapitre raconte comment le projet a progressivement tenté de répondre à une question beaucoup plus difficile :
>
> > quelles adresses appartiennent probablement à la même entité ?

Et cette question allait transformer :

* l’architecture,
* les performances,
* les datasets,
* les scanners,
* et même la manière de penser le système.

---

## 1. Le problème invisible

Pendant longtemps, Bitcoin Monitor observait :

* des blocs,
* des transactions,
* des UTXO,
* des mouvements.

Mais quelque chose manquait.

Le système voyait :

```text
A → B
```

sans comprendre :

```text
qui contrôle réellement quoi.
```

Et c’est là qu’un nouveau besoin est apparu :

> relier les adresses entre elles.

---

## 2. Le déclic

Un jour, une évidence est apparue.

Sur Bitcoin, lorsqu’une transaction possède plusieurs inputs :

```text
input A
input B
input C
```

il est extrêmement probable que :

* les clés privées associées
* soient contrôlées par la même entité.

Pourquoi ?

Parce que pour signer une transaction multi-input :

> il faut contrôler toutes les clés des inputs.

Cette idée semble simple.

Mais elle ouvre quelque chose d’énorme :

> construire des clusters d’adresses.

---

## 3. Le système commence à penser en entités

Avant Cluster :

Bitcoin Monitor observait :

* des adresses,
* des transactions,
* des outputs.

Après Cluster :

le système commençait à observer :

* des groupes,
* des comportements,
* des ensembles cohérents.

C’est une transition majeure.

Le projet cessait progressivement de voir :

```text
des objets techniques
```

pour commencer à voir :

```text
des acteurs blockchain.
```

---

## 4. La première version du scanner

La première implémentation semblait relativement simple.

Le scanner :

* lisait les blocs,
* parcourait les transactions,
* récupérait les inputs,
* extrayait les adresses,
* puis créait des liens.

Le pipeline ressemblait à ceci :

```text
Bitcoin Core RPC
      ↓
scan block
      ↓
extract inputs
      ↓
group addresses
      ↓
create links
      ↓
merge clusters
```

Sur le papier :
cela semblait suffisant.

En réalité :
ce n’était que le début.

---

## 5. Le premier vrai problème : les prevouts

Très vite, une difficulté importante est apparue.

Dans Bitcoin :

* les inputs ne contiennent pas directement les adresses précédentes,
* ils référencent des outputs antérieurs.

Le scanner devait donc :

* relire les prevouts,
* reconstruire les transactions précédentes,
* extraire les scripts,
* comprendre les adresses.

Et là, Bitcoin Monitor a commencé à découvrir une réalité importante :

> analyser Bitcoin coûte cher.

---

## 6. Les performances commencent à souffrir

Le scanner devait maintenant :

* lire énormément de blocs,
* reconstruire les prevouts,
* parser des scripts,
* créer des liens,
* fusionner des clusters.

Les premiers symptômes sont apparus :

* CPU élevé,
* scans très longs,
* mémoire qui grimpe,
* ralentissements PostgreSQL,
* jobs interminables.

Le problème n’était plus :

> “le code fonctionne-t-il ?”

Mais :

> “le système peut-il tenir dans le temps ?”

---

## 7. Cluster cesse d’être une simple feature

C’est un moment important dans la vie d’une application.

Le module Cluster n’était plus :

```text
une fonctionnalité.
```

Il devenait :

```text
un pipeline massif de reconstruction d’identité probabiliste.
```

Et cela change tout.

---

## 8. Les premières tables apparaissent

Pour stocker les relations, plusieurs modèles sont apparus.

Par exemple :

```ruby
Cluster
ClusterAddress
ClusterLink
```

Puis progressivement :

* profils,
* métriques,
* signaux,
* snapshots.

Le système ne stockait plus seulement :

```text
des données blockchain.
```

Mais :

```text
une interprétation structurée de comportements.
```

---

## 9. Les datasets explosent

Très vite :
les volumes sont devenus gigantesques.

Des centaines de milliers :

* d’adresses,
* de liens,
* de relations,
* de clusters.

Puis :
des millions.

Et là, un nouveau problème est apparu :

> comment maintenir les clusters à jour sans rescanner toute la blockchain ?

---

## 10. Le scanner incrémental devient obligatoire

Au début :
le scanner rescannait énormément de données.

Mais cette approche devenait rapidement impossible.

Bitcoin Monitor a alors commencé à introduire :

* des curseurs,
* des best heights,
* des scans incrémentaux,
* des reprises,
* des backfills.

Le système devenait progressivement :

> vivant.

---

## 11. Le moment où le scanner devient trop gros

Au départ :
tout était contenu dans :

```ruby
ClusterScanner
```

Le service :

* extrayait les inputs,
* groupait les adresses,
* écrivait les données,
* fusionnait les clusters,
* créait les liens,
* gérait les stats.

Petit à petit :
le fichier devenait énorme.

Et surtout :
de plus en plus difficile à comprendre.

---

## 12. Le vrai problème n’était plus le code

Le vrai problème devenait :

> la responsabilité.

Le scanner connaissait :

* trop de détails,
* trop de règles métier,
* trop de structures internes.

Et là, un changement important a commencé.

---

## 13. Le grand refactor

Progressivement, plusieurs composants spécialisés sont apparus.

Par exemple :

```ruby
Clusters::InputExtractor
Clusters::AddressWriter
Clusters::ClusterMerger
Clusters::LinkWriter
Clusters::DirtyClusterRefresher
```

C’est une étape extrêmement importante.

Pourquoi ?

Parce que le scanner cessait progressivement de :

```text
tout faire lui-même.
```

Il devenait :

```text
un orchestrateur.
```

---

## 14. Le système commence à respirer

Le nouveau pipeline ressemblait davantage à ceci :

```text
RPC
 ↓
InputExtractor
 ↓
AddressWriter
 ↓
ClusterMerger
 ↓
LinkWriter
 ↓
DirtyClusterRefresher
```

Et soudain :
le système devenait beaucoup plus lisible.

---

## 15. Les structures implicites deviennent dangereuses

Un autre problème est apparu pendant le refactor.

Au départ :
les données voyageaient sous forme de Hash implicites.

Par exemple :

```ruby
{
  "bc1..." => 123_000
}
```

Cela semblait pratique.

Mais progressivement :
les erreurs devenaient difficiles à suivre.

---

## 16. Le passage aux objets métier implicites

Le système a alors commencé à utiliser des structures plus explicites :

```ruby
{
  address: "...",
  total_inputs: 2,
  total_value_sats: 123456
}
```

Ce changement semble petit.

En réalité :
il transforme complètement la lisibilité du pipeline.

Pourquoi ?

Parce que les données commencent à porter :

> du sens métier.

---

## 17. Les statistiques deviennent vitales

Puis un autre problème est apparu.

Le scanner tournait parfois pendant :

* plusieurs minutes,
* parfois des heures.

Mais impossible de savoir :

* ce qu’il faisait réellement,
* s’il avançait,
* ou s’il était bloqué.

Des métriques sont alors apparues :

```ruby
@stats
```

Avec :

* blocs scannés,
* transactions,
* liens créés,
* clusters fusionnés,
* erreurs,
* progression.

Et là :
le pipeline devenait observable.

---

## 18. Runtime ≠ progression

C’est une distinction extrêmement importante.

Avant :

```text
job running = job vivant
```

Mais ce n’était pas vrai.

Un job pouvait :

* tourner,
* consommer du CPU,
* sans réellement avancer.

Le système a commencé à comprendre qu’il fallait afficher :

* la progression réelle,
* le curseur,
* les blocs traités,
* les étapes internes.

---

## 19. Les tensions futures deviennent visibles

À ce stade, plusieurs futurs problèmes étaient déjà perceptibles :

* parallélisation,
* mémoire,
* queues,
* Redis,
* batch processing,
* contention PostgreSQL,
* refresh coûteux.

Mais cette fois :

> les problèmes étaient compris.

Et cela change énormément la manière de développer.

---

## 20. Cluster devient une fondation du système

Progressivement, d’autres modules ont commencé à dépendre de Cluster :

```text
Whales
   ↓
Exchange Like
   ↓
Clusters
   ↓
Signals
   ↓
Behavior analysis
```

Cluster devenait progressivement :

> une couche d’intelligence transverse.

---

## 21. Le système commence à interpréter les comportements

Avant :
Bitcoin Monitor observait :

* des transactions.

Maintenant :
le système commençait à observer :

* des comportements agrégés,
* des groupes cohérents,
* des changements d’activité,
* des signaux.

Le projet ne lisait plus seulement :

```text
la blockchain.
```

Il commençait à :

```text
interpréter des comportements probabilistes.
```

---

## 22. Le vrai changement

Le vrai changement introduit par Cluster n’était pas uniquement technique.

Le vrai changement était conceptuel.

Avant :

```text
adresse = entité
```

Après :

```text
adresse ≠ acteur réel
```

Et cette nuance transforme complètement :

* l’analyse,
* les dashboards,
* les signaux,
* les interprétations marché.

---

## 23. Les leçons apprises

### Les scanners deviennent rapidement des systèmes complexes

Même lorsqu’ils semblent simples au départ.

---

### Les responsabilités doivent être découpées tôt

Sinon :
les services deviennent incontrôlables.

---

### Les structures implicites deviennent dangereuses avec le temps

Les pipelines massifs ont besoin :

* de structures claires,
* de données explicites,
* de sens métier.

---

### L’observabilité devient obligatoire

Les jobs longs nécessitent :

* progression,
* métriques,
* heartbeat,
* visibilité réelle.

---

### Les clusters sont probabilistes

Bitcoin ne fournit jamais :

```text
owner_id
```

Tout repose sur :

* des heuristiques,
* des hypothèses,
* des probabilités.

---

## 24. Conclusion

Le module Cluster a profondément changé Bitcoin Monitor.

Avant lui :

* l’application observait des transactions.

Après lui :

* elle commençait à reconstruire des comportements d’acteurs blockchain.

Et ce changement a transformé :

* l’architecture,
* les pipelines,
* les datasets,
* les scanners,
* et même la manière de penser le système.

Parce qu’au final :

> construire des clusters revient à essayer de lire la blockchain comme un organisme vivant.
