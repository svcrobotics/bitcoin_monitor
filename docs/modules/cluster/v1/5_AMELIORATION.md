
# Cluster — V1 — Améliorations

Ce document liste les améliorations possibles du module `cluster`
après la mise en place du socle V1.

Le principe est simple :

- la V1 reste minimaliste
- les améliorations sont notées ici
- elles ne doivent pas faire dériver le périmètre initial

---

# 1. Objectif du document

Ce fichier sert à :

- garder la trace des idées utiles
- séparer le “nice to have” du “must have”
- protéger la V1 contre l’éparpillement
- préparer les futures itérations

---

# 2. Rappel du scope V1

La V1 couvre uniquement :

- scan incrémental bloc par bloc
- heuristique `multi_input`
- création d’adresses
- création de liens
- création / fusion de clusters
- statistiques simples

Ne font pas partie de la V1 :

- `change detection`
- `CoinJoin detection`
- scoring de risque
- attribution d’entité
- UI avancée
- moteur forensic complet

---

# 3. Améliorations court terme

## A-001 — Ajout d’un `README.md` opérationnel
Créer un document d’entrée simple pour expliquer :

- ce que fait le module
- comment lancer le scanner
- quelles tables sont utilisées
- quelles sont les limites de la V1

### Valeur
Améliore la lisibilité et l’onboarding.

---

## A-002 — Ajouter un mode debug transaction
Prévoir une commande ou une tâche pour analyser une transaction donnée.

Exemple :

```text
cluster:debug_tx[txid]
````

### But

* inspecter rapidement une tx multi-input
* comprendre pourquoi un cluster a été créé
* faciliter le debug

---

## A-003 — Logs plus lisibles

Enrichir les logs du scanner avec :

* hauteur de bloc
* nombre de tx analysées
* nombre de liens créés
* nombre de clusters créés
* nombre de clusters fusionnés

### Valeur

Facilite le pilotage et le debug.

---

## A-004 — Résumé de run dans `job_runs`

Brancher le scanner cluster sur le mécanisme de suivi de job déjà présent.

### But

Conserver :

* date du run
* hauteur de départ
* hauteur de fin
* stats du run
* erreurs éventuelles

---

## A-005 — Tâche de recalcul des stats

Créer une tâche dédiée pour recalculer proprement les stats d’adresses ou de clusters.

Exemple :

```text
cluster:rebuild_stats
```

### Valeur

Permet de corriger ou vérifier les compteurs sans rescanner toute la logique.

---

# 4. Améliorations fonctionnelles moyen terme

## A-006 — Change detection

Introduire une heuristique pour détecter l’adresse de change probable.

### Exemples de signaux

* output jamais vu auparavant
* type de script cohérent
* montant atypique
* autre output ressemblant à un paiement

### Attention

Amélioration utile mais plus fragile que `multi_input`.

---

## A-007 — Score de confiance des liens

Ajouter un niveau de confiance sur chaque lien.

Exemple :

* `multi_input` = confiance élevée
* `change_probable` = confiance moyenne ou faible

### Valeur

Permet de nuancer les résultats.

---

## A-008 — Différenciation des types de lien

Étendre `address_links.link_type` avec de nouveaux types :

* `multi_input`
* `change_probable`
* `same_spend_pattern`
* `cluster_merge`

### Valeur

Prépare un moteur plus riche sans casser le modèle.

---

## A-009 — Détection de cas spéciaux

Ajouter des garde-fous pour éviter certains faux positifs.

Exemples :

* CoinJoin
* PayJoin
* transactions atypiques
* constructions wallet particulières

### Valeur

Améliore la qualité des clusters.

---

## A-010 — Support d’un backfill plus large

Permettre un scan historique plus large, plus robuste et plus paramétrable.

### Exemples

* scan par plage de hauteurs
* scan par tranche
* scan progressif avec checkpoints

---

# 5. Améliorations data / performance

## A-011 — Batchs d’écriture

Réduire le nombre de requêtes SQL en groupant certaines opérations.

### Candidats

* création des adresses
* insertion des liens
* mise à jour des compteurs

### Valeur

Améliore les performances.

---

## A-012 — Upserts plus propres

Introduire des stratégies d’upsert pour éviter les doublons
et réduire la logique applicative répétitive.

---

## A-013 — Recalcul partiel de cluster

Éviter les recalculs globaux inutiles après chaque fusion.

### Idée

Ne recalculer que le cluster touché.

---

## A-014 — Index avancés

Ajouter ou ajuster les index si la volumétrie augmente.

### Exemples

* index partiels
* index composites supplémentaires
* optimisation sur `cluster_id`
* optimisation sur `txid`

---

## A-015 — Partitionnement futur

Étudier le partitionnement des tables lourdes si le volume augmente fortement.

### Candidats

* `address_links`
* éventuellement `addresses` si nécessaire

---

# 6. Améliorations produit / métier

## A-016 — Fiche cluster

Créer une page simple pour afficher un cluster.

Contenu possible :

* identifiant du cluster
* nombre d’adresses
* première activité
* dernière activité
* volume observé
* exemples d’adresses liées

### Valeur

Première visualisation métier exploitable.

---

## A-017 — Recherche par adresse

Permettre à l’utilisateur de saisir une adresse
et d’obtenir son cluster probable.

### Valeur

Très utile pour l’exploration manuelle.

---

## A-018 — Enrichissement whales

Relier les alertes whales à des clusters au lieu d’adresses isolées.

### Valeur

Donne plus de sens aux gros mouvements.

---

## A-019 — Enrichissement exchange flows

Utiliser les clusters pour améliorer la lecture des flux exchange.

### Valeur

Peut aider à distinguer :

* retraits liés
* dépôts consolidés
* activité structurée

---

## A-020 — Détection de concentration du capital

Construire des vues sur la concentration de BTC par cluster.

### Valeur

Très intéressant pour l’analyse comportementale du capital.

---

# 7. Améliorations forensic / risque

## A-021 — Attribution d’entités

Associer certains clusters à des catégories :

* exchange
* service
* wallet
* scam
* inconnu

### Attention

Nécessite plus que le simple clustering V1.

---

## A-022 — Risk scoring

Ajouter un score de risque sur un cluster.

Exemples de facteurs :

* comportement inhabituel
* exposition à clusters sensibles
* patterns automatisés
* signalements externes

---

## A-023 — Scanner d’adresse destination

Permettre d’analyser une adresse cible avant envoi.

### Exemple

* cluster connu ou inconnu
* ancienneté
* activité
* signaux atypiques
* niveau de prudence

---

## A-024 — Moteur “anti-virus BTC”

Construire plus tard une brique d’aide à la décision avant transfert.

### Important

Cette brique dépend d’abord :

* d’un cluster builder solide
* puis d’une couche d’interprétation

---

# 8. Améliorations UX / visualisation

## A-025 — UI cluster minimale

Ajouter une interface simple dans Bitcoin Monitor :

* recherche adresse
* cluster trouvé
* nombre d’adresses
* activité récente

---

## A-026 — Graphe léger

Afficher un mini graphe d’adresses liées.

### Attention

Pas besoin d’un moteur graphe complexe au début.

---

## A-027 — Badges de confiance

Afficher dans l’UI des badges comme :

* `cluster probable`
* `confiance élevée`
* `multi-input`

---

## A-028 — Explications pédagogiques

Ajouter un encart “Comprendre” expliquant :

* ce qu’est un cluster
* ce qu’est un lien multi-input
* pourquoi ce n’est pas une certitude absolue

---

# 9. Améliorations de qualité / fiabilité

## A-029 — Jeux de tests réels documentés

Constituer une petite bibliothèque de transactions connues
utiles pour tester le moteur.

---

## A-030 — Vérifications de cohérence

Créer une tâche de contrôle automatique.

Exemples :

* adresses sans cluster alors qu’un lien existe
* `address_count` incohérent
* liens auto-référents
* clusters vides

---

## A-031 — Idempotence renforcée

Durcir encore le comportement lors de rescans,
fusions répétées ou interruptions.

---

## A-032 — Gestion d’erreurs plus fine

Mieux distinguer :

* erreur RPC
* erreur data
* erreur de fusion
* erreur de transaction SQL

---

# 10. Améliorations d’architecture

## A-033 — Séparer builder et scanner

Si le module grossit, séparer :

* `ClusterScanner`
* `ClusterBuilder`
* `ClusterMerger`
* `ClusterStatsRefresher`

### Valeur

Clarifie les responsabilités.

---

## A-034 — Services dédiés

Créer des services spécialisés comme :

* `Cluster::TxAnalyzer`
* `Cluster::LinkCreator`
* `Cluster::Merger`
* `Cluster::StatsUpdater`

---

## A-035 — Événements internes

Plus tard, produire des événements internes lors de :

* création cluster
* fusion cluster
* lien détecté

### Valeur

Peut servir à enrichir d’autres modules.

---

# 11. Priorités recommandées après V1

## Priorité haute

* logs améliorés
* tâche debug transaction
* recalcul de stats
* recherche par adresse
* fiche cluster simple

## Priorité moyenne

* change detection
* score de confiance
* enrichissement whales / flows

## Priorité basse

* graphe avancé
* attribution d’entité large
* anti-virus BTC complet
* moteur forensic étendu

---

# 12. Philosophie

Le module cluster doit grandir par couches :

## couche 1

socle de clustering fiable

## couche 2

meilleure qualité heuristique

## couche 3

lecture métier / produit

## couche 4

risque / forensic / aide à la décision

L’amélioration la plus importante reste :

un moteur V1 simple, propre et explicable.


