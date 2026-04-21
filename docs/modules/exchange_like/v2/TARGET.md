# Exchange Like — V2 — Target Architecture

---

# 1. Objectif

Le module `exchange_like` V2 a pour objectif :

- d’identifier des adresses Bitcoin probablement liées à des exchanges
- de maintenir une base fiable et évolutive (`exchange_addresses`)
- de fournir cette base aux modules consommateurs (exchange_flow, clusters, etc.)

Le module est une **brique de connaissance**, pas un module d’analyse marché.

---

# 2. Hors périmètre

Le module ne fait pas :

- calcul d’inflow / outflow
- KPI marché
- interprétation financière
- dashboard final utilisateur

---

# 3. Inputs

- blocs Bitcoin (via RPC)
- transactions
- outputs (vout)
- historique interne (`exchange_addresses`)
- patterns heuristiques
- (optionnel) signaux externes (whale_alerts, datasets publics)

---

# 4. Outputs

## Table principale

`exchange_addresses`

Chaque entrée contient :

- address
- confidence
- occurrences
- tx_count
- first_seen_at
- last_seen_at
- source
- metadata (JSON)

---

# 5. Sous-modules

## 5.1 Scan Range Resolver
Détermine la plage de blocs à scanner.

## 5.2 Output Candidate Extractor
Extrait les outputs pertinents depuis les blocs.

## 5.3 Address Aggregator
Agrège les données en mémoire :

- occurrences
- txids
- volume
- activité

## 5.4 Address Filter
Filtre les candidats :

- outputs trop petits
- outputs trop gros
- scripts non pertinents
- patterns invalides

## 5.5 Address Scorer
Attribue un score basé sur :

- fréquence
- volume
- diversité
- stabilité

## 5.6 Address Upserter
Persiste les résultats dans `exchange_addresses`.

## 5.7 Cursor Manager
Gère le scan incrémental.

---

# 6. Pipeline cible

Blockchain
→ Extraction outputs
→ Agrégation
→ Filtrage
→ Scoring
→ Upsert exchange_addresses

---

# 7. Scoring V2

Le score `confidence` doit devenir :

- explicite
- documenté
- testable

## Signaux utilisés

- occurrences
- volume total
- fréquence des transactions
- nombre de jours actifs
- diversité des contreparties
- interactions avec adresses exchange-like existantes

## Évolutions futures

- score pondéré
- score dynamique
- score basé sur clusters

---

# 8. Détection des faux positifs

Le module doit filtrer :

- services non exchange
- mixers
- wallets personnels actifs
- scripts automatisés

## Approches possibles

- heuristiques négatives
- blacklist
- détection comportementale

---

# 9. Monitoring V2

Le module doit exposer :

## Builder

- dernier run
- durée
- blocs scannés
- candidats détectés
- adresses retenues
- adresses rejetées

## Dataset

- nombre total d’adresses
- nouvelles adresses (24h)
- adresses mises à jour (24h)
- distribution des scores

## Scanner (si utilisé avec observation)

- UTXO seen
- UTXO spent
- activité récente

## Santé

- lag du curseur
- erreurs récentes
- performance du scan

---

# 10. Scalabilité

## Volume de données

- `exchange_observed_utxos` peut devenir très volumineuse

### Solutions

- politique de rétention
- archivage
- partitionnement (par mois ou année)

## Builder

- optimisation RPC
- pré-filtrage des transactions
- batching

## Future

- parallélisation du scan
- pipeline distribué

---

# 11. Redis (usage futur)

Redis n’est pas nécessaire en V1.

En V2, il pourra être utilisé pour :

- cache des adresses “chaudes”
- accélération du scan
- stockage temporaire des candidats
- file d’événements (optionnel)

---

# 12. Règles d’architecture

- PostgreSQL = source de vérité
- Redis = cache / accélérateur
- services spécialisés
- jobs courts et orchestrateurs
- logique métier testable
- pas de calcul lourd en controller

---

# 13. Roadmap d’implémentation

## Phase 1 — Clarification
- documenter V1
- définir le périmètre
- clarifier le pipeline

## Phase 2 — Refactor builder
- découper ExchangeAddressBuilder
- isoler scoring
- isoler filtrage

## Phase 3 — Monitoring
- enrichir /system
- ajouter métriques métier

## Phase 4 — Optimisation
- améliorer heuristiques
- réduire faux positifs
- optimiser SQL / RPC

## Phase 5 — Scalabilité
- gestion volume
- partitionnement
- performance long terme

---

# 14. Position dans l’architecture globale

Whales / Blockchain
→ exchange_like
→ exchange_addresses
→ exchange_observation
→ exchange_flow
→ dashboard

---

# Conclusion

La V2 du module `exchange_like` transforme un builder heuristique simple en :

- un système structuré
- un pipeline clair
- une base de connaissance fiable
- une brique réutilisable et scalable
