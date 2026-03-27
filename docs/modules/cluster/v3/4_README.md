
# Bitcoin Monitor — Module Cluster V3

Le module **Cluster V3** prolonge les versions précédentes du moteur cluster.

Il ne remplace pas :

* la **V1**, qui construit la structure brute
* la **V2**, qui ajoute profils, classification et score

Il ajoute une nouvelle couche :

* métriques agrégées
* signaux comportementaux simples
* enrichissement de lecture côté interface

---

# 1. Objectif

La V3.1 transforme le cluster en :

👉 **unité de lecture comportementale simple**

Le module ne doit plus seulement répondre à :

> “Cette adresse appartient-elle à un cluster ?”

mais aussi à :

> “Ce cluster présente-t-il une activité récente notable ou un comportement méritant attention ?”

---

# 2. Positionnement

## V1 — Structure brute

Le moteur V1 construit :

* `addresses`
* `address_links`
* `clusters`

à partir d’heuristiques structurelles, principalement multi-input.

---

## V2 — Interprétation simple

Le moteur V2 ajoute :

* `cluster_profiles`
* classification
* score
* traits

Le profil cluster permet une première lecture synthétique du cluster.

---

## V3.1 — Enrichissement comportemental

La V3.1 ajoute :

* `cluster_metrics`
* `cluster_signals`

Elle permet une lecture plus dynamique du cluster :

* activité récente
* volume récent
* variations par rapport à une base estimée
* signaux simples

---

# 3. Ce que la V3.1 apporte

## 3.1 Métriques

Le module calcule des métriques agrégées estimées pour un cluster :

* activité 24h
* activité 7j
* volume envoyé 24h
* volume envoyé 7j
* `activity_score`

⚠️ Important :

les métriques actuelles sont **estimées** à partir du profil cluster.
Elles ne correspondent pas encore à une reconstruction temporelle exacte du cluster.

---

## 3.2 Signaux

Le module produit actuellement les signaux suivants :

* `sudden_activity`
* `volume_spike`
* `large_transfers`
* `cluster_activation`

Ces signaux sont construits à partir :

* des métriques cluster
* de seuils heuristiques
* d’un wording volontairement prudent

---

## 3.3 Lecture enrichie

La V3.1 enrichit la lecture utilisateur en ajoutant :

* une synthèse plus intelligente
* des signaux récents
* une distinction plus nette entre profil du cluster et comportement observé

---

# 4. Architecture actuelle

## 4.1 Données structurelles

Issues de la V1 :

* `addresses`
* `address_links`
* `clusters`

---

## 4.2 Données enrichies

Issues de la V2 :

* `cluster_profiles`

Le profil cluster est recalculé à partir des adresses du cluster.

---

## 4.3 Données V3.1

Ajoutées en V3.1 :

* `cluster_metrics`
* `cluster_signals`

---

# 5. Services actuels

## Services hérités

* `ClusterScanner`
* `ClusterAggregator`
* `ClusterClassifier`
* `ClusterScorer`

---

## Services V3.1

* `ClusterMetricsBuilder`
* `ClusterSignalEngine`

### `ClusterMetricsBuilder`

Calcule les métriques cluster à partir du profil.

### `ClusterSignalEngine`

Produit les signaux à partir des métriques.

---

# 6. Pipeline actuel

Le pipeline réel repose sur la structure V1, les profils V2, puis les couches V3.

Pipeline actuel :

```text
cluster scan
→ addresses / links / clusters
→ clusters modifiés (dirty)
→ rebuild cluster_profiles
→ cluster_metrics
→ cluster_signals
→ UI
```

## Point important

Les profils cluster sont recalculés après mutation du cluster, pour éviter les incohérences entre :

* somme réelle des adresses
* profil cluster stocké

Cela garantit notamment la cohérence de :

```ruby
cluster.addresses.sum(:total_sent_sats)
==
cluster.cluster_profile.total_sent_sats
```

---

# 7. Exécution actuelle

## Ce qui existe déjà

La logique V3.1 existe déjà au niveau :

* services
* tables
* UI
* monitoring système

## Services utilisables

```ruby
ClusterMetricsBuilder.call(cluster)
ClusterSignalEngine.call(cluster)
```

## Ce qui reste à industrialiser proprement

* tâches rake V3 nommées proprement
* scripts cron V3
* orchestration V3 complète

---

# 8. Pages concernées

## 8.1 Page adresse

La page adresse est le point d’entrée principal.

Elle affiche déjà :

* synthèse interprétée
* classification
* score
* traits
* signaux récents
* adresses liées
* preuves multi-input

Elle peut aussi signaler des incohérences temporaires, par exemple :

* cluster incomplet
* cluster en cours de construction
* agrégat cluster suspect

---

## 8.2 Page signaux cluster

La V3 dispose maintenant d’une page dédiée :

* `/cluster_signals`

Elle permet de voir directement :

* les signaux récents
* les clusters touchés
* une adresse d’entrée pour analyse détaillée

---

## 8.3 Top clusters du jour

La V3 dispose aussi d’une page :

* `/cluster_signals/top`

Elle permet de classer les clusters selon :

* score agrégé
* nombre de signaux
* sévérité
* types de signaux observés

---

## 8.4 Dashboard

Le dashboard donne accès aux entrées cluster principales via les raccourcis.

---

# 9. Cas d’usage

## Avant un transfert

Comprendre rapidement si une adresse appartient à un cluster :

* actif
* volumineux
* récemment réveillé
* atypique sur une courte période

---

## Analyse comportementale

Détecter :

* une hausse d’activité
* un pic de volume
* une activation récente
* des transferts importants concentrés

---

## Sécurité / vigilance

Repérer des comportements qui méritent une vérification supplémentaire,
sans jamais prétendre identifier une entité avec certitude.

---

# 10. Philosophie produit

La V3.1 repose sur quatre principes.

## 1. Contexte

Toujours expliquer ce qui est observé.

## 2. Prudence

Ne jamais présenter une hypothèse comme une certitude.

## 3. Lisibilité

Un signal doit être compréhensible rapidement.

## 4. Utilité

L’information doit aider à surveiller ou à mieux interpréter une adresse.

---

# 11. Ce que la V3.1 n’est pas

La V3.1 n’est pas :

* un moteur AML complet
* un système d’identification certaine
* un moteur de conformité
* un moteur cross-modules complet
* un système temps réel pur

Le module reste :

👉 **un moteur probabiliste d’analyse comportementale simple**

---

# 12. Monitoring

Le monitoring V3.1 est déjà visible dans `/system` pour :

* `cluster_metrics`
* `cluster_signals`

Ce qui reste à améliorer :

* SLA explicites
* suivi plus détaillé des jobs V3
* orchestration plus claire du pipeline complet

---

# 13. État réel de la V3.1

## Déjà en place

* tables `cluster_metrics`
* tables `cluster_signals`
* `ClusterMetricsBuilder`
* `ClusterSignalEngine`
* page adresse enrichie
* page `/cluster_signals`
* page `/cluster_signals/top`
* monitoring `/system`
* recalcul cohérent des profils cluster
* optimisation scanner via dirty clusters

## Encore à finaliser

* tâches rake V3 propres
* cron V3 propre
* visibilité explicite des métriques 24h / 7j dans l’UI adresse
* tests de services et invariants

---

# 14. Roadmap

## V3.1

* metrics
* signaux simples
* affichage enrichi
* cohérence profils / clusters
* entrées UI dédiées

## V3.2

* alertes
* meilleure orchestration V3
* visibilité système renforcée

## V3.3

* corrélations whales
* corrélations exchange flow
* lecture plus transverse

## V4

* intelligence avancée
* priorisation comportementale
* lecture globale de pression marché via clusters

---

# 15. Exemple de lecture V3.1

Exemples de sorties possibles :

* Cluster large
* activité récente notable
* volume 24h supérieur à la moyenne estimée
* aucun signal critique détecté

Ou :

* Cluster moyen
* activité atypique récente
* signal `volume_spike`
* vigilance recommandée

Ou encore :

* Cluster récemment activé
* nombre de transactions 24h élevé par rapport au niveau habituel
* signal `cluster_activation`

Ou enfin :

* Cluster incomplet ou en cours de construction
* agrégat cluster probablement sous-estimé
* lecture prudente recommandée

---

# 16. Résumé

La V3.1 transforme le module cluster en :

* moteur de métriques agrégées
* moteur de signaux simples
* brique d’enrichissement comportemental
* point d’entrée d’analyse plus global via UI dédiée

Le cluster n’est plus seulement une structure technique :

👉 il devient une **unité de lecture du comportement observé**

---

# 17. Règle d’or

👉 **Aider à comprendre un comportement, sans jamais prétendre connaître toute la vérité.**
