# Whale Scan : le moment où Bitcoin Monitor a commencé à surveiller les gros mouvements du réseau

> *Au départ, Bitcoin Monitor observait surtout le marché.*
>
> Les prix.
>
> Les variations.
>
> Les indicateurs classiques.
>
> Puis une question est apparue :
>
> > que se passe-t-il réellement sur la blockchain lorsqu’une énorme quantité de Bitcoin bouge ?
>
> Ce chapitre raconte comment un simple besoin de détection de “grosses transactions” a progressivement conduit à :
>
> * des heuristiques comportementales,
> * des classifications probabilistes,
> * des scanners blockchain massifs,
> * des problèmes de performance,
> * des datasets historiques,
> * et une nouvelle manière d’interpréter le marché.

---

## 1. Le problème initial

Au début, Bitcoin Monitor savait déjà :

* lire des blocs,
* récupérer des transactions,
* afficher des données marché.

Mais quelque chose manquait.

Le système observait :

```text id="x8srlq"
le prix
```

sans réellement observer :

```text id="8h1s9o"
les acteurs qui déplacent le capital.
```

Et dans Bitcoin :
les très gros mouvements sont rarement anodins.

---

## 2. Le mot “whale”

Dans l’écosystème crypto, un terme revient constamment :

```text id="cru79m"
whale
```

Une whale représente généralement :

* une entité,
* un fonds,
* un exchange,
* une institution,
* ou un très gros détenteur.

L’idée semblait simple :

> détecter les transactions énormes.

Mais très vite, la réalité est devenue beaucoup plus complexe.

---

## 3. Le premier scanner

La première version du système faisait quelque chose de relativement basique.

Le scanner :

* lisait les blocs récents,
* parcourait les transactions,
* calculait les montants déplacés,
* puis déclenchait des alertes.

Le pipeline ressemblait à ceci :

```text id="efhl8r"
Bitcoin Core RPC
      ↓
scan blocks
      ↓
parse transactions
      ↓
calculate outputs
      ↓
threshold detection
      ↓
alert
```

Le seuil initial ressemblait à :

```ruby id="prhny5"
MIN_BTC = 100
```

Si une transaction dépassait :

```text id="wyov6z"
100 BTC
```

elle devenait intéressante.

---

## 4. Le premier faux sentiment de simplicité

Au départ :
cela semblait suffisant.

Mais rapidement :
un problème important est apparu.

Une transaction énorme ne signifie pas forcément :

* achat,
* vente,
* panique,
* accumulation,
* ou mouvement institutionnel.

Parfois :
c’est juste un reshuffle interne.

---

## 5. Les premières classifications apparaissent

Le système a alors commencé à chercher :

> des comportements.

Pas seulement :

```text id="h7mdgc"
des montants.
```

Les premières heuristiques sont apparues.

Par exemple :

```ruby id="7tb7an"
outputs_nonzero_count >= 80
```

→ probable batching.

Ou :

```ruby id="9dskso"
largest_output_ratio >= 0.95
```

→ probable transfert unique.

---

## 6. Whale Scan cesse d’être un simple détecteur

C’est un moment important.

Le module ne cherchait plus seulement :

```text id="8av9sm"
de grosses transactions.
```

Il cherchait désormais :

```text id="2d7gzc"
des comportements blockchain.
```

Et cela change complètement la nature du système.

---

## 7. Les catégories apparaissent

Progressivement, plusieurs types sont apparus :

```ruby id="4n2k9o"
consolidation
distribution
batching
single_destination
other
```

Ces catégories semblent simples.

Mais elles représentent en réalité :

> une tentative d’interprétation probabiliste de comportements réels.

---

## 8. Le problème des exchanges

Très vite, une autre difficulté est apparue.

Certaines transactions ressemblaient énormément à :

* des dépôts exchange,
* des retraits,
* des reshuffles internes,
* des cold wallets.

Mais Bitcoin ne fournit jamais :

```text id="79a4ta"
type = exchange
```

Tout devait être inféré.

---

## 9. Les scores apparaissent

Le système a commencé à produire :

* des scores,
* des probabilités,
* des hints.

Par exemple :

```ruby id="3g9e4y"
exchange_likelihood
exchange_hint
score
```

Et là, un changement important est apparu :

> Bitcoin Monitor cessait progressivement d’être déterministe.

---

## 10. Le système devient probabiliste

C’est une évolution très importante dans une application d’analyse.

Avant :

```text id="gdn5ff"
true / false
```

Après :

```text id="hxtm4v"
probablement
possiblement
fortement suspect
```

Le système commençait à accepter :

> l’incertitude.

---

## 11. Les datasets commencent à exploser

Au départ :
quelques alertes suffisaient.

Mais progressivement :

* les scans deviennent continus,
* les blocs s’accumulent,
* les transactions grossissent,
* les historiques deviennent énormes.

Le système devait maintenant stocker :

* les scores,
* les catégories,
* les timestamps,
* les comportements,
* les métadonnées.

---

## 12. La table WhaleAlert devient centrale

Une nouvelle structure devient progressivement critique :

```ruby id="t6kgnt"
WhaleAlert
```

Avec des colonnes comme :

* txid,
* block_height,
* total_out_btc,
* outputs_nonzero_count,
* largest_output_ratio,
* exchange_likelihood,
* alert_type,
* meta.

Le module cessait progressivement d’être :

```text id="a3nny7"
un scanner temporaire.
```

Il devenait :

```text id="5fcf9g"
une base comportementale historique.
```

---

## 13. Les performances deviennent un sujet

Puis un autre problème est apparu.

Le scanner devait maintenant :

* lire énormément de blocs,
* parser énormément de transactions,
* calculer énormément d’heuristiques.

Et surtout :

```text id="u9msaq"
faire cela continuellement.
```

Les premiers symptômes sont apparus :

* scans longs,
* CPU élevé,
* jobs qui dérivent,
* requêtes SQL lourdes.

---

## 14. Le mode pruned change les règles

Bitcoin Monitor utilisait un nœud Bitcoin Core en mode pruned.

Et cela change énormément de choses.

Pourquoi ?

Parce que :

* certaines données anciennes disparaissent,
* certains prevouts ne sont plus accessibles,
* certaines stratégies deviennent impossibles.

Le scanner devait donc devenir :

> pruned-safe.

---

## 15. Les blocs deviennent des ressources coûteuses

Le système a commencé à comprendre quelque chose d’important :

> chaque appel RPC a un coût.

Lire :

* des blocs,
* des transactions,
* des prevouts,
* des scripts,
* en boucle,
  peut rapidement devenir très cher.

---

## 16. Le scanner devient incrémental

Au début :
le système rescannait énormément.

Mais cela devenait impossible.

Bitcoin Monitor a alors introduit :

* des curseurs,
* des last scanned blocks,
* des scans incrémentaux,
* des safety cutoffs,
* des confirmations minimales.

Le scanner devenait :

```text id="5gx9k2"
un pipeline vivant.
```

---

## 17. Le système commence à apprendre des comportements

Puis un autre déclic est apparu.

Whale Scan pouvait servir à :

* enrichir Exchange Like,
* alimenter Inflow / Outflow,
* détecter des signaux,
* apprendre des comportements exchange.

Le module cessait d’être isolé.

---

## 18. Whale Scan devient une fondation

Progressivement :

```text id="crltc6"
Whale Scan
     ↓
Exchange Like
     ↓
Observed UTXO
     ↓
Inflow / Outflow
     ↓
Market interpretation
```

Le système devenait :

> interconnecté.

---

## 19. Le vrai problème n’était plus la détection

Le vrai problème devenait :

> comment interpréter correctement les mouvements ?

Parce qu’un énorme transfert peut représenter :

* une vente,
* une accumulation,
* une consolidation,
* un transfert interne,
* un mouvement OTC,
* un simple déplacement de cold wallet.

Le contexte devenait plus important que :

```text id="c6of7m"
la taille brute.
```

---

## 20. Les scanners deviennent des systèmes

À ce stade :
Whale Scan n’était plus :

```text id="mjtyrm"
un job cron.
```

Il devenait :

* un pipeline,
* un dataset,
* un moteur comportemental,
* une source transverse d’intelligence.

Et cela change complètement la manière de concevoir l’architecture.

---

## 21. Les futurs problèmes deviennent visibles

À ce moment-là :
plusieurs tensions futures apparaissaient déjà :

* Redis,
* batch processing,
* parallélisation,
* queues,
* observabilité,
* backfills,
* stockage massif.

Mais cette fois :

> les problèmes étaient compris.

---

## 22. Le système commence à lire le marché autrement

Avant Whale Scan :
Bitcoin Monitor observait surtout :

* le prix,
* les indicateurs,
* les chandeliers.

Après Whale Scan :
le système commençait à observer :

* les comportements,
* les acteurs,
* les flux massifs,
* les structures du marché.

Et cette différence est énorme.

---

## 23. Les leçons apprises

### Les gros montants seuls ne suffisent pas

Le contexte comportemental est essentiel.

---

### Les heuristiques deviennent inévitables

Bitcoin ne fournit presque jamais :

```text id="c8wz9t"
la vérité métier.
```

Tout doit être inféré.

---

### Les systèmes deviennent rapidement probabilistes

Les scores remplacent progressivement :

```text id="kr4cfr"
les booléens simples.
```

---

### Les scanners blockchain deviennent des pipelines vivants

Ils nécessitent :

* observabilité,
* progression,
* supervision,
* reprise,
* monitoring.

---

### Les datasets historiques deviennent précieux

Car ils permettent :

* l’apprentissage,
* les corrélations,
* les signaux,
* les comportements long terme.

---

## 24. Conclusion

Le module Whale Scan a profondément changé Bitcoin Monitor.

Avant lui :

* l’application observait principalement des données marché.

Après lui :

* elle commençait à surveiller les comportements réels du capital sur la blockchain.

Et ce changement a transformé :

* les pipelines,
* les datasets,
* les scanners,
* les heuristiques,
* et la manière même d’interpréter le marché.

Parce qu’au final :

> observer les whales revient souvent à essayer de comprendre les mouvements invisibles du système financier Bitcoin.
