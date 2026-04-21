# Exchange Like — V2 — Builder Parity Check

## Objectif
Vérifier que le refacto V2 du builder conserve un comportement métier cohérent
par rapport à la V1 sur une même fenêtre de scan.

## Fenêtre testée
- blocks_back: 20

## Référence V1
- scanned_blocks:
- scanned_txs:
- scanned_vouts:
- learned_outputs:
- kept_addresses:
- filtered_addresses:
- upsert_rows:
- duration_s:
- exchange_addresses_total:

## Résultat V2
- scanned_blocks:
- scanned_txs:
- scanned_vouts:
- learned_outputs:
- kept_addresses:
- filtered_addresses:
- upsert_rows:
- duration_s:
- exchange_addresses_total:

## Écart observé
- écarts mineurs attendus :
- écarts anormaux :
- conclusion :

## Validation
- [ ] comportement cohérent
- [ ] pas de régression visible
- [ ] builder V2 validé
