
# Bitcoin Monitor — Cluster V2 — Decisions

Ce document consigne les décisions d’architecture, de périmètre et de produit
prises pour la V2 du module cluster.

L’objectif est de garder une trace claire de :
- ce qui est inclus en V2
- ce qui est exclu
- pourquoi ces choix ont été faits

---

# D-201 — La V2 prolonge la V1 sans rupture

## Décision
La V2 ne remplace pas la V1.
Elle enrichit le moteur existant en ajoutant une couche d’intelligence
au-dessus de la base actuelle :

- `addresses`
- `address_links`
- `clusters`

## Raisons
- préserver la stabilité du moteur V1
- éviter une refonte inutile
- garder un chemin d’évolution simple
- pouvoir itérer rapidement

## Conséquence
Le cœur du clustering reste inchangé :
la V2 ajoute profils, classification, score et patterns.

---

# D-202 — Le moteur V1 reste la source de vérité structurelle

## Décision
La V1 reste responsable de la structure brute :
- adresses observées
- liens multi-input
- clusters probables

La V2 ne modifie pas directement la logique de clustering.

## Raisons
- séparation claire des responsabilités
- meilleure lisibilité
- réduction du risque de régression
- debug plus facile

## Conséquence
Les services V2 lisent les données V1 et produisent des vues enrichies.

---

# D-203 — La V2 introduit une couche de profils

## Décision
La V2 ajoute des tables de profils :
- `cluster_profiles`
- `cluster_patterns`
- `address_profiles`

## Raisons
- stocker des données dérivées sans alourdir les tables V1
- séparer structure et interprétation
- permettre des recalculs ciblés
- faciliter les itérations futures

## Conséquence
Les pages produit V2 liront prioritairement les profils enrichis,
tout en conservant les tables V1 comme base.

---

# D-204 — La classification V2 reste heuristique et prudente

## Décision
Les types de clusters V2 sont présentés comme des classifications probables,
pas comme des identifications certaines.

Exemples :
- `exchange_like`
- `service`
- `whale`
- `retail`
- `unknown`

## Raisons
- le clustering n’apporte pas l’identité réelle
- les heuristiques peuvent se tromper
- il faut rester crédible et méthodologiquement honnête

## Conséquence
Le wording produit doit rester prudent :
- “compatible avec”
- “probablement”
- “aucun signal particulier détecté”
et éviter :
- “safe”
- “trusted”
- “identifié avec certitude”

---

# D-205 — La V2 commence par une classification simple

## Décision
La première classification V2 repose d’abord sur :
- la taille du cluster
- le niveau d’activité
- le volume envoyé

## Raisons
- rapidité de mise en œuvre
- bon rapport valeur / complexité
- meilleure lisibilité produit immédiate
- possibilité d’affiner plus tard

## Conséquence
La V2.1 propose une lecture simple et utile,
avant toute sophistication excessive.

---

# D-206 — Le score V2 n’est pas encore un risk score complet

## Décision
Le score V2 est un score heuristique simple,
destiné à résumer l’importance / la structure / l’activité d’un cluster,
et non un score AML ou juridique.

## Raisons
- éviter les promesses trompeuses
- ne pas donner une impression de certitude excessive
- garder une progression produit maîtrisée

## Conséquence
Le score doit être présenté comme un indicateur interne
ou un score d’analyse,
pas comme un verdict absolu.

---

# D-207 — La page adresse reste le point d’entrée principal

## Décision
Le moteur de recherche d’adresse reste au centre du produit en V2.

## Raisons
- c’est le cas d’usage le plus universel
- c’est la valeur la plus immédiatement perçue
- c’est le meilleur point d’entrée utilisateur
- c’est le support naturel pour enrichir l’analyse

## Conséquence
La priorité UX V2 porte sur la page adresse,
avant toute sophistication de la page cluster.

---

# D-208 — La V2 enrichit la même UI au lieu d’en créer une nouvelle

## Décision
La V2 réutilise les pages existantes :
- page adresse
- page cluster
- dashboard

## Raisons
- continuité produit
- réduction du coût de développement
- progression plus naturelle pour l’utilisateur

## Conséquence
La V2 ajoute :
- classification
- badges
- score
- signaux simples
à l’interface existante.

---

# D-209 — Les preuves restent visibles

## Décision
Même en V2, les preuves on-chain restent affichables :
- adresses liées
- txid multi-input
- activity span

## Raisons
- transparence
- confiance utilisateur
- capacité d’audit
- différenciation par rapport à une simple “boîte noire”

## Conséquence
Le produit conserve une base explicable et vérifiable.

---

# D-210 — La V2 prépare la détection de patterns

## Décision
La V2 introduit une structure dédiée pour les patterns,
même si la détection complète ne vient que plus tard.

## Raisons
- préparer CoinJoin detection
- préparer comportements automatisés
- préparer enrichissements futurs
- éviter de recoder la structure plus tard

## Conséquence
`cluster_patterns` est ajoutée dès la V2,
même si la première version reste simple.

---

# D-211 — CoinJoin detection n’entre pas immédiatement dans le clustering

## Décision
La détection CoinJoin V2 agit d’abord comme un signal
de prudence ou de qualité de cluster,
pas comme une refonte immédiate du moteur V1.

## Raisons
- protéger la stabilité du clustering V1
- éviter de casser les résultats existants
- introduire progressivement cette complexité

## Conséquence
Le moteur V1 continue à clusteriser,
et la V2 ajoute un drapeau / score de prudence en cas de pattern CoinJoin probable.

---

# D-212 — La V2 n’est pas un moteur AML complet

## Décision
Le module cluster V2 n’a pas vocation à devenir immédiatement
un outil AML / compliance complet.

## Raisons
- périmètre trop large
- complexité méthodologique
- besoin de données et labels externes
- risque produit trop élevé à ce stade

## Conséquence
La V2 reste un moteur d’analyse on-chain probabiliste,
pas un moteur de conformité réglementaire.

---

# D-213 — Les intégrations cross-modules viennent après la stabilisation V2.1

## Décision
La V2.1 reste centrée sur :
- clusters
- recherche d’adresse
- lecture enrichie

Les intégrations avec :
- whales
- inflow / outflow
- exchange flows
viennent après.

## Raisons
- éviter l’éparpillement
- prioriser la valeur produit visible
- réduire la surface de bugs

## Conséquence
Les modules existants restent découplés dans un premier temps.

---

# D-214 — La cron V2 reste séparée de la V1

## Décision
Les traitements V2 ont leur propre refresh,
séparé du scan cluster V1.

## Raisons
- séparation claire :
  - V1 = scan / structure
  - V2 = enrichissement / intelligence
- possibilité de recalculer les profils sans rescanner la blockchain
- meilleure observabilité

## Conséquence
Un pipeline du type `cluster:v2_refresh` sera introduit,
avec son propre suivi système.

---

# D-215 — Le monitoring V2 doit s’intégrer au module System

## Décision
Les traitements V2 doivent être visibles dans `/system`.

## Raisons
- cohérence avec le reste de la plateforme
- besoin de confiance sur les jobs d’enrichissement
- détection rapide des retards

## Conséquence
Le module System devra suivre :
- le job V2 refresh
- sa fraîcheur
- son statut
- son SLA

---

# D-216 — Le produit doit rester compréhensible pour un non-dev

## Décision
Les résultats V2 doivent être lisibles par un utilisateur non technique.

## Raisons
- le moteur de recherche d’adresse est un point d’entrée grand public
- la valeur produit doit être immédiate
- un trop haut niveau de technicité nuit à l’adoption

## Conséquence
La V2 ajoute :
- une lecture rapide
- des badges
- des labels simples
avant d’ajouter davantage de technicité.

---

# D-217 — Le wording produit doit rester prudent

## Décision
Le wording de la V2 évite tout langage absolu.

## À éviter
- “safe”
- “trusted”
- “clean”
- “identified owner”

## À privilégier
- “compatible avec”
- “probablement”
- “aucun signal particulier détecté”
- “activité observée”

## Raisons
- honnêteté méthodologique
- sécurité produit
- crédibilité long terme

## Conséquence
Toutes les vues V2 doivent être relues sous cet angle.

---

# D-218 — La priorité V2.1 est la valeur visible, pas la sophistication maximale

## Décision
La V2.1 privilégie :
- classification simple
- score simple
- meilleur rendu UI
au lieu d’un moteur analytique complexe dès le départ.

## Raisons
- obtenir rapidement un gain produit visible
- réduire la complexité
- accélérer l’itération

## Conséquence
Les premières livraisons V2 doivent être petites, claires, utiles.

---

# D-219 — L’adresse est l’unité d’entrée, le cluster l’unité de contexte

## Décision
Le produit reste centré sur l’adresse comme entrée,
et sur le cluster comme contexte explicatif.

## Raisons
- c’est naturel pour l’utilisateur
- c’est le meilleur modèle mental
- cela rend l’outil actionnable avant transfert

## Conséquence
La page adresse reste la page stratégique principale.

---

# D-220 — La philosophie V2 est “contexte, interprétation, prudence”

## Décision
Chaque enrichissement V2 doit répondre à trois critères :
- il apporte du contexte
- il améliore l’interprétation
- il reste prudent

## Raisons
- garder un produit fiable
- construire de la confiance
- éviter la sur-interprétation

## Conséquence
Toute nouvelle fonctionnalité V2 sera arbitrée selon ces trois critères.