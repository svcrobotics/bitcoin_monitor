
# Exchange Like — V1 — Améliorations possibles

Ce document liste les améliorations envisageables pour les versions futures
du module `exchange_like`.

La V1 privilégie la simplicité et la robustesse.  
Plusieurs améliorations peuvent être envisagées pour améliorer :

- la précision
- les performances
- la scalabilité
- la qualité des données

---

# 1 — Amélioration des heuristiques du builder

## Situation actuelle

Le builder utilise des heuristiques simples basées sur :

- occurrences
- nombre de transactions
- jours actifs
- volume total

Ces heuristiques permettent de produire un premier set d’adresses exchange-like.

---

## Améliorations possibles

### Analyse des patterns de transactions

Détecter :

- consolidation patterns
- fan-in / fan-out
- patterns typiques des exchanges

---

### Détection des clusters

Regrouper les adresses liées entre elles via :

- heuristique des inputs communs
- analyse des graphes de transactions

Cela permettrait de reconstruire des clusters d'exchange.

---

### Distinction hot wallet / cold wallet

Analyser :

- fréquence d’activité
- taille des transactions
- régularité des mouvements

pour distinguer :

- hot wallets
- cold wallets

---

# 2 — Amélioration du scoring

## Situation actuelle

Le score `confidence` repose sur une formule heuristique simple.

---

## Améliorations possibles

Ajouter de nouveaux signaux :

- volume total transféré
- fréquence des transactions
- interactions avec d'autres adresses exchange-like
- stabilité dans le temps

---

# 3 — Détection des faux positifs

## Situation actuelle

Certains faux positifs peuvent apparaître dans le set exchange-like.

---

## Améliorations possibles

Identifier et filtrer :

- adresses de services non exchange
- mixers
- wallets personnels très actifs
- scripts automatisés

---

# 4 — Optimisation du scanner

## Situation actuelle

Le scanner parcourt tous les blocs nouveaux et vérifie chaque transaction.

---

## Améliorations possibles

### Optimisation des requêtes RPC

Limiter certains appels RPC inutiles.

---

### Pré-filtrage des transactions

Filtrer les transactions qui ne peuvent pas contenir d’adresses exchange-like.

---

### Optimisation SQL du traitement `spent`

Actuellement :

- le scanner vérifie les UTXO existants
- puis effectue un `upsert`

Une mise à jour SQL plus directe pourrait améliorer les performances.

---

# 5 — Gestion du volume de données

## Situation actuelle

La table :

```

exchange_observed_utxos

```

peut grossir rapidement.

---

## Améliorations possibles

### Politique de rétention

Supprimer ou archiver les UTXO anciens.

Par exemple :

- conserver les 12 derniers mois
- archiver les données historiques

---

### Partitionnement des tables

Partitionner `exchange_observed_utxos` par :

- année
- mois
- ou `seen_day`

Cela permettrait de maintenir des performances élevées à long terme.

---

# 6 — Amélioration des index

## Situation actuelle

Les index principaux sont en place.

---

## Améliorations possibles

Analyser régulièrement :

- les plans d'exécution SQL
- les index réellement utilisés

et ajuster les index si nécessaire.

---

# 7 — Observabilité

## Situation actuelle

La supervision repose sur :

- `JobRun`
- la page `/system`
- les logs cron

---

## Améliorations possibles

Ajouter :

- métriques Prometheus
- alertes en cas de blocage
- monitoring des volumes de données

---

# 8 — Visualisation du module

## Situation actuelle

Une vue `exchange_like` est prévue mais reste simple.

---

## Améliorations possibles

Créer une interface dédiée montrant :

- top adresses exchange-like
- évolution du nombre d’adresses
- activité récente des UTXO
- statistiques du scanner

---

# 9 — Enrichissement des données

## Améliorations possibles

Associer certaines adresses à :

- exchanges connus
- clusters publics
- bases de données open source

Cela permettrait d'enrichir l'analyse.

---

# 10 — Optimisation du builder à très grande échelle

Si le builder devait scanner de très grandes périodes :

- plusieurs années
- ou toute la blockchain

des optimisations supplémentaires pourraient être nécessaires :

- parallélisation
- batch RPC
- pipeline distribué

---

# Conclusion

La V1 du module `exchange_like` est volontairement simple :

- heuristiques lisibles
- architecture claire
- pipeline robuste
- fonctionnement incrémental

Les améliorations listées ici visent à préparer une V2 plus avancée.
