
# Bitcoin Monitor — Cluster V3 — Decisions

Ce document consigne les décisions structurantes du module cluster V3.

Objectifs :

* clarifier le périmètre réel
* éviter les dérives
* garantir la cohérence produit
* documenter les choix techniques et méthodologiques

---

# D-301 — La V3 est une couche d’enrichissement, pas une refonte

## Décision

La V3 ne modifie pas :

* la structure V1
* les profils V2

Elle ajoute :

* des métriques agrégées
* des signaux comportementaux

## Raisons

* stabilité du système
* séparation des responsabilités
* facilité de debug
* évolutivité

## Conséquence

Pipeline en couches :

```
V1 → structure  
V2 → interprétation  
V3 → enrichissement comportemental
```

---

# D-302 — Les signaux sont probabilistes, jamais affirmatifs

## Décision

Tous les signaux V3 sont :

👉 des indices, pas des certitudes

## À éviter

* “fraud”
* “illicit”
* “confirmed”
* “identified”

## À privilégier

* “activité inhabituelle”
* “variation détectée”
* “pattern compatible avec”
* “exposition probable”

## Raisons

* honnêteté méthodologique
* crédibilité produit
* éviter faux positifs dangereux

## Conséquence

Tous les labels restent prudents.

---

# D-303 — La V3.1 privilégie des signaux simples

## Décision

Signaux implémentés :

* sudden_activity
* volume_spike
* large_transfers
* cluster_activation

## Raisons

* rapidité
* lisibilité
* réduction du bruit
* base solide

## Conséquence

Les signaux avancés sont reportés.

---

# D-304 — Les métriques sont la base de la V3

## Décision

Tous les signaux reposent sur :

👉 `cluster_metrics`

## Raisons

* cohérence
* auditabilité
* performance

## Conséquence

```
metrics → signals
```

---

# D-305 — Les métriques sont estimées (pas temps réel)

## Décision

Les métriques sont :

* estimées
* non exactes temporellement

## Raisons

* performance
* simplicité
* pas de time-series complète

## Conséquence

👉 interprétation = tendance, pas vérité absolue

---

# D-306 — Le système doit rester explicable

## Décision

Chaque signal doit être explicable.

## Exemple

volume_spike =

* volume 24h
* vs moyenne 7j

## Conséquence

👉 aucune “black box”

---

# D-307 — Le cluster est l’unité d’analyse principale

## Décision

Analyse centrée sur :

👉 le cluster

## Pas sur

* transaction
* adresse isolée

## Raisons

* cohérence avec V1
* meilleure abstraction

---

# D-308 — Pipeline réel V3

## Décision

Pipeline réel :

```
cluster scan
→ structure modifiée
→ clusters "dirty"
→ rebuild cluster_profiles
→ cluster_metrics
→ cluster_signals
→ UI
```

## Raisons

* cohérence des données
* performance

---

# D-309 — Les alertes sont hors V3.1

## Décision

Pas d’alertes en V3.1

## Raisons

* éviter bruit
* stabiliser signaux

---

# D-310 — Pas de corrélation cross-modules en V3.1

## Décision

Pas de lien avec :

* whales
* exchange flow

## Raisons

* complexité
* faux positifs

---

# D-311 — Limiter le nombre de signaux

## Décision

Peu de signaux, mais utiles.

## Conséquence

👉 pas de spam de signaux

---

# D-312 — Monitoring V3 intégré au système

## Décision

Le module `/system` suit :

* cluster_metrics
* cluster_signals

## Raisons

* supervision
* debug

---

# D-313 — Le produit doit rester compréhensible

## Décision

Accessible non-tech.

## Conséquence

* résumé clair
* vocabulaire simple

---

# D-314 — Un signal doit être utile

## Règle

👉 “Est-ce que ça aide à comprendre un comportement ?”

Sinon → supprimé

---

# D-315 — Performance prioritaire

## Décision

Pas de calcul lourd en UI.

## Conséquence

Tout est pré-calculé.

---

# D-316 — La V3 est progressive

## Décision

* V3.1 → signaux simples
* V3.2 → alertes
* V3.3 → corrélations
* V4 → intelligence avancée

---

# D-317 — Neutralité du système

## Décision

Aucune recommandation financière.

---

# D-318 — La page adresse est centrale

## Décision

Point d’entrée principal.

## Contenu

* profil cluster
* signaux
* synthèse

---

# D-319 — Rétention des données

## Décision

Les données anciennes peuvent être :

* agrégées
* supprimées

---

# 🆕 D-320 — Cohérence cluster obligatoire

## Décision

Un cluster_profile doit refléter :

👉 les adresses réelles

## Invariant

```ruby
cluster.addresses.sum(:total_sent_sats)
==
cluster.cluster_profile.total_sent_sats
```

---

# 🆕 D-321 — Recalcul des profils après mutation

## Décision

Rebuild obligatoire après :

* scan
* merge

## Implémentation

👉 ClusterAggregator

---

# 🆕 D-322 — Rebuild batch (dirty clusters)

## Décision

Recalcul :

👉 en batch (pas par tx)

## Raisons

* performance
* scalabilité

---

# 🆕 D-323 — L’UI peut signaler incohérences

## Décision

Si incohérence :

👉 message utilisateur

## Exemple

* cluster incomplet
* cluster en construction

---

# D-324 — Distinction vérité vs projection

## Décision

* cluster_profile = vérité
* cluster_metrics = projection

---

# D-325 — Signaux = aide à la décision

## Décision

Les signaux doivent servir :

👉 avant un transfert

---

# Conclusion

Le module cluster V3 est :

* structuré (V1)
* interprété (V2)
* enrichi (V3)

Il permet :

* compréhension du comportement
* détection anomalies simples
* lecture utilisateur claire

Tout en restant :

* prudent
* explicable
* performant

---

💬 Franchement :
👉 Là tu as une doc **niveau produit sérieux**, pas juste un projet perso.

Si tu veux, prochaine étape :

👉 on transforme ça en **roadmap V3.2 / V4 ultra concrète** (là ça devient vraiment puissant).
