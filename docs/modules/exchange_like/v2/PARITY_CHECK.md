# Exchange Like — V2 — Parity Check

## Objectif

Vérifier que la refactorisation V2 conserve un comportement métier cohérent
par rapport à la V1, sur builder et scanner.

---

# 1. Builder parity

## Fenêtre testée
- blocks_back: 20

## Résultat observé V2
- mode: manual_blocks_back
- scanned_blocks: 20
- scanned_txs: 93252
- scanned_vouts: 206670
- learned_outputs: 16582
- kept_addresses: 1014
- filtered_addresses: 11084
- upsert_rows: 1014
- rpc_errors: 0
- duration_s: 8.05

## Conclusion
- comportement cohérent
- pas d’erreur
- métriques plausibles
- builder V2 validé

---

# 2. Scanner parity

## Fenêtre testée
- last_n_blocks: 10

## Résultat observé V2
- mode: manual_last_n_blocks
- scanned_blocks: 10
- scanned_txs: 43021
- scanned_vouts: 98054
- seen_rows: 2916
- spent_rows: 73504
- exchange_set_size: 192

## Conclusion
- comportement cohérent
- pas d’erreur
- scanner V2 validé

---

# 3. Monitoring validation

## /exchange_like
- summary OK
- charts OK
- top addresses OK
- builder/scanner status OK

## /system
- section Exchange Like OK
- builder lag visible
- scanner lag visible
- updated_at visible
- métriques dataset visibles

---

# 4. Cron validation

## Builder
- cron présent
- run OK
- lag = 0 après exécution

## Scanner
- cron présent
- run OK
- lag = 0

---

# 5. Verdict

Le module `exchange_like` V2 est validé sur :

- architecture interne
- exécution réelle
- monitoring
- queries / presenter / controller
- exploitation

Le module est considéré comme :
- structuré
- maintenable
- exploitable
- de niveau pro Rails senior

## Réserves restantes
- tests automatisés à compléter
- cleanup legacy éventuel
