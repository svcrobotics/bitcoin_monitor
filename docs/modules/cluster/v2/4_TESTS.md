
# Bitcoin Monitor — Cluster V2 — Tests

Ce document décrit la stratégie de test de la V2 du module cluster.

La V2 ajoute une couche d’intelligence au-dessus du moteur V1 :
- profils enrichis
- classification
- score
- patterns simples
- rendu UI plus lisible

Le but des tests n’est pas de “prouver” une identité réelle,
mais de vérifier que :
- les calculs sont cohérents
- les enrichissements sont stables
- l’UI reste prudente et utile

---

# 1. Objectifs des tests

La V2 doit prouver que :

- les profils cluster sont correctement calculés
- les profils adresse sont correctement calculés
- la classification simple est cohérente
- le score simple est cohérent
- les patterns simples sont détectés sans casser la V1
- les pages UI enrichies restent lisibles
- le pipeline V2 peut être relancé sans incohérence majeure

---

# 2. Périmètre testé

## Inclus
- modèles `ClusterProfile`, `ClusterPattern`, `AddressProfile`
- services V2
- tâches rake V2
- enrichissement page adresse
- enrichissement page cluster
- monitoring V2

## Exclu en V2.1
- forensic complet
- AML complet
- attribution réelle certaine
- visualisation graphe avancée
- détection exhaustive CoinJoin

---

# 3. Niveaux de tests

## 3.1 Tests unitaires
Valider :
- modèles
- helpers de classification
- helpers de scoring
- helpers de détection simples

## 3.2 Tests de service
Valider :
- `ClusterAggregator`
- `ClusterClassifier`
- `ClusterScorer`
- `ClusterPatternDetector`
- `AddressProfiler`

## 3.3 Tests d’intégration
Valider :
- pipeline `cluster:v2_refresh`
- cohérence entre V1 et V2
- affichage UI enrichi

## 3.4 Recette produit
Valider :
- compréhension humaine
- prudence du wording
- utilité avant transfert

---

# 4. Jeux de données de test

## 4.1 Jeux synthétiques
Créer des clusters de tailles variées :
- cluster de taille 1
- cluster de taille 5
- cluster de taille 50
- cluster de taille 5000

Créer aussi :
- activité faible
- activité moyenne
- activité continue
- structure répétée

## 4.2 Jeux réels
Utiliser :
- quelques clusters réels observés
- une adresse observée dans un gros cluster
- une adresse observée dans un petit cluster
- une adresse valide non observée
- une adresse invalide

---

# 5. Tests des modèles

---

## 5.1 `ClusterProfile`

### À vérifier
- présence de `cluster_id`
- unicité de `cluster_id`
- association correcte avec `Cluster`

### Champs à vérifier
- `cluster_size`
- `tx_count`
- `active_days`
- `total_sent_sats`
- `first_seen_height`
- `last_seen_height`
- `classification`
- `score`

### Cas de test
- création valide
- unicité sur `cluster_id`
- mise à jour propre
- re-calcul sans duplication

---

## 5.2 `ClusterPattern`

### À vérifier
- présence de `cluster_id`
- unicité de `cluster_id`
- association correcte avec `Cluster`

### Champs à vérifier
- `coinjoin_detected`
- `repeated_structures`
- `automated_behavior_score`
- `unique_inputs_ratio`
- `avg_inputs_per_tx`

### Cas de test
- création valide
- update correct
- recalcul idempotent

---

## 5.3 `AddressProfile`

### À vérifier
- présence de `address_id`
- unicité de `address_id`
- association correcte avec `Address`

### Champs à vérifier
- `tx_count`
- `total_sent_sats`
- `active_span`
- `reuse_score`

### Cas de test
- création valide
- recalcul simple
- rattachement cluster cohérent

---

# 6. Tests du `ClusterAggregator`

## 6.1 Cluster vide ou incohérent
### Attendus
- pas de crash
- profil absent ou profil minimal
- erreur explicite si besoin

## 6.2 Petit cluster
### Données
- 3 adresses
- activité limitée
- volume faible

### Attendus
- `cluster_size = 3`
- `tx_count` cohérent
- `active_days` cohérent
- `total_sent_sats` cohérent

## 6.3 Gros cluster
### Données
- cluster réel ou synthétique de grande taille

### Attendus
- agrégats cohérents
- pas de lenteur excessive
- pas de doublon

## 6.4 Rebuild
### Attendus
- relancer l’aggregator ne crée pas de doublon
- le profil est mis à jour proprement

---

# 7. Tests du `ClusterClassifier`

## 7.1 Adresse isolée / cluster size 1
### Attendus
- classification prudente
- typiquement `unknown` ou équivalent

## 7.2 Petit cluster
### Attendus
- classification compatible avec `retail`

## 7.3 Cluster moyen
### Attendus
- classification compatible avec `service`

## 7.4 Très gros cluster
### Attendus
- classification compatible avec `exchange_like`

## 7.5 Cas ambigus
### Données
- taille grande mais activité faible
- taille moyenne mais volume élevé

### Attendus
- classification cohérente
- pas de wording absolu

---

# 8. Tests du `ClusterScorer`

## 8.1 Score minimal
### Données
- cluster faible, peu actif

### Attendus
- score bas ou modéré
- pas de crash sur valeurs manquantes

## 8.2 Score élevé
### Données
- cluster grand, actif, régulier

### Attendus
- score plus élevé
- cohérence avec classification

## 8.3 Score stable
### Attendus
- recalcul sur mêmes données = même score

## 8.4 Bords
### Attendus
- score borné
- pas de score négatif
- pas de score > maximum prévu

---

# 9. Tests du `ClusterPatternDetector`

## 9.1 Aucun pattern particulier
### Attendus
- `coinjoin_detected = false`
- score d’automatisation faible ou neutre

## 9.2 Pattern répétitif simple
### Données
- plusieurs structures similaires

### Attendus
- `repeated_structures > 0`

## 9.3 CoinJoin basique
### Données
- structure synthétique à sorties identiques

### Attendus
- détection prudente
- drapeau `coinjoin_detected = true`

## 9.4 Faux positifs
### Attendus
- ne pas marquer abusivement des services normaux
- documenter la prudence du signal

---

# 10. Tests du `AddressProfiler`

## 10.1 Adresse peu active
### Attendus
- `tx_count` correct
- `active_span` faible
- `reuse_score` simple et cohérent

## 10.2 Adresse très active
### Attendus
- `tx_count` élevé
- `total_sent_sats` élevé
- profil cohérent avec l’adresse

## 10.3 Adresse non clusterisée
### Attendus
- profil calculable
- `cluster_id` nil ou absent selon logique retenue

---

# 11. Tests des tâches rake V2

## 11.1 `cluster:build_profiles`
### Attendus
- crée / met à jour `cluster_profiles`
- pas de doublon

## 11.2 `cluster:detect_patterns`
### Attendus
- crée / met à jour `cluster_patterns`
- comportement idempotent

## 11.3 `cluster:score`
### Attendus
- remplit `score`
- pas d’erreur sur cluster incomplet

## 11.4 `cluster:v2_refresh`
### Attendus
- enchaîne correctement aggregation / classification / scoring / patterns
- journalisation claire
- sortie stable

---

# 12. Tests d’intégration UI — page adresse

## 12.1 Adresse observée dans gros cluster
### Attendus
- badge / lecture rapide visible
- classification visible
- score visible
- wording prudent
- linked addresses limitées
- preuves dédupliquées

## 12.2 Adresse observée dans petit cluster
### Attendus
- lecture rapide cohérente
- pas de sur-interprétation

## 12.3 Adresse valide non observée
### Attendus
- comportement inchangé
- message clair
- aucune erreur

## 12.4 Adresse invalide
### Attendus
- message clair
- aucune régression UI

---

# 13. Tests d’intégration UI — page cluster

## 13.1 Cluster enrichi
### Attendus
- classification affichée
- score affiché
- patterns visibles si disponibles

## 13.2 Cluster sans profil
### Attendus
- fallback propre
- pas de crash
- message sobre

## 13.3 Table index clusters enrichie
### Attendus
- colonnes cohérentes
- tri lisible
- pas de surcharge visuelle excessive

---

# 14. Tests de monitoring

## 14.1 Job V2 visible dans `/system`
### Attendus
- présence dans `job_health` si JobRun branché
- SLA correct
- statut correct

## 14.2 Tables V2 visibles
### Attendus
- fraîcheur de `cluster_profiles`
- fraîcheur de `cluster_patterns`
- statut OK / FAIL cohérent

## 14.3 Cron V2
### Attendus
- exécution sans erreur
- logs clairs
- retour non nul en cas d’échec

---

# 15. Tests d’idempotence

## 15.1 Rebuild profils
### Attendus
- pas de doublons
- profils mis à jour proprement

## 15.2 Recalcul score
### Attendus
- mêmes données → même score

## 15.3 Recalcul patterns
### Attendus
- mêmes données → mêmes flags ou mêmes valeurs

## 15.4 Pipeline complet
### Attendus
- plusieurs runs successifs ne dégradent pas la cohérence

---

# 16. Tests de performance

## 16.1 Gros volume
### Attendus
- refresh V2 supportable
- pas d’explosion mémoire
- pas de requêtes aberrantes

## 16.2 UI
### Attendus
- page adresse rapide
- page cluster supportable
- pas de N+1 évident

## 16.3 Recalculs
### Attendus
- le pipeline V2 ne nécessite pas un rescanning blockchain

---

# 17. Recette produit

## 17.1 Valeur perçue
Question :
- l’utilisateur comprend-il mieux l’adresse qu’en V1 ?

### Attendus
- oui, grâce à classification + lecture rapide + score

## 17.2 Prudence
Question :
- le produit évite-t-il les certitudes trompeuses ?

### Attendus
- oui, wording prudent

## 17.3 Utilité
Question :
- un utilisateur peut-il s’en servir avant un transfert ?

### Attendus
- oui, compréhension plus rapide du contexte

---

# 18. Définition de terminé — V2.1

La V2.1 sera considérée comme testée si :

- [ ] les profils cluster sont produits correctement
- [ ] la classification simple est cohérente
- [ ] le score simple est cohérent
- [ ] la page adresse affiche classification + score
- [ ] la page cluster affiche classification + score
- [ ] les preuves restent lisibles
- [ ] le wording reste prudent
- [ ] le pipeline V2 est relançable sans incohérence
- [ ] le monitoring système reflète correctement l’état

---

# 19. Philosophie de test

La V2 ne cherche pas à “prouver la vérité”.
Elle cherche à :

- enrichir le contexte
- améliorer l’interprétation
- garder un produit prudent et crédible

Les tests doivent donc vérifier :
- cohérence
- stabilité
- lisibilité
- honnêteté méthodologique