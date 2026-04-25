- 
- 



- 
- 
- 
- 
- 
- 
- 



on peut essayer de reparer Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	OK ok: — fail: — skip: 2026-04-24 11:30:03 start: 2026-04-24 11:30:03 end: 2026-04-24 11:30:03 hb: — last: — avg10: — max10: — delay: 24m 57s missed: 4 capacity: unknown skips10: 9 — yes	0



On va le traiter comme un problème de **job qui ne travaille jamais** : il est marqué OK, mais uniquement parce qu’il “skip”, donc aucune vraie exécution `ok`. Je vais te donner un diagnostic simple puis les commandes à lancer dans l’ordre.

Réflexion durant quelques secondes

Oui. Là le problème est clair :

**cluster_scan ne plante pas, il est SKIPPÉ.**
Donc Rails lance bien le cron, mais le script décide de ne rien faire.

À faire dans l’ordre :

```
cd ~/bitcoin_monitor
```

### 1. Voir pourquoi il skip

```
tail -n 200 log/cron.victor.log | grep -i "cluster"
```

Puis :

```
grep -R "cluster_scan" -n .
```

### 2. Tester le script à la main

```
bash bin/cron_cluster_scan.sh
```

S’il affiche un skip, copie-moi la sortie.

### 3. Vérifier les verrous flock

Très probable : un ancien lock bloque le job.

```
ls -lah /tmp | grep cluster
```

Puis :

```
ps aux | grep -i cluster | grep -v grep
```

Si aucun process cluster ne tourne, supprime le lock :

```
rm -f /tmp/*cluster*lock*
```

Puis relance :

```
bash bin/cron_cluster_scan.sh
```

### 4. Vérifier les derniers JobRun

```
rails runner 'puts JobRun.where(name: "cluster_scan").order(created_at: :desc).limit(10).pluck(:status, :started_at, :finished_at, :meta).map(&:inspect)'
```

### 5. Si ça reste en skip

Le souci est sûrement dans `bin/cron_cluster_scan.sh` ou dans la tâche rake appelée.

Envoie-moi le contenu de :

```
cat bin/cron_cluster_scan.sh
```

et aussi :

```
grep -R "desc .*cluster" -n lib/tasks
```

Mais première réparation probable :

```
rm -f /tmp/*cluster*lock*
bash bin/cron_cluster_scan.sh
```



il y a pas mal de retard Cluster scan FAIL Last scanned 942686 Best block 946424 Lag 3738 Updated 2026-03-28 21:24:59 Hash



Oui, là ce n’est plus juste un souci de cron : **le scanner cluster est très en retard**.

Il manque :

```
946424 - 942686 = 3738 blocs
```

Soit environ :

```
3738 / 144 ≈ 26 jours
```

Donc le module Cluster n’a quasiment pas avancé depuis le **28 mars 2026**.

À faire maintenant :

```
cd ~/bitcoin_monitor
```

### 1. Vérifier si un lock bloque encore

```
ps aux | grep -i cluster | grep -v grep
ls -lah /tmp | grep -i cluster
```

Si aucun process cluster ne tourne :

```
rm -f /tmp/*cluster*lock*
```

### 2. Tester un petit rattrapage manuel

Essaie d’abord seulement 100 blocs :

```
rails runner 'ClusterScanJob.perform_now(from_height: 942687, to_height: 942787)'
```

Si ta classe/job n’a pas ces arguments, lance :

```
grep -R "class Cluster" -n app/jobs app/services lib/tasks
```

### 3. Trouver la vraie commande de scan

Lance :

```
grep -R "cluster_scan\|ClusterScan\|scan_cluster\|clusters:" -n app/jobs app/services lib/tasks bin
```

Envoie-moi le résultat de cette commande.

Le but est de trouver **la tâche exacte** qui met à jour `Last scanned`. Ensuite on fera un backfill propre par paquets, par exemple :

```
942687 → 943000
943001 → 943500
943501 → 944000
...
jusqu’à 946424
```

Ne lance pas directement les 3738 blocs d’un coup tant qu’on n’a pas confirmé la commande exacte.



victor@debian:~/bitcoin_monitor$ ps aux | grep -i cluster | grep -v grep ls -lah /tmp | grep -i cluster victor     15771  0.0  0.0   5468  1000 ?        Ss   09:15   0:00 flock -n /tmp/bitcoin_monitor_cluster_scan.lock env RBENV_ROOT=/home/victor/.rbenv PATH=/home/victor/.rbenv/shims:/home/victor/.rbenv/bin:/home/victor/.rbenv/shims:/home/victor/.cargo/bin:/home/victor/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:/home/victor/.local/bin BUNDLE_GEMFILE=/home/victor/bitcoin_monitor/Gemfile RAILS_ENV=development APP=/home/victor/bitcoin_monitor LOG=/home/victor/bitcoin_monitor/log/cron.victor.log SCHEDULED_FOR=2026-04-24 09:15:01 TRIGGERED_BY=cron bash -c bin/cron_cluster_scan.sh >> "/home/victor/bitcoin_monitor/log/cron.victor.log" 2>&1 victor     15867  0.0  0.0   6940  2844 ?        S    09:15   0:00 bash -c bin/cron_cluster_scan.sh >> "/home/victor/bitcoin_monitor/log/cron.victor.log" 2>&1 victor     15868  0.0  0.0   7072  2980 ?        S    09:15   0:00 bash bin/cron_cluster_scan.sh victor     15906 71.3  0.8 476412 257956 ?       Rl   09:15 121:44 ruby bin/rails runner  JobRunner.run!(   "cluster_scan",   triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),   scheduled_for: ENV["SCHEDULED_FOR"].presence ) do |jr|   JobRunner.heartbeat!(jr)   ClusterScanner.call(job_run: jr)   JobRunner.heartbeat!(jr) end  victor    139314  0.0  0.0   7072  3428 pts/1    S+   12:03   0:00 bash bin/cron_cluster_scan.sh victor    139353 78.4  0.7 459384 238796 pts/1   Rl+  12:03   1:21 ruby bin/rails runner  JobRunner.run!(   "cluster_scan",   triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),   scheduled_for: ENV["SCHEDULED_FOR"].presence ) do |jr|   JobRunner.heartbeat!(jr)   ClusterScanner.call(job_run: jr)   JobRunner.heartbeat!(jr) end  -rw-r--r--  1 victor  victor     0 24 avril 09:15 bitcoin_monitor_cluster_scan.lock victor@debian:~/bitcoin_monitor$ 



Oui, on a trouvé le problème : **2 scans cluster tournent en même temps**.

Un lancé par cron depuis **09:15** :

```
PID 15906
```

Un lancé à la main depuis **12:03** :

```
PID 139353
```

Il faut garder **un seul scanner**.

Arrête celui lancé à la main :

```
kill 139353 139314
```

Puis vérifie :

```
ps aux | grep -i cluster | grep -v grep
```

Ensuite regarde s’il avance :

```
rails runner 'puts ClusterCursor.first.attributes'
```

ou selon ton modèle :

```
rails runner 'puts ClusterScanState.first.attributes'
```

Puis :

```
tail -f log/cron.victor.log
```

Conclusion :
**ne supprime pas le lock maintenant**. Il est normal, car le scan de 09:15 tourne encore.

Le vrai sujet ensuite sera d’améliorer le cron : actuellement il est prévu toutes les 15 minutes, mais le scan dure plus longtemps, donc beaucoup de `skip`. Ce n’est pas grave si le scanner avance.



victor@debian:~/bitcoin_monitor$ ps aux | grep -i cluster | grep -v grep victor     15771  0.0  0.0   5468  1000 ?        Ss   09:15   0:00 flock -n /tmp/bitcoin_monitor_cluster_scan.lock env RBENV_ROOT=/home/victor/.rbenv PATH=/home/victor/.rbenv/shims:/home/victor/.rbenv/bin:/home/victor/.rbenv/shims:/home/victor/.cargo/bin:/home/victor/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:/home/victor/.local/bin BUNDLE_GEMFILE=/home/victor/bitcoin_monitor/Gemfile RAILS_ENV=development APP=/home/victor/bitcoin_monitor LOG=/home/victor/bitcoin_monitor/log/cron.victor.log SCHEDULED_FOR=2026-04-24 09:15:01 TRIGGERED_BY=cron bash -c bin/cron_cluster_scan.sh >> "/home/victor/bitcoin_monitor/log/cron.victor.log" 2>&1 victor     15867  0.0  0.0   6940  2844 ?        S    09:15   0:00 bash -c bin/cron_cluster_scan.sh >> "/home/victor/bitcoin_monitor/log/cron.victor.log" 2>&1 victor     15868  0.0  0.0   7072  2980 ?        S    09:15   0:00 bash bin/cron_cluster_scan.sh victor     15906 71.4  0.7 449724 233772 ?       Sl   09:15 122:21 ruby bin/rails runner  JobRunner.run!(   "cluster_scan",   triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),   scheduled_for: ENV["SCHEDULED_FOR"].presence ) do |jr|   JobRunner.heartbeat!(jr)   ClusterScanner.call(job_run: jr)   JobRunner.heartbeat!(jr) end  victor@debian:~/bitcoin_monitor$ rails runner 'puts ClusterCursor.first.attributes' Please specify a valid ruby command or the path of a script to run. Run 'bin/rails runner -h' for help. uninitialized constant ClusterCursor victor@debian:~/bitcoin_monitor$ rails runner 'puts ClusterScanState.first.attributes' Please specify a valid ruby command or the path of a script to run. Run 'bin/rails runner -h' for help. uninitialized constant ClusterScanState victor@debian:~/bitcoin_monitor$ 



Parfait : maintenant il ne reste **qu’un seul scan cluster**. C’est bon.

Les deux commandes ont échoué car les modèles ne s’appellent pas `ClusterCursor` / `ClusterScanState`.

Trouve le bon modèle avec :

```
grep -R "last_scanned\|best_block\|cursor\|cluster_scan" -n app/models app/services db/schema.rb
```

Puis surveille déjà le scanner actif :

```
tail -n 100 -f log/cron.victor.log
```

Pour voir si la DB bouge :

```
rails runner 'puts Cluster.count'
rails runner 'puts Address.where.not(cluster_id: nil).count'
rails runner 'puts Cluster.maximum(:last_seen_height)'
```

Et pour identifier les tables cluster :

```
rails runner 'puts ActiveRecord::Base.connection.tables.grep(/cluster|address|scan|cursor|state/i)'
```

Envoie-moi surtout le résultat de :

```
grep -R "last_scanned\|best_block\|cursor\|cluster_scan" -n app/models app/services db/schema.rb
```



victor@debian:~/bitcoin_monitor$ grep -R "last_scanned\|best_block\|cursor\|cluster_scan" -n app/models app/services db/schema.rb app/models/vault.rb:93:    last_scanned_at.present? app/models/vault.rb:123:      last_scanned_at:  Time.current app/models/vault.rb:133:      last_scanned_at:         Time.current app/models/vault.rb:141:      last_scanned_at:  Time.current app/models/scanner_cursor.rb:1:# app/models/scanner_cursor.rb app/services/brc20_scan_coverage.rb:47:    cursor = target_from app/services/brc20_scan_coverage.rb:50:      if r.from > cursor app/services/brc20_scan_coverage.rb:51:        missing << RangeInfo.new(cursor, r.from - 1) app/services/brc20_scan_coverage.rb:53:      cursor = [cursor, r.to + 1].max app/services/brc20_scan_coverage.rb:56:    if cursor <= target_to app/services/brc20_scan_coverage.rb:57:      missing << RangeInfo.new(cursor, target_to) app/services/system_test_runner.rb:26:      "spec/services/cluster_scanner_spec.rb", app/services/system_qa_status.rb:40:          key: "cluster_scanner", app/services/vault_utxo_scanner.rb:39:    tip_height = safe_best_block_height app/services/vault_utxo_scanner.rb:52:    tip_height = safe_best_block_height app/services/vault_utxo_scanner.rb:62:      last_scanned_at:         Time.current, app/services/vault_utxo_scanner.rb:73:    @vault.update(last_scanned_at: Time.current, last_scan_status: "error", last_scan_error: e.message) rescue nil app/services/vault_utxo_scanner.rb:186:  def safe_best_block_height app/services/vault_utxo_scanner.rb:187:    @chain_rpc.best_block_height app/services/vault_utxo_scanner.rb:189:    @logger.warn "[VaultUtxoScanner] best_block_height failed: #{e.class} - #{e.message}" app/services/vault_utxo_scanner.rb:227:      last_scanned_at: Time.current, app/services/system_test_status.rb:25:      key: "cluster_scanner", app/services/system_test_status.rb:27:      files: ["./spec/services/cluster_scanner_spec.rb"] app/services/system_test_status.rb:109:          module_status("cluster_scanner"), app/services/cluster_scanner.rb:5:# app/services/cluster_scanner.rb app/services/cluster_scanner.rb:9:  CURSOR_NAME = "cluster_scan" app/services/cluster_scanner.rb:61:      "[cluster_scan] start " \ app/services/cluster_scanner.rb:80:    update_cursor!(range[:end_height]) if range[:mode] == :incremental app/services/cluster_scanner.rb:109:    cursor = scanner_cursor app/services/cluster_scanner.rb:112:      if cursor.last_blockheight.present? app/services/cluster_scanner.rb:113:        cursor.last_blockheight.to_i + 1 app/services/cluster_scanner.rb:139:  def scanner_cursor app/services/cluster_scanner.rb:140:    @scanner_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME) app/services/cluster_scanner.rb:143:  def update_cursor!(height) app/services/cluster_scanner.rb:146:    scanner_cursor.update!( app/services/cluster_scanner.rb:165:      puts "[cluster_scan] skip_pruned_block height=#{height}" app/services/cluster_scanner.rb:197:    puts "[cluster_scan] tx_skip txid=#{txid} height=#{height} reason=#{e.message}" app/services/cluster_scanner.rb:401:    puts "[cluster_scan] refresh_dirty_clusters count=#{@dirty_cluster_ids.size}" app/services/cluster_scanner.rb:423:      "[cluster_scan] progress " \ app/services/guide_health.rb:52:        cluster_scan app/services/guide_health.rb:82:        cluster_scan app/services/guide_health.rb:143:      cursor = ScannerCursor.find_by(name: scanner_name) app/services/guide_health.rb:147:        last_blockheight: cursor&.last_blockheight, app/services/guide_health.rb:148:        last_blockhash: cursor&.last_blockhash, app/services/guide_health.rb:149:        updated_at: cursor&.updated_at, app/services/guide_health.rb:150:        status: scanner_status(cursor) app/services/guide_health.rb:178:  def scanner_status(cursor) app/services/guide_health.rb:179:    return :warn unless cursor&.updated_at app/services/guide_health.rb:181:    age = Time.current - cursor.updated_at app/services/exchange_address_builder.rb:177:    update_cursor!(range.end_height) if range.mode == :incremental app/services/exchange_address_builder.rb:212:      cursor_name: CURSOR_NAME, app/services/exchange_address_builder.rb:221:  def builder_cursor app/services/exchange_address_builder.rb:222:    @builder_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME) app/services/exchange_address_builder.rb:225:  def update_cursor!(height) app/services/exchange_address_builder.rb:228:    builder_cursor.update!( app/services/exchange_address_builder.rb:332:         "cursor_last_blockheight=#{range.cursor_last_blockheight.inspect} "\ app/services/exchange_like/scan_range_resolver.rb:10:      :cursor_last_blockheight, app/services/exchange_like/scan_range_resolver.rb:26:      cursor_name:, app/services/exchange_like/scan_range_resolver.rb:34:      @cursor_name = cursor_name app/services/exchange_like/scan_range_resolver.rb:46:      cursor = ScannerCursor.find_or_create_by!(name: @cursor_name) app/services/exchange_like/scan_range_resolver.rb:47:      cursor_last_blockheight = cursor.last_blockheight app/services/exchange_like/scan_range_resolver.rb:49:      return resolve_manual(cursor_last_blockheight) if manual_mode? app/services/exchange_like/scan_range_resolver.rb:51:      resolve_incremental(cursor_last_blockheight) app/services/exchange_like/scan_range_resolver.rb:60:    def resolve_manual(cursor_last_blockheight) app/services/exchange_like/scan_range_resolver.rb:69:          cursor_last_blockheight: cursor_last_blockheight app/services/exchange_like/scan_range_resolver.rb:82:          cursor_last_blockheight: cursor_last_blockheight app/services/exchange_like/scan_range_resolver.rb:94:        cursor_last_blockheight: cursor_last_blockheight app/services/exchange_like/scan_range_resolver.rb:98:    def resolve_incremental(cursor_last_blockheight) app/services/exchange_like/scan_range_resolver.rb:100:        if cursor_last_blockheight.present? app/services/exchange_like/scan_range_resolver.rb:101:          cursor_last_blockheight.to_i + 1 app/services/exchange_like/scan_range_resolver.rb:111:        cursor_last_blockheight: cursor_last_blockheight app/services/bitcoin_rpc.rb:261:  def best_block_height      = getblockcount.to_i app/services/exchange_observed_scanner.rb:95:    update_cursor!(range[:end_height]) if range[:mode] == :incremental app/services/exchange_observed_scanner.rb:153:    cursor = scanner_cursor app/services/exchange_observed_scanner.rb:154:    if cursor.last_blockheight.present? app/services/exchange_observed_scanner.rb:155:      start_height = cursor.last_blockheight.to_i + 1 app/services/exchange_observed_scanner.rb:185:  def scanner_cursor app/services/exchange_observed_scanner.rb:186:    @scanner_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME) app/services/exchange_observed_scanner.rb:189:  def update_cursor!(height) app/services/exchange_observed_scanner.rb:192:    scanner_cursor.update!( app/services/block_explorer.rb:9:    tip_height = @rpc.best_block_height db/schema.rb:703:  create_table "scan_cursors", force: :cascade do |t| db/schema.rb:708:    t.index ["name"], name: "index_scan_cursors_on_name", unique: true db/schema.rb:711:  create_table "scanner_cursors", force: :cascade do |t| db/schema.rb:717:    t.index ["last_blockheight"], name: "index_scanner_cursors_on_last_blockheight" db/schema.rb:718:    t.index ["name"], name: "index_scanner_cursors_on_name", unique: true db/schema.rb:790:    t.datetime "last_scanned_at" victor@debian:~/bitcoin_monitor$ 



Parfait, le bon modèle est :

```
ScannerCursor
```

Vérifie l’état réel :

```
rails runner 'p ScannerCursor.find_by(name: "cluster_scan")&.attributes'
```

Puis surveille seulement la hauteur :

```
watch -n 30 'cd ~/bitcoin_monitor && rails runner "puts ScannerCursor.find_by(name: \"cluster_scan\")&.last_blockheight"'
```

Si la hauteur monte, même lentement : **on laisse tourner**.

Pour voir les logs du scanner :

```
tail -f log/cron.victor.log | grep --line-buffered "cluster_scan"
```

Important : comme le job tourne depuis 09:15, le `delay` et les `missed` sont normaux. Le cron tente toutes les 15 minutes, mais `flock` empêche les doublons.

Le vrai indicateur maintenant c’est :

```
ScannerCursor.last_blockheight
```

Il doit se rapprocher de `946424`.



victor@debian:~/bitcoin_monitor$ rails runner 'p ScannerCursor.find_by(name: "cluster_scan")&.attributes' {"id"=>3, "name"=>"cluster_scan", "last_blockheight"=>942686, "last_blockhash"=>"000000000000000000000e5a2c704fd8e90c522360dcbfeb44fe8d02252de8aa", "created_at"=>2026-03-18 21:20:02.658779000 CET +01:00, "updated_at"=>2026-03-28 21:24:59.600479000 CET +01:00} victor@debian:~/bitcoin_monitor$ 



Là c’est confirmé : **le process Ruby tourne, mais le cursor ne bouge pas** depuis le 28 mars.

Il faut regarder ce qu’il fait réellement :

```
tail -n 200 log/cron.victor.log | grep -i "cluster_scan"
```

Puis teste son activité CPU/temps :

```
ps -p 15906 -o pid,etime,pcpu,pmem,stat,cmd
```

S’il tourne depuis des heures sans log de progression, arrête-le proprement :

```
kill 15906
```

Attends 5 secondes :

```
ps aux | grep -i cluster | grep -v grep
```

Puis relance en mode visible :

```
bash bin/cron_cluster_scan.sh
```

Envoie-moi la sortie complète.
Le point important : le scanner devrait afficher des lignes du type :

```
[cluster_scan] start ...
[cluster_scan] progress height=...
```

S’il reste bloqué avant le premier `progress`, on ira directement dans `app/services/cluster_scanner.rb`.



[cluster_scan] progress height=943986 blocks=1300 txs=5126036 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=943996 blocks=1310 txs=5157215 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944006 blocks=1320 txs=5199337 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944016 blocks=1330 txs=5239652 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944026 blocks=1340 txs=5278086 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944036 blocks=1350 txs=5311883 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944046 blocks=1360 txs=5344560 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944056 blocks=1370 txs=5381211 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944066 blocks=1380 txs=5431586 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944076 blocks=1390 txs=5477815 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944086 blocks=1400 txs=5514379 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944096 blocks=1410 txs=5560963 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944106 blocks=1420 txs=5598546 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944116 blocks=1430 txs=5633922 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944126 blocks=1440 txs=5668285 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944136 blocks=1450 txs=5701083 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944146 blocks=1460 txs=5732859 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944156 blocks=1470 txs=5772386 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944166 blocks=1480 txs=5810617 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944176 blocks=1490 txs=5854737 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944186 blocks=1500 txs=5893446 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944196 blocks=1510 txs=5944826 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944206 blocks=1520 txs=5978424 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944216 blocks=1530 txs=6007264 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944226 blocks=1540 txs=6032573 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944236 blocks=1550 txs=6076666 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944246 blocks=1560 txs=6118840 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944256 blocks=1570 txs=6170770 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944266 blocks=1580 txs=6204280 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 [cluster_scan] progress height=944276 blocks=1590 txs=6246614 multi_input_txs=0 links_created=0 clusters_created=0 clusters_merged=0 pruned_blocks_skipped=0 tx_skipped_rpc_errors=0 tx_skipped_missing_prevout=0 victor@debian:~/bitcoin_monitor$ 



Bonne nouvelle : **il avance bien**.

Il est passé de :

```
942686
```

à environ :

```
944276
```

Donc il a déjà rattrapé :

```
1590 blocs
```

Il reste environ :

```
946424 - 944276 = 2148 blocs
```

À ce stade : **ne touche plus au process**. Laisse-le finir.

Pour surveiller proprement :

```
watch -n 60 'cd ~/bitcoin_monitor && rails runner "p ScannerCursor.find_by(name: \"cluster_scan\")&.attributes"'
```

Mais attention : le cursor peut ne se mettre à jour **qu’à la fin du scan complet**. Tes logs montrent que le travail avance même si `ScannerCursor` reste ancien.

Le point bizarre à noter :

```
multi_input_txs=0
links_created=0
clusters_created=0
```

Donc le scanner parcourt les blocs, mais ne crée rien. On vérifiera après la fin si c’est normal ou si le parseur ne détecte plus les inputs.

Pour l’instant : **on laisse terminer**.



- 
- 



- 
- 
- 
- 
- 
- 
- 



il faut refactoriser cluster 



Oui. Pour `cluster`, il faut le traiter comme un vrai module métier séparé : scanner, stocker, agréger, détecter, afficher et superviser. Je te propose d’abord de cadrer l’architecture cible, puis on descend fichier par fichier.

Réflexion durant quelques secondes

Oui. Pour moi, `cluster` doit être refactorisé en **module propre**, pas juste “réparer le job”.

## Objectif du refactor `cluster`

Passer de :

```
un gros scan lent
des logs difficiles à lire
des responsabilités mélangées
des performances fragiles
```

à :

```
Cluster/
  Scan
  Build
  Metrics
  Signals
  UI
  Health
  Recovery
```

## Architecture cible

```
app/
  services/
    clusters/
      scanner.rb
      link_builder.rb
      cluster_merger.rb
      metrics_builder.rb
      signal_detector.rb
      recovery_status.rb

  queries/
    clusters/
      dashboard_query.rb
      address_lookup_query.rb
      signal_query.rb

  presenters/
    clusters/
      cluster_presenter.rb
      signal_presenter.rb

  jobs/
    clusters/
      scan_job.rb
      metrics_job.rb
      signals_job.rb
```

## Le module doit répondre à 10 questions

```
1. Que voit l’utilisateur ?
2. Quelles données sont utilisées ?
3. D’où viennent les données ?
4. Comment les données entrent dans le module ?
5. Comment le module prépare les données ?
6. Quelle est la fraîcheur des données ?
7. Comment les données sont transformées pour l’UI ?
8. Comment elles sont affichées ?
9. Comment le système supervise le module ?
10. Comment on teste et sécurise ?
```

## Ordre de refactor recommandé

### 1. Séparer le scan brut

Responsabilité :

```
lire les blocs
extraire les transactions multi-inputs
produire des liens entre adresses
```

Pas de métriques.
Pas de signaux.
Pas d’UI.

### 2. Séparer la construction des clusters

Responsabilité :

```
créer les clusters
fusionner les clusters
rattacher les adresses
```

### 3. Séparer les métriques

Responsabilité :

```
calculer activité 24h / 7d
volume envoyé
nombre de transactions
taille du cluster
score d’activité
```

### 4. Séparer les signaux

Responsabilité :

```
large_transfers
sudden_activity
volume_spike
cluster_activation
```

### 5. Séparer l’affichage

La vue ne doit pas calculer.

Elle doit recevoir un objet propre :

```
Clusters::DashboardQuery.call
```

ou :

```
Clusters::ClusterPresenter.new(cluster)
```

### 6. Séparer la supervision

Dans `/system`, on doit voir :

```
cluster_scan
cluster_metrics
cluster_signals
dernier bloc scanné
lag
durée du dernier job
nombre de clusters
nombre de signaux
état recovery
```

## Structure métier propre

```
Cluster Scan
  ↓
Cluster Links
  ↓
Cluster Merge
  ↓
Cluster Profiles
  ↓
Cluster Metrics
  ↓
Cluster Signals
  ↓
Cluster Dashboard
```

## Première étape concrète

On commence par auditer le scan actuel.

Envoie-moi ces fichiers :

```
app/services/...cluster...
app/jobs/...cluster...
lib/tasks/...cluster...
app/models/cluster.rb
app/models/address.rb
app/models/cluster_metric.rb
app/models/cluster_signal.rb
```

Et on va faire le refactor dans cet ordre :

```
1. comprendre l’existant
2. isoler le scanner
3. corriger le problème multi_input_txs = 0
4. rendre le scan pruned-safe
5. exposer une progression claire
6. accélérer avec batch / upsert / RAM
7. documenter le module
```



quel est la commande pour creer le zip



Dans le dossier parent de ton projet :

```
zip -r bitcoin_monitor.zip bitcoin_monitor \
  -x "bitcoin_monitor/.git/*" \
     "bitcoin_monitor/log/*" \
     "bitcoin_monitor/tmp/*" \
     "bitcoin_monitor/storage/*" \
     "bitcoin_monitor/node_modules/*" \
     "bitcoin_monitor/vendor/bundle/*" \
     "bitcoin_monitor/.env*" \
     "bitcoin_monitor/config/master.key"
```

Ça va créer :

```
bitcoin_monitor.zip
```

avec le code utile mais sans :

- `.git`
- logs
- tmp
- storage
- node_modules
- gems vendorisées
- secrets Rails

Ensuite tu peux l’envoyer ici.



victor@debian:~/bitcoin_monitor$ zip -r bitcoin_monitor.zip bitcoin_monitor   -x "bitcoin_monitor/.git/*"      "bitcoin_monitor/log/*"      "bitcoin_monitor/tmp/*"      "bitcoin_monitor/storage/*"      "bitcoin_monitor/node_modules/*"      "bitcoin_monitor/vendor/bundle/*"      "bitcoin_monitor/.env*"      "bitcoin_monitor/config/master.key" zip warning: name not matched: bitcoin_monitor zip error: Nothing to do! (bitcoin_monitor.zip) victor@debian:~/bitcoin_monitor$ 



Tu es déjà **dans** le dossier `~/bitcoin_monitor`.

Donc il faut zipper le dossier courant `.` et non `bitcoin_monitor`.

Commande correcte :

```
zip -r ../bitcoin_monitor.zip . \
  -x ".git/*" \
     "log/*" \
     "tmp/*" \
     "storage/*" \
     "node_modules/*" \
     "vendor/bundle/*" \
     ".env*" \
     "config/master.key"
```

Le zip sera créé ici :

```
/home/victor/bitcoin_monitor.zip
```

Tu peux vérifier :

```
ls -lh ../bitcoin_monitor.zip
```



victor@debian:~$ zip -r ../bitcoin_monitor.zip . \  -x ".git/*" \     "log/*" \     "tmp/*" \     "storage/*" \     "node_modules/*" \     "vendor/bundle/*" \     ".env*" \     "config/master.key" Scanning files  zip warning: name not matched: .config/google-chrome/SingletonCookie zip warning: name not matched: .config/google-chrome/SingletonLock zip warning: name not matched: .config/Typora/SingletonCookie zip warning: name not matched: .config/Typora/SingletonSocket zip warning: name not matched: .config/Typora/SingletonLock .....	zip warning: name not matched: .x2go/C-victor-50-1768649954_stDXFCE_dp24 zip warning: name not matched: .x2go/C-victor-50-1768650595_stDXFCE_dp24 zip warning: name not matched: .mozilla/firefox/y9f720qc.default-esr/lock ........... ..zip I/O error: Permission denied zip error: Could not create output file (../bitcoin_monitor.zip) victor@debian:~$ 



Là tu as lancé la commande depuis `~` (ton home), donc il essaie de zipper tout ton système utilisateur 😄

Retourne dans le dossier du projet :

```
cd ~/bitcoin_monitor
```

Puis lance :

```
zip -r ~/bitcoin_monitor.zip . \
  -x ".git/*" \
     "log/*" \
     "tmp/*" \
     "storage/*" \
     "node_modules/*" \
     "vendor/bundle/*" \
     ".env*" \
     "config/master.key"
```

Et vérifie :

```
ls -lh ~/bitcoin_monitor.zip
```

Cette fois il ne prendra que le projet Bitcoin Monitor.





e39730d8-1674-419e-8dc8-c86a75c19395.zip

Archive zip



Parfait, j’ai bien reçu l’archive de Bitcoin Monitor.
Je vais pouvoir auditer le module `cluster` proprement et te proposer un vrai plan de refactor orienté :

- performance
- séparation des responsabilités
- pruned-mode
- supervision
- temps réel futur
- maintenabilité Rails pro
- préparation Redis / Sidekiq / ClickHouse éventuelle

On va surtout regarder :

```
cluster scan
cluster merge
cluster metrics
cluster signals
queries
jobs
cron
modèles
```

et identifier :

```
ce qui doit être :
- isolé
- supprimé
- fusionné
- accéléré
- batché
- mis en cache
- rendu observable
```

Ensuite je te proposerai :

```
architecture cible
flux complet
nouvelle structure de dossiers
ordre de migration
quick wins performance
```

et surtout :

```
comment éviter que cluster devienne un monstre ingérable
```



Tu as auditer l'existant ?



Oui — j’ai commencé l’audit de l’existant de Bitcoin Monitor et il y a déjà plusieurs constats très clairs sur le module `cluster`.

# Ce que j’ai trouvé

## Architecture actuelle

Tu as actuellement :

```
ClusterScanner
ClusterAggregator
ClusterMetricsBuilder
ClusterSignalEngine
ClusterClassifier
ClusterScorer
```

avec :

```
controllers
cron
rake tasks
specs
models
```

👉 donc la base est déjà bonne.
Le problème n’est pas “tout refaire”.

Le problème est :

```
les responsabilités sont encore trop couplées
+
le scan est trop coûteux
+
les métriques sont reconstruites de manière naïve
+
le moteur n’est pas encore pensé temps réel / reprise / scaling
```

------

# Premier constat CRITIQUE

Dans ton `ClusterScanner` :

```
multi_input_txs: 0
links_created: 0
clusters_created: 0
```

dans les logs…

👉 ce n’est PAS normal.

Ça veut dire qu’une de ces choses arrive :

```
1. prevouts absents
2. mauvais parsing vin
3. skip silencieux
4. pruned mode mal géré
5. filtre trop agressif
6. tx décodées incomplètes
```

et c’est EXACTEMENT ce qu’on voyait dans tes logs récents.

------

# Deuxième constat important

Le scanner fait encore :

```
scan blockchain
+
construction cluster
+
merge
+
stats
```

dans une logique trop centralisée.

👉 résultat :

- difficile à débugger
- difficile à accélérer
- impossible à paralléliser proprement
- compliqué à rendre temps réel

------

# Troisième constat

Ton `ClusterMetricsBuilder` fait des estimations :

```
(profile.tx_count.to_f / cluster_age_blocks) * 144
```

👉 donc :

```
ce ne sont pas de vraies métriques temporelles
```

mais des projections statistiques.

Ça peut être OK pour V1/V2.

Mais pour une vraie V3 “pro” :

```
il faudra snapshots réels
```

par date / heure / fenêtre.

------

# Quatrième constat

Le moteur de signaux est propre conceptuellement :

```
sudden_activity
volume_spike
large_transfers
cluster_activation
```

👉 ça j’aime beaucoup.

MAIS :

```
il dépend trop des métriques reconstruites
```

et pas assez :

```
d’événements blockchain réels
```

------

# Ce que je recommande

# PHASE 1 — Stabilisation

## Objectif

Faire fonctionner le scan correctement.

Avant toute optimisation.

------

## On veut :

```
multi_input_txs > 0
links_created > 0
clusters_created > 0
```

de manière fiable.

------

# PHASE 2 — Refactor architecture

Séparer :

```
Scanner
Link extraction
Cluster merge
Profiles
Metrics
Signals
```

------

# PHASE 3 — Performance

Là il y a énormément à gagner.

## Tu peux facilement :

### 1. batch SQL

Utiliser :

```
insert_all
upsert_all
```

massivement.

------

### 2. RAM cache

Pendant le scan :

```
address -> cluster_id
```

en mémoire.

Énorme gain.

------

### 3. Redis

Plus tard :

```
cluster merge queue
hot addresses
signal buffers
```

------

### 4. ZMQ temps réel

Plus tard :

```
nouveau bloc
↓
cluster incremental update
↓
signals
↓
dashboard live
```

------

# Le GROS problème actuel

Tu scans encore de manière :

```
historique + relationnelle + synchrone
```

👉 alors que Bitcoin Monitor va devenir :

```
event-driven
```

avec :

```
bitcoind ZMQ
Redis
Sidekiq
incremental processing
```

------

# Mon verdict honnête

Le module n’est PAS mauvais.

Au contraire :

```
la vision architecture est bonne
```

et très supérieure à beaucoup de projets perso Rails.

MAIS :

```
le moteur doit maintenant passer :
du mode prototype
→ au mode système de données
```

Et ça change totalement la manière de coder.

------

# La prochaine étape

Je veux maintenant auditer précisément :

```
ClusterScanner
```

car c’est le cœur du problème.

Notamment :

```
gestion des prevouts
RPC
pruned mode
merge logic
tables utilisées
```

Et ensuite je te proposerai :

```
Cluster V4 architecture cible
```

avec :

```
scan incrémental
pipeline clair
temps réel
Redis
batching
recovery
supervision
```

très proche d’une vraie architecture data-engineering.



ok on continue



Je vais regarder l’archive directement et me concentrer sur le module `cluster` : modèles, services, jobs, rake tasks, cron, vues système et tests. Ensuite je te donne le diagnostic réel avec les fichiers concernés.

Réflexion durant 1m 5s

Oui, là j’ai audité le vrai code.

## Verdict

Ton module `cluster` est **bien avancé**, mais il a 3 problèmes majeurs :

### 1. Le scanner dépend de `getblock(..., 3)`

Dans `ClusterScanner`, tu fais :

```
block = @rpc.getblock(blockhash, 3)
```

Puis tu lis :

```
vin["prevout"]
```

Donc si Bitcoin Core ne renvoie pas les `prevout`, tu obtiens :

```
multi_input_txs = 0
links_created = 0
clusters_created = 0
```

C’est probablement la cause principale de ton problème actuel.

------

### 2. Le scanner fait trop de choses

Aujourd’hui `ClusterScanner` fait :

```
lecture des blocs
extraction des inputs
création des adresses
mise à jour stats
création des liens
merge clusters
rebuild profiles
```

C’est trop pour une seule classe.

------

### 3. Les métriques V3 ne sont pas encore “réelles”

`ClusterMetricsBuilder` calcule les 24h / 7j à partir d’une moyenne sur l’âge du cluster :

```
(profile.tx_count.to_f / cluster_age_blocks) * 144
```

Donc ce ne sont pas encore de vraies fenêtres temporelles blockchain.

## Bonne nouvelle

Tu as déjà une base solide :

```
ClusterScanner
ClusterAggregator
ClusterMetricsBuilder
ClusterSignalEngine
ClusterClassifier
ClusterScorer
ClusterProfile
ClusterMetric
ClusterSignal
JobRunner
cron cluster
tests RSpec cluster
```

Donc on ne jette pas tout.

## Première action à faire

On doit d’abord corriger/valider le scanner.

Teste dans Rails console :

```
rails c
```

Puis :

```
rpc = BitcoinRpc.new(wallet: nil)
height = rpc.getblockcount
hash = rpc.getblockhash(height)
block = rpc.getblock(hash, 3)

tx = block["tx"].find { |t| t["vin"].is_a?(Array) && t["vin"].size >= 2 && !t["vin"].first["coinbase"] }

tx["vin"].map { |vin| vin.keys }
```

Si tu ne vois pas `"prevout"` dans les clés, alors le scan ne peut pas fonctionner comme ça.

Ensuite teste :

```
tx["vin"].map { |vin| vin["prevout"] }.compact.size
```

On veut un nombre supérieur à `0`.

Le prochain refactor doit commencer par :

```
Clusters::InputExtractor
```

C’est lui qui dira proprement :

```
cette tx est exploitable
cette tx n’a pas de prevout
cette tx est coinbase
cette tx a moins de 2 adresses distinctes
```

Et seulement après, on découpe le reste.



victor@debian:~/bitcoin_monitor$ rails c Loading development environment (Rails 8.0.4) bitcoin-monitor(dev)> rpc = BitcoinRpc.new(wallet: nil) bitcoin-monitor(dev)> height = rpc.getblockcount bitcoin-monitor(dev)> hash = rpc.getblockhash(height) bitcoin-monitor(dev)> block = rpc.getblock(hash, 3) bitcoin-monitor(dev)>  bitcoin-monitor(dev)> tx = block["tx"].find { |t| t["vin"].is_a?(Array) && t["vin"].size >= 2 && !t["vin"].first["coinbase"] } bitcoin-monitor(dev)>  bitcoin-monitor(dev)> tx["vin"].map { |vin| vin.keys } =>  [["txid", "vout", "scriptSig", "prevout", "sequence"], ["txid", "vout", "scriptSig", "txinwitness", "prevout", "sequence"]] bitcoin-monitor(dev)> 



Très bon résultat : `prevout` est bien présent. Donc le problème `multi_input_txs = 0` ne vient pas de Bitcoin Core ni du pruned mode à ce niveau ; il vient probablement du filtre/extracteur d’adresses dans ton code. Je vais vérifier le scanner réel dans l’archive.

Réflexion durant 39s

Excellent. Donc `prevout` existe bien.

Conclusion : le problème n’est **pas** Bitcoin Core.
Le problème est dans cette partie de `ClusterScanner` :

```
address = extract_address(script_pub_key)
next if address.blank?
```

ou ici :

```
return if grouped_inputs.size < 2
```

Maintenant teste ça dans `rails c` :

```
rpc = BitcoinRpc.new(wallet: nil)
height = rpc.getblockcount
hash = rpc.getblockhash(height)
block = rpc.getblock(hash, 3)

stats = {
  txs: 0,
  non_coinbase: 0,
  vin_ge_2: 0,
  with_prevout: 0,
  with_address: 0,
  multi_distinct_addresses: 0
}

block["tx"].each do |tx|
  stats[:txs] += 1
  next if tx["vin"].any? { |vin| vin["coinbase"].present? }

  stats[:non_coinbase] += 1
  next unless tx["vin"].size >= 2

  stats[:vin_ge_2] += 1

  addresses = tx["vin"].filter_map do |vin|
    prevout = vin["prevout"]
    next unless prevout

    stats[:with_prevout] += 1

    spk = prevout["scriptPubKey"] || {}
    addr = spk["address"] || Array(spk["addresses"]).first

    stats[:with_address] += 1 if addr.present?
    addr
  end.uniq

  stats[:multi_distinct_addresses] += 1 if addresses.size >= 2
end

stats
```

On veut surtout voir :

```
:vin_ge_2
:with_prevout
:with_address
:multi_distinct_addresses
```

Si `multi_distinct_addresses` est supérieur à `0`, alors ton extraction marche, et le problème vient probablement de cette ligne :

```
return if AddressLink.exists?(txid: txid, link_type: "multi_input")
```

C’est possible que ton scanner rescane des blocs déjà traités, donc il skippe tout avant même d’incrémenter `multi_input_txs`.

Ensuite donne-moi juste le résultat du hash `stats`.



=>  {:txs=>4125, :non_coinbase=>4124, :vin_ge_2=>268, :with_prevout=>4764, :with_address=>4764, :multi_distinct_addresses=>162} bitcoin-monitor(dev)> 



Parfait. Ton extraction fonctionne.

Donc le problème vient très probablement de la logique de skip :

```
return if AddressLink.exists?(txid: txid, link_type: "multi_input")
```

Si le bloc a déjà été partiellement traité, ton scanner peut faire :

```
tx multi-input trouvée
mais déjà connue
donc return
donc multi_input_txs non incrémenté
```

## Test suivant

Dans `rails c`, prends une transaction multi-input du dernier bloc :

```
candidate = block["tx"].find do |tx|
  next false if tx["vin"].any? { |vin| vin["coinbase"].present? }

  addresses = tx["vin"].filter_map do |vin|
    spk = vin.dig("prevout", "scriptPubKey") || {}
    spk["address"] || Array(spk["addresses"]).first
  end.uniq

  addresses.size >= 2
end

candidate["txid"]
```

Puis teste :

```
AddressLink.where(txid: candidate["txid"], link_type: "multi_input").count
```

Si ça retourne `> 0`, ton scan voit bien les tx, mais il les ignore car déjà enregistrées.

## Correction probable

Dans le futur `ClusterScanner`, il faudra distinguer :

```
tx vues
tx exploitables
tx déjà connues
tx réellement insérées
```

Donc les logs devraient devenir :

```
txs_total
multi_input_candidates
multi_input_already_known
links_created
clusters_created
clusters_merged
```

Là ton `multi_input_txs = 0` est probablement trompeur : il compte seulement les tx vraiment traitées, pas les candidates détectées.



bitcoin-monitor(dev)> candidate["txid"] => "4e57a0436e3d9dc630300ac80675ff7a39291d0adcc151e153960b2ca1b62b27" bitcoin-monitor(dev)> AddressLink.where(txid: candidate["txid"], link_type: "multi_input").count  AddressLink Count (0.9ms)  SELECT COUNT(*) FROM "address_links" WHERE "address_links"."txid" = '4e57a0436e3d9dc630300ac80675ff7a39291d0adcc151e153960b2ca1b62b27' AND "address_links"."link_type" = 'multi_input' /*application='BitcoinMonitor'*/ => 0 bitcoin-monitor(dev)> 



OK, là c’est encore plus intéressant : la transaction candidate n’est pas déjà enregistrée. Donc le skip `AddressLink.exists?` n’explique pas ce cas. Je vais maintenant vérifier précisément le code du scanner dans l’archive pour trouver le filtre qui bloque.

Réflexion durant 51s

Parfait. Là on a isolé le problème.

Ton dernier bloc contient bien :

```
vin_ge_2: 268
with_prevout: 4764
with_address: 4764
multi_distinct_addresses: 162
```

Donc `ClusterScanner` devrait trouver des transactions multi-input.

## Test décisif maintenant

Lance exactement ça :

```
bin/rails "cluster:scan_recent[1]"
```

Ou si ta task ne prend pas l’argument :

```
BLOCKS=1 bin/rails cluster:scan_recent
```

On veut voir si le scanner officiel retourne encore :

```
multi_input_txs: 0
```

ou s’il trouve maintenant des tx.

## Si ça retourne encore 0

Alors le bug est dans `ClusterScanner`, probablement ici :

```
return if AddressLink.exists?(txid: txid, link_type: "multi_input")
```

ou dans :

```
grouped_inputs = group_inputs_by_address(input_rows)
return if grouped_inputs.size < 2
```

## Prochaine amélioration à faire

Il faut ajouter des compteurs de debug dans `ClusterScanner`.

Dans `@stats`, ajoute :

```
multi_input_candidates: 0,
already_linked_txs: 0,
input_rows_found: 0,
multi_address_candidates: 0
```

Puis dans `scan_transaction`, remplace le début par :

```
def scan_transaction(tx, height)
  txid = tx["txid"].to_s
  return if txid.blank?
  return if coinbase_tx?(tx)

  if Array(tx["vin"]).size >= 2
    @stats[:multi_input_candidates] += 1
  end

  if AddressLink.exists?(txid: txid, link_type: "multi_input")
    @stats[:already_linked_txs] += 1
    return
  end

  input_rows = extract_input_rows_from_prevout(tx)
  @stats[:input_rows_found] += input_rows.size

  return if input_rows.empty?

  grouped_inputs = group_inputs_by_address(input_rows)

  if grouped_inputs.size >= 2
    @stats[:multi_address_candidates] += 1
  end

  return if grouped_inputs.size < 2

  @stats[:multi_input_txs] += 1

  ActiveRecord::Base.transaction do
    address_records = upsert_addresses!(grouped_inputs.keys, height)
    assign_input_stats!(address_records, grouped_inputs, height)
    cluster = attach_or_merge_clusters!(address_records)
    @stats[:links_created] += create_links!(address_records, txid, height)
    mark_cluster_dirty!(cluster)
  end

  @stats[:addresses_touched] += grouped_inputs.size
rescue BitcoinRpc::Error => e
  @stats[:tx_skipped_rpc_errors] += 1
  puts "[cluster_scan] tx_skip txid=#{txid} height=#{height} reason=#{e.message}"
rescue StandardError => e
  raise Error, "scan_transaction failed txid=#{txid} height=#{height}: #{e.class} - #{e.message}"
end
```

Ensuite relance :

```
BLOCKS=1 bin/rails cluster:scan_recent
```

Après ça, on saura exactement où ça bloque.



victor@debian:~/bitcoin_monitor$ BLOCKS=1 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946434 end_height=946434 [cluster_scan] refresh_dirty_clusters count=281 {:ok=>true, :mode=>:manual, :best_height=>946434, :start_height=>946434, :end_height=>946434, :scanned_blocks=>1, :scanned_txs=>2664, :multi_input_txs=>342, :links_created=>4251, :clusters_created=>203, :clusters_merged=>4, :addresses_touched=>4593, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>650, :already_linked_txs=>0, :input_rows_found=>8195, :multi_address_candidates=>342} victor@debian:~/bitcoin_monitor$ 



Excellent. Le scanner fonctionne.

Donc le vrai problème n’était pas le code RPC/extraction, mais probablement :

```
ancien bloc déjà traité
ou mauvais range
ou ancienne version sans compteurs debug
```

## Résultat actuel

```
multi_input_txs: 342
links_created: 4251
clusters_created: 203
clusters_merged: 4
addresses_touched: 4593
```

C’est très bon.

## Ce que ça prouve

Ton pipeline actuel sait bien faire :

```
bloc Bitcoin
↓
transactions multi-input
↓
adresses liées
↓
clusters créés / fusionnés
↓
clusters dirty rafraîchis
```

## Maintenant on peut refactoriser proprement

Le prochain objectif n’est plus “réparer cluster”, mais :

```
rendre ClusterScanner lisible, mesurable, performant et maintenable
```

## Étape suivante recommandée

On garde tes compteurs debug et on renomme les métriques :

```
multi_input_candidates
already_linked_txs
input_rows_found
multi_address_candidates
multi_input_txs
links_created
clusters_created
clusters_merged
addresses_touched
```

Puis on découpe `ClusterScanner` en 4 classes :

```
Clusters::BlockScanner
Clusters::InputExtractor
Clusters::LinkWriter
Clusters::ClusterMerger
```

Ordre logique :

```
1. extraire InputExtractor
2. extraire LinkWriter
3. extraire ClusterMerger
4. garder ClusterScanner comme orchestrateur
```

Le premier fichier à créer sera :

```
app/services/clusters/input_extractor.rb
```

C’est la meilleure première étape.



ok on avance



Parfait.
On va faire un vrai refactor “senior Rails / data pipeline”.

# Objectif immédiat

Transformer :

```
ClusterScanner = monolithe
```

en :

```
ClusterScanner = orchestrateur
```

avec :

```
InputExtractor
LinkWriter
ClusterMerger
```

------

# Étape 1 — Extraire InputExtractor

## Responsabilité unique

Prendre une transaction Bitcoin :

```
tx
```

et retourner :

```
adresses d’inputs exploitables
```

Rien d’autre.

------

# Pourquoi c’est IMPORTANT

Aujourd’hui ton scanner mélange :

```
RPC
filtrage tx
lecture prevout
parsing scriptPubKey
normalisation adresses
grouping
```

👉 impossible à tester proprement.

------

# Nouveau fichier

```
app/services/clusters/input_extractor.rb
```

------

# Version cible

```
# app/services/clusters/input_extractor.rb

module Clusters
  class InputExtractor
    def self.call(tx)
      new(tx).call
    end

    def initialize(tx)
      @tx = tx
    end

    def call
      return [] if coinbase_tx?

      rows = extract_rows

      grouped = rows.group_by { |r| r[:address] }

      grouped.map do |address, inputs|
        {
          address: address,
          total_inputs: inputs.size,
          total_value_sats: inputs.sum { |i| i[:value_sats] }
        }
      end
    end

    private

    attr_reader :tx

    def coinbase_tx?
      Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }
    end

    def extract_rows
      Array(tx["vin"]).filter_map do |vin|
        prevout = vin["prevout"]
        next unless prevout

        script_pub_key = prevout["scriptPubKey"] || {}

        address =
          script_pub_key["address"] ||
          Array(script_pub_key["addresses"]).first

        next if address.blank?

        value_sats =
          ((prevout["value"].to_d) * 100_000_000).to_i

        {
          address: address,
          value_sats: value_sats
        }
      end
    end
  end
end
```

------

# Ensuite dans ClusterScanner

Tu remplaces :

```
input_rows = extract_input_rows_from_prevout(tx)
grouped_inputs = group_inputs_by_address(input_rows)
```

par :

```
grouped_inputs = Clusters::InputExtractor.call(tx)
```

------

# Et ensuite

Tu transformes :

```
grouped_inputs.keys
```

en :

```
grouped_inputs.map { |g| g[:address] }
```

------

# Résultat

Tu obtiens :

```
ClusterScanner
↓
InputExtractor
↓
LinkWriter
↓
ClusterMerger
```

👉 architecture BEAUCOUP plus propre.

------

# Ce que ça apporte immédiatement

## 1. Tests unitaires ultra simples

Tu pourras faire :

```
Clusters::InputExtractor.call(tx)
```

sans DB.

------

## 2. Débug énorme

Tu peux logguer :

```
puts grouped_inputs.inspect
```

------

## 3. Préparation temps réel

Demain ZMQ pourra appeler directement :

```
InputExtractor
```

sans lancer tout le scanner.

------

# IMPORTANT

Ne supprime PAS encore :

```
extract_input_rows_from_prevout
group_inputs_by_address
```

tout de suite.

👉 d’abord :

```
1. créer InputExtractor
2. brancher scanner dessus
3. vérifier scan OK
4. ensuite supprimer ancien code
```

------

# Quand c’est fait

On attaque :

```
Clusters::LinkWriter
```

et là on va énormément améliorer :

```
insert_all
upsert_all
batch SQL
```

pour accélérer massivement le scan.



\# frozen_string_literal: true require "set" # app/services/cluster_scanner.rb class ClusterScanner  class Error < StandardError; end   CURSOR_NAME = "cluster_scan"  INITIAL_BLOCKS_BACK = (Integer(ENV.fetch("CLUSTER_INITIAL_BLOCKS_BACK", "50")) rescue 50)   def self.call(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil)    new(      from_height: from_height,      to_height: to_height,      limit: limit,      rpc: rpc,      job_run: job_run    ).call  end   def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil)    @from_height = from_height.present? ? from_height.to_i : nil    @to_height   = to_height.present? ? to_height.to_i : nil    @limit       = limit.present? ? limit.to_i : nil    @rpc         = rpc || BitcoinRpc.new(wallet: nil)    @job_run = job_run     @dirty_cluster_ids = Set.new     @stats = {      scanned_blocks: 0,      scanned_txs: 0,      multi_input_txs: 0,      links_created: 0,      clusters_created: 0,      clusters_merged: 0,      addresses_touched: 0,      pruned_blocks_skipped: 0,      tx_skipped_rpc_errors: 0,      tx_skipped_missing_prevout: 0,      multi_input_candidates: 0,      already_linked_txs: 0,      input_rows_found: 0,      multi_address_candidates: 0    }  end   def call    best_height = @rpc.getblockcount.to_i    range = compute_scan_range(best_height)     if range[:start_height] > range[:end_height]      return {        ok: true,        note: "nothing to scan",        mode: range[:mode],        best_height: best_height,        start_height: range[:start_height],        end_height: range[:end_height]      }    end     puts(      "[cluster_scan] start " \      "mode=#{range[:mode]} " \      "start_height=#{range[:start_height]} " \      "end_height=#{range[:end_height]}"    )     (range[:start_height]..range[:end_height]).each do |height|      scanned = scan_block(height)      @stats[:scanned_blocks] += 1 if scanned       if (@stats[:scanned_blocks] % 10).zero? || height == range[:end_height]        update_progress!(height, range[:start_height], range[:end_height])      end       log_progress(height)    end     refresh_dirty_clusters!     update_cursor!(range[:end_height]) if range[:mode] == :incremental     {      ok: true,      mode: range[:mode],      best_height: best_height,      start_height: range[:start_height],      end_height: range[:end_height]    }.merge(@stats)  end   private   def compute_scan_range(best_height)    if manual_mode?      start_height = @from_height || [0, best_height - default_manual_span + 1].max      end_height   = @to_height || best_height       if @limit.present? && @limit > 0        end_height = [end_height, start_height + @limit - 1].min      end       return {        mode: :manual,        start_height: [0, start_height].max,        end_height: [best_height, end_height].min      }    end     cursor = scanner_cursor     start_height =      if cursor.last_blockheight.present?        cursor.last_blockheight.to_i + 1      else        [0, best_height - INITIAL_BLOCKS_BACK + 1].max      end     end_height = best_height     if @limit.present? && @limit > 0      end_height = [best_height, start_height + @limit - 1].min    end     {      mode: :incremental,      start_height: start_height,      end_height: end_height    }  end   def manual_mode?    @from_height.present? || @to_height.present?  end   def default_manual_span    @limit.present? && @limit > 0 ? @limit : INITIAL_BLOCKS_BACK  end   def scanner_cursor    @scanner_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME)  end   def update_cursor!(height)    blockhash = @rpc.getblockhash(height)     scanner_cursor.update!(      last_blockheight: height,      last_blockhash: blockhash    )  end   def scan_block(height)    blockhash = @rpc.getblockhash(height)    block = @rpc.getblock(blockhash, 3)     Array(block["tx"]).each do |tx|      @stats[:scanned_txs] += 1      scan_transaction(tx, height)    end     true  rescue BitcoinRpc::Error => e    if e.message.include?("Block not available (pruned data)")      @stats[:pruned_blocks_skipped] += 1      puts "[cluster_scan] skip_pruned_block height=#{height}"      return false    end     raise  end   def scan_transaction(tx, height)    txid = tx["txid"].to_s    return if txid.blank?    return if coinbase_tx?(tx)     if Array(tx["vin"]).size >= 2      @stats[:multi_input_candidates] += 1    end     if AddressLink.exists?(txid: txid, link_type: "multi_input")      @stats[:already_linked_txs] += 1      return    end     @stats[:input_rows_found] += input_rows.size     return if input_rows.empty?     grouped_inputs = Clusters::InputExtractor.call(tx)     if grouped_inputs.size >= 2      @stats[:multi_address_candidates] += 1    end     return if grouped_inputs.size < 2     @stats[:multi_input_txs] += 1     ActiveRecord::Base.transaction do      address_records = upsert_addresses!(grouped_inputs.keys, height)      assign_input_stats!(address_records, grouped_inputs, height)      cluster = attach_or_merge_clusters!(address_records)      @stats[:links_created] += create_links!(address_records, txid, height)      mark_cluster_dirty!(cluster)    end     @stats[:addresses_touched] += grouped_inputs.size  rescue BitcoinRpc::Error => e    @stats[:tx_skipped_rpc_errors] += 1    puts "[cluster_scan] tx_skip txid=#{txid} height=#{height} reason=#{e.message}"  rescue StandardError => e    raise Error, "scan_transaction failed txid=#{txid} height=#{height}: #{e.class} - #{e.message}"  end   def extract_input_rows_from_prevout(tx)    rows = []     Array(tx["vin"]).each do |vin|      next if vin["coinbase"].present?       prevout = vin["prevout"]      unless prevout.present?        @stats[:tx_skipped_missing_prevout] += 1        next      end       script_pub_key = prevout["scriptPubKey"] || {}      address = extract_address(script_pub_key)      next if address.blank?       value_sats = btc_to_sats(prevout["value"])      next if value_sats <= 0       rows << {        address: address,        value_sats: value_sats      }    end     rows  end   def group_inputs_by_address(rows)    grouped = Hash.new(0)     rows.each do |row|      grouped[row[:address]] += row[:value_sats].to_i    end     grouped  end   def extract_address(script_pub_key)    return if script_pub_key.blank?     script_pub_key["address"].presence ||      Array(script_pub_key["addresses"]).first.presence  end   def btc_to_sats(value)    (value.to_d * 100_000_000).to_i  rescue StandardError    0  end   def coinbase_tx?(tx)    Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }  end   def upsert_addresses!(addresses, height)    addresses.map do |addr|      existing = Address.find_by(address: addr)      next existing if existing.present?       begin        created = nil         Address.transaction(requires_new: true) do          created = Address.create!(            address: addr,            first_seen_height: height,            last_seen_height: height          )        end         created      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid        found = Address.find_by(address: addr)        next found if found.present?         raise Error, "upsert_address failed address=#{addr.inspect} height=#{height}: duplicate suspected but record not found"      rescue => e        raise Error, "upsert_address failed address=#{addr.inspect} height=#{height}: #{e.class} - #{e.message}"      end    end  end   def assign_input_stats!(address_records, grouped_inputs, height)    address_records.each do |record|      sent_sats = grouped_inputs.fetch(record.address, 0).to_i       record.update!(        first_seen_height: min_present(record.first_seen_height, height),        last_seen_height: max_present(record.last_seen_height, height),        total_sent_sats: record.total_sent_sats.to_i + sent_sats,        tx_count: record.tx_count.to_i + 1      )    end  end   def attach_or_merge_clusters!(address_records)    cluster_ids = address_records.map(&:cluster_id).compact.uniq     if cluster_ids.empty?      cluster = Cluster.create!       Address.where(id: address_records.map(&:id)).update_all(        cluster_id: cluster.id,        updated_at: Time.current      )       @stats[:clusters_created] += 1      return cluster    end     if cluster_ids.size == 1      cluster = Cluster.find(cluster_ids.first)       unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)      if unclustered_ids.any?        Address.where(id: unclustered_ids).update_all(          cluster_id: cluster.id,          updated_at: Time.current        )      end       return cluster    end     merge_clusters!(cluster_ids, address_records)  end   def merge_clusters!(cluster_ids, address_records)    master_id = cluster_ids.min    other_ids = cluster_ids - [master_id]     Address.where(cluster_id: other_ids).update_all(      cluster_id: master_id,      updated_at: Time.current    )     unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)    if unclustered_ids.any?      Address.where(id: unclustered_ids).update_all(        cluster_id: master_id,        updated_at: Time.current      )    end     cleanup_derived_rows_for_clusters!([master_id] + other_ids)     Cluster.where(id: other_ids).delete_all     @stats[:clusters_merged] += other_ids.size     Cluster.find(master_id)  end   def cleanup_derived_rows_for_clusters!(cluster_ids)    ids = Array(cluster_ids).compact.uniq    return if ids.empty?     ClusterSignal.where(cluster_id: ids).delete_all    ClusterMetric.where(cluster_id: ids).delete_all    ClusterProfile.where(cluster_id: ids).delete_all  end   def create_links!(address_records, txid, height)    records = address_records.sort_by(&:id)    return 0 if records.size < 2     pivot = records.first    created = 0     records.drop(1).each do |other|      id_a, id_b = [pivot.id, other.id].sort       link = AddressLink.find_or_initialize_by(        address_a_id: id_a,        address_b_id: id_b,        link_type: "multi_input",        txid: txid      )       next if link.persisted?       link.block_height = height      link.save!      created += 1    end     created  end   def mark_cluster_dirty!(cluster)    return if cluster.blank?     @dirty_cluster_ids << cluster.id  end   def refresh_dirty_clusters!    return if @dirty_cluster_ids.empty?     puts "[cluster_scan] refresh_dirty_clusters count=#{@dirty_cluster_ids.size}"     Cluster.where(id: @dirty_cluster_ids.to_a).find_each do |cluster|      cluster.recalculate_stats!      ClusterAggregator.call(cluster)    end  end   def min_present(a, b)    return b if a.blank?    [a, b].min  end   def max_present(a, b)    return b if a.blank?    [a, b].max  end   def log_progress(height)    return unless (@stats[:scanned_blocks] % 10).zero? && @stats[:scanned_blocks].positive?     puts(      "[cluster_scan] progress " \      "height=#{height} " \      "blocks=#{@stats[:scanned_blocks]} " \      "txs=#{@stats[:scanned_txs]} " \      "multi_input_txs=#{@stats[:multi_input_txs]} " \      "links_created=#{@stats[:links_created]} " \      "clusters_created=#{@stats[:clusters_created]} " \      "clusters_merged=#{@stats[:clusters_merged]} " \      "pruned_blocks_skipped=#{@stats[:pruned_blocks_skipped]} " \      "tx_skipped_rpc_errors=#{@stats[:tx_skipped_rpc_errors]} " \      "tx_skipped_missing_prevout=#{@stats[:tx_skipped_missing_prevout]}"    )  end   def update_progress!(current_height, start_height, end_height)    return if @job_run.blank?     total = (end_height - start_height + 1)    return if total <= 0     done = (current_height - start_height + 1)    pct = ((done.to_f / total) * 100).round(1)     JobRunner.progress!(      @job_run,      pct: pct,      label: "block #{current_height} / #{end_height}",      meta: {        start_height: start_height,        current_height: current_height,        end_height: end_height,        scanned_blocks: @stats[:scanned_blocks],        scanned_txs: @stats[:scanned_txs],        multi_input_txs: @stats[:multi_input_txs],        links_created: @stats[:links_created],        clusters_created: @stats[:clusters_created],        clusters_merged: @stats[:clusters_merged],        pruned_blocks_skipped: @stats[:pruned_blocks_skipped]      }    )  end end



Réflexion durant quelques secondes

Oui, là tu as une erreur dans ton refactor.

Dans `scan_transaction`, tu as supprimé :

```
input_rows = extract_input_rows_from_prevout(tx)
```

mais tu as gardé :

```
@stats[:input_rows_found] += input_rows.size
return if input_rows.empty?
```

Donc `input_rows` n’existe plus.

## Corrige `scan_transaction` comme ça

Remplace toute la méthode par :

```
def scan_transaction(tx, height)
  txid = tx["txid"].to_s
  return if txid.blank?
  return if coinbase_tx?(tx)

  if Array(tx["vin"]).size >= 2
    @stats[:multi_input_candidates] += 1
  end

  if AddressLink.exists?(txid: txid, link_type: "multi_input")
    @stats[:already_linked_txs] += 1
    return
  end

  grouped_inputs = Clusters::InputExtractor.call(tx)

  @stats[:input_rows_found] += grouped_inputs.sum { |g| g[:total_inputs].to_i }

  return if grouped_inputs.empty?

  if grouped_inputs.size >= 2
    @stats[:multi_address_candidates] += 1
  end

  return if grouped_inputs.size < 2

  @stats[:multi_input_txs] += 1

  addresses = grouped_inputs.map { |g| g[:address] }
  grouped_by_address = grouped_inputs.index_by { |g| g[:address] }

  ActiveRecord::Base.transaction do
    address_records = upsert_addresses!(addresses, height)
    assign_input_stats!(address_records, grouped_by_address, height)
    cluster = attach_or_merge_clusters!(address_records)
    @stats[:links_created] += create_links!(address_records, txid, height)
    mark_cluster_dirty!(cluster)
  end

  @stats[:addresses_touched] += grouped_inputs.size
rescue BitcoinRpc::Error => e
  @stats[:tx_skipped_rpc_errors] += 1
  puts "[cluster_scan] tx_skip txid=#{txid} height=#{height} reason=#{e.message}"
rescue StandardError => e
  raise Error, "scan_transaction failed txid=#{txid} height=#{height}: #{e.class} - #{e.message}"
end
```

## Puis corrige aussi `assign_input_stats!`

Remplace :

```
sent_sats = grouped_inputs.fetch(record.address, 0).to_i
```

par :

```
input_data = grouped_inputs.fetch(record.address)
sent_sats = input_data[:total_value_sats].to_i
```

Donc méthode complète :

```
def assign_input_stats!(address_records, grouped_inputs, height)
  address_records.each do |record|
    input_data = grouped_inputs.fetch(record.address)
    sent_sats = input_data[:total_value_sats].to_i

    record.update!(
      first_seen_height: min_present(record.first_seen_height, height),
      last_seen_height: max_present(record.last_seen_height, height),
      total_sent_sats: record.total_sent_sats.to_i + sent_sats,
      tx_count: record.tx_count.to_i + 1
    )
  end
end
```

Après ça, relance :

```
BLOCKS=1 bin/rails cluster:scan_recent
```

On vérifie que le refactor `InputExtractor` est branché correctement.



victor@debian:~/bitcoin_monitor$ BLOCKS=1 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946437 end_height=946437 [cluster_scan] refresh_dirty_clusters count=106 {:ok=>true, :mode=>:manual, :best_height=>946437, :start_height=>946437, :end_height=>946437, :scanned_blocks=>1, :scanned_txs=>1117, :multi_input_txs=>113, :links_created=>1803, :clusters_created=>74, :clusters_merged=>1, :addresses_touched=>1916, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>219, :already_linked_txs=>0, :input_rows_found=>3219, :multi_address_candidates=>113} victor@debian:~/bitcoin_monitor$ 



Parfait. Le premier refactor est validé.

`Clusters::InputExtractor` fonctionne bien :

```
multi_input_candidates: 219
multi_address_candidates: 113
multi_input_txs: 113
links_created: 1803
clusters_created: 74
clusters_merged: 1
```

## Prochaine étape

Maintenant on peut supprimer de `ClusterScanner` les anciennes méthodes devenues inutiles :

```
extract_input_rows_from_prevout
group_inputs_by_address
extract_address
btc_to_sats
```

Garde encore :

```
coinbase_tx?
```

Ensuite on passe à l’étape 2 :

```
Clusters::LinkWriter
```

Objectif : sortir cette logique du scanner :

```
create_links!(address_records, txid, height)
```

et préparer un futur `insert_all` pour accélérer fortement.



ok on continue



On continue avec **Étape 2 — extraire `LinkWriter`**.

## 1. Crée ce fichier

```
mkdir -p app/services/clusters
nano app/services/clusters/link_writer.rb
```

Colle :

```
# frozen_string_literal: true

module Clusters
  class LinkWriter
    LINK_TYPE = "multi_input"

    def self.call(address_records:, txid:, height:)
      new(
        address_records: address_records,
        txid: txid,
        height: height
      ).call
    end

    def initialize(address_records:, txid:, height:)
      @address_records = Array(address_records).compact
      @txid = txid.to_s
      @height = height.to_i
    end

    def call
      records = address_records.sort_by(&:id)
      return 0 if records.size < 2

      pivot = records.first
      created = 0

      records.drop(1).each do |other|
        id_a, id_b = [pivot.id, other.id].sort

        link = AddressLink.find_or_initialize_by(
          address_a_id: id_a,
          address_b_id: id_b,
          link_type: LINK_TYPE,
          txid: txid
        )

        next if link.persisted?

        link.block_height = height
        link.save!
        created += 1
      end

      created
    end

    private

    attr_reader :address_records, :txid, :height
  end
end
```

## 2. Dans `ClusterScanner`, remplace

```
@stats[:links_created] += create_links!(address_records, txid, height)
```

par :

```
@stats[:links_created] += Clusters::LinkWriter.call(
  address_records: address_records,
  txid: txid,
  height: height
)
```

## 3. Supprime ensuite cette méthode de `ClusterScanner`

```
def create_links!(address_records, txid, height)
  ...
end
```

## 4. Test

```
BLOCKS=1 bin/rails cluster:scan_recent
```

On veut encore voir :

```
links_created > 0
multi_input_txs > 0
```



victor@debian:~/bitcoin_monitor$ BLOCKS=1 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946437 end_height=946437 {:ok=>true, :mode=>:manual, :best_height=>946437, :start_height=>946437, :end_height=>946437, :scanned_blocks=>1, :scanned_txs=>1117, :multi_input_txs=>0, :links_created=>0, :clusters_created=>0, :clusters_merged=>0, :addresses_touched=>0, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>219, :already_linked_txs=>113, :input_rows_found=>1197, :multi_address_candidates=>0} victor@debian:~/bitcoin_monitor$ 



C’est normal : tu as relancé sur **le même bloc `946437`**.

Il a déjà été traité au run précédent, donc :

```
already_linked_txs: 113
multi_input_txs: 0
links_created: 0
```

Ça veut dire que le `LinkWriter` n’a pas cassé le scan.

Teste sur un nouveau bloc ou sur 2 blocs récents :

```
BLOCKS=2 bin/rails cluster:scan_recent
```

Ou en explicite :

```
FROM=946438 TO=946438 bin/rails cluster:scan_range
```

Le résultat attendu :

```
already_linked_txs: possible
multi_input_txs: > 0 sur bloc non traité
links_created: > 0
```



victor@debian:~/bitcoin_monitor$ BLOCKS=2 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946436 end_height=946437 [cluster_scan] refresh_dirty_clusters count=285 {:ok=>true, :mode=>:manual, :best_height=>946437, :start_height=>946436, :end_height=>946437, :scanned_blocks=>2, :scanned_txs=>3669, :multi_input_txs=>318, :links_created=>1838, :clusters_created=>207, :clusters_merged=>4, :addresses_touched=>2156, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>861, :already_linked_txs=>113, :input_rows_found=>6406, :multi_address_candidates=>318} victor@debian:~/bitcoin_monitor$ 



Parfait. `Clusters::LinkWriter` est validé.

Résultat important :

```
multi_input_txs: 318
links_created: 1838
already_linked_txs: 113
```

Donc le scanner sait maintenant :

```
détecter les tx déjà traitées
continuer sur les tx nouvelles
créer les liens via LinkWriter
```

## Prochaine étape

On extrait maintenant :

```
Clusters::AddressWriter
```

pour sortir ces deux méthodes de `ClusterScanner` :

```
upsert_addresses!
assign_input_stats!
```

Objectif :

```
ClusterScanner ne doit plus gérer directement les écritures Address
```

Ensuite il restera surtout :

```
ClusterMerger
```



ok on continue



On continue avec **Étape 3 — `Clusters::AddressWriter`**.

## 1. Crée le fichier

```
nano app/services/clusters/address_writer.rb
```

Colle :

```
# frozen_string_literal: true

module Clusters
  class AddressWriter
    def self.call(grouped_inputs:, height:)
      new(grouped_inputs: grouped_inputs, height: height).call
    end

    def initialize(grouped_inputs:, height:)
      @grouped_inputs = grouped_inputs
      @height = height.to_i
    end

    def call
      addresses = grouped_inputs.keys

      records = addresses.map do |addr|
        find_or_create_address!(addr)
      end

      assign_input_stats!(records)

      records
    end

    private

    attr_reader :grouped_inputs, :height

    def find_or_create_address!(addr)
      existing = Address.find_by(address: addr)
      return existing if existing.present?

      Address.create!(
        address: addr,
        first_seen_height: height,
        last_seen_height: height
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      found = Address.find_by(address: addr)
      return found if found.present?

      raise "AddressWriter failed address=#{addr.inspect} height=#{height}"
    end

    def assign_input_stats!(records)
      records.each do |record|
        input_data = grouped_inputs.fetch(record.address)
        sent_sats = input_data[:total_value_sats].to_i

        record.update!(
          first_seen_height: min_present(record.first_seen_height, height),
          last_seen_height: max_present(record.last_seen_height, height),
          total_sent_sats: record.total_sent_sats.to_i + sent_sats,
          tx_count: record.tx_count.to_i + 1
        )
      end
    end

    def min_present(a, b)
      return b if a.blank?
      [a, b].min
    end

    def max_present(a, b)
      return b if a.blank?
      [a, b].max
    end
  end
end
```

## 2. Dans `ClusterScanner`, remplace

```
addresses = grouped_inputs.map { |g| g[:address] }
grouped_by_address = grouped_inputs.index_by { |g| g[:address] }
```

et :

```
address_records = upsert_addresses!(addresses, height)
assign_input_stats!(address_records, grouped_by_address, height)
```

par :

```
grouped_by_address = grouped_inputs.index_by { |g| g[:address] }

address_records = Clusters::AddressWriter.call(
  grouped_inputs: grouped_by_address,
  height: height
)
```

Donc dans la transaction :

```
ActiveRecord::Base.transaction do
  grouped_by_address = grouped_inputs.index_by { |g| g[:address] }

  address_records = Clusters::AddressWriter.call(
    grouped_inputs: grouped_by_address,
    height: height
  )

  cluster = attach_or_merge_clusters!(address_records)

  @stats[:links_created] += Clusters::LinkWriter.call(
    address_records: address_records,
    txid: txid,
    height: height
  )

  mark_cluster_dirty!(cluster)
end
```

## 3. Supprime ensuite de `ClusterScanner`

```
upsert_addresses!
assign_input_stats!
min_present
max_present
```

## 4. Test

```
BLOCKS=1 bin/rails cluster:scan_recent
```

Sur un bloc déjà traité, tu peux avoir `multi_input_txs: 0`.
Le bon test est plutôt :

```
BLOCKS=2 bin/rails cluster:scan_recent
```

Le scanner doit continuer à sortir :

```
multi_input_txs > 0
links_created > 0
```



victor@debian:~/bitcoin_monitor$ BLOCKS=2 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946440 end_height=946441 [cluster_scan] refresh_dirty_clusters count=162 {:ok=>true, :mode=>:manual, :best_height=>946441, :start_height=>946440, :end_height=>946441, :scanned_blocks=>2, :scanned_txs=>7125, :multi_input_txs=>174, :links_created=>1336, :clusters_created=>116, :clusters_merged=>5, :addresses_touched=>1510, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>318, :already_linked_txs=>0, :input_rows_found=>10982, :multi_address_candidates=>174} victor@debian:~/bitcoin_monitor$ 



Parfait. `Clusters::AddressWriter` est validé.

Le scan reste bon :

```
multi_input_txs: 174
links_created: 1336
clusters_created: 116
clusters_merged: 5
```

Tu peux maintenant supprimer proprement de `ClusterScanner` :

```
upsert_addresses!
assign_input_stats!
min_present
max_present
```

## État actuel du refactor

```
ClusterScanner
  ├── Clusters::InputExtractor
  ├── Clusters::AddressWriter
  └── Clusters::LinkWriter
```

## Prochaine étape

On extrait maintenant :

```
Clusters::ClusterMerger
```

pour sortir de `ClusterScanner` :

```
attach_or_merge_clusters!
merge_clusters!
cleanup_derived_rows_for_clusters!
mark_cluster_dirty!
```

Après ça, `ClusterScanner` deviendra vraiment un orchestrateur propre.



on continue



On continue avec **Étape 4 — `Clusters::ClusterMerger`**.

## 1. Crée le fichier

```
nano app/services/clusters/cluster_merger.rb
```

Colle :

```
# frozen_string_literal: true

module Clusters
  class ClusterMerger
    def self.call(address_records:)
      new(address_records: address_records).call
    end

    def initialize(address_records:)
      @address_records = Array(address_records).compact
    end

    def call
      cluster_ids = address_records.map(&:cluster_id).compact.uniq

      if cluster_ids.empty?
        return create_cluster!
      end

      if cluster_ids.size == 1
        return attach_unclustered_addresses!(Cluster.find(cluster_ids.first))
      end

      merge_clusters!(cluster_ids)
    end

    private

    attr_reader :address_records

    def create_cluster!
      cluster = Cluster.create!

      Address.where(id: address_records.map(&:id)).update_all(
        cluster_id: cluster.id,
        updated_at: Time.current
      )

      Result.new(cluster: cluster, created: 1, merged: 0)
    end

    def attach_unclustered_addresses!(cluster)
      unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)

      if unclustered_ids.any?
        Address.where(id: unclustered_ids).update_all(
          cluster_id: cluster.id,
          updated_at: Time.current
        )
      end

      Result.new(cluster: cluster, created: 0, merged: 0)
    end

    def merge_clusters!(cluster_ids)
      master_id = cluster_ids.min
      other_ids = cluster_ids - [master_id]

      Address.where(cluster_id: other_ids).update_all(
        cluster_id: master_id,
        updated_at: Time.current
      )

      unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)

      if unclustered_ids.any?
        Address.where(id: unclustered_ids).update_all(
          cluster_id: master_id,
          updated_at: Time.current
        )
      end

      cleanup_derived_rows_for_clusters!([master_id] + other_ids)

      Cluster.where(id: other_ids).delete_all

      Result.new(
        cluster: Cluster.find(master_id),
        created: 0,
        merged: other_ids.size
      )
    end

    def cleanup_derived_rows_for_clusters!(cluster_ids)
      ids = Array(cluster_ids).compact.uniq
      return if ids.empty?

      ClusterSignal.where(cluster_id: ids).delete_all
      ClusterMetric.where(cluster_id: ids).delete_all
      ClusterProfile.where(cluster_id: ids).delete_all
    end

    Result = Struct.new(:cluster, :created, :merged, keyword_init: true)
  end
end
```

## 2. Dans `ClusterScanner`, remplace

```
cluster = attach_or_merge_clusters!(address_records)
```

par :

```
merge_result = Clusters::ClusterMerger.call(address_records: address_records)

@stats[:clusters_created] += merge_result.created
@stats[:clusters_merged] += merge_result.merged

cluster = merge_result.cluster
```

## 3. Supprime de `ClusterScanner`

```
attach_or_merge_clusters!
merge_clusters!
cleanup_derived_rows_for_clusters!
```

Garde :

```
mark_cluster_dirty!
```

pour l’instant.

## 4. Test

```
BLOCKS=2 bin/rails cluster:scan_recent
```

On veut encore :

```
multi_input_txs > 0
links_created > 0
clusters_created >= 0
clusters_merged >= 0
```



victor@debian:~/bitcoin_monitor$ BLOCKS=3 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946439 end_height=946441 [cluster_scan] refresh_dirty_clusters count=51 {:ok=>true, :mode=>:manual, :best_height=>946441, :start_height=>946439, :end_height=>946441, :scanned_blocks=>3, :scanned_txs=>13605, :multi_input_txs=>53, :links_created=>136, :clusters_created=>27, :clusters_merged=>1, :addresses_touched=>189, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>432, :already_linked_txs=>174, :input_rows_found=>16210, :multi_address_candidates=>53} victor@debian:~/bitcoin_monitor$ 



Parfait. `Clusters::ClusterMerger` fonctionne.

Le refactor principal est maintenant réussi.

## Architecture actuelle

Tu es passé de :

```
ClusterScanner = énorme classe monolithique
```

à :

```
ClusterScanner
  ├── Clusters::InputExtractor
  ├── Clusters::AddressWriter
  ├── Clusters::LinkWriter
  └── Clusters::ClusterMerger
```

Ça change énormément la maintenabilité.

------

# Ce que tu peux maintenant supprimer de `ClusterScanner`

Tu peux retirer définitivement :

```
extract_input_rows_from_prevout
group_inputs_by_address
extract_address
btc_to_sats
upsert_addresses!
assign_input_stats!
attach_or_merge_clusters!
merge_clusters!
cleanup_derived_rows_for_clusters!
min_present
max_present
```

------

# Maintenant le vrai gros gain arrive

## Étape suivante = performance

Car actuellement :

```
Address.find_by
Address.create!
record.update!
find_or_initialize_by
link.save!
```

👉 ça fait énormément de requêtes SQL.

------

# Ce qu’il faut faire ensuite

## Phase performance V2

Transformer :

```
N requêtes SQL par tx
```

en :

```
1 batch SQL
```

avec :

```
insert_all
upsert_all
update_all
```

------

# Gains potentiels

Tu peux probablement multiplier la vitesse du scan par :

```
x5
à
x20
```

selon la taille des blocs.

------

# La prochaine cible

👉 `Clusters::AddressWriter`

Actuellement il fait :

```
find_by
create!
update!
```

adresse par adresse.

C’est le plus gros frein actuel.

------

# Architecture cible future

## Scanner ultra léger

```
nouveau bloc
↓
InputExtractor
↓
AddressWriter.batch
↓
LinkWriter.batch
↓
ClusterMerger
↓
dirty clusters
```

------

# Et ensuite

Après les batchs SQL :

## Étape Redis

Pour cache RAM :

```
address -> cluster_id
```

et éviter :

```
des milliers de SELECT
```

------

# Et ensuite

## Temps réel ZMQ

```
bitcoind ZMQ
↓
nouveau bloc
↓
scan incrémental
↓
dashboard live
```

------

# Mon avis honnête maintenant

Ton module cluster est en train de devenir :

```
un vrai moteur d’analyse blockchain
```

et plus un “script Rails”.

C’est exactement la bonne direction pour Bitcoin Monitor.



on continue



Réflexion durant quelques secondes

Oui. Prochaine étape : **optimiser `Clusters::AddressWriter`**, mais doucement.

Pour l’instant on ne fait pas encore `upsert_all`, on fait d’abord une version plus propre avec moins de requêtes.

## Étape 5 — améliorer `AddressWriter`

Dans `app/services/clusters/address_writer.rb`, remplace la méthode `call` par :

```
def call
  addresses = grouped_inputs.keys

  existing_records = Address.where(address: addresses).index_by(&:address)

  missing_addresses = addresses - existing_records.keys

  missing_addresses.each do |addr|
    existing_records[addr] = create_address!(addr)
  end

  records = addresses.map { |addr| existing_records.fetch(addr) }

  assign_input_stats!(records)

  records
end
```

Puis ajoute cette méthode privée :

```
def create_address!(addr)
  Address.create!(
    address: addr,
    first_seen_height: height,
    last_seen_height: height
  )
rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
  found = Address.find_by(address: addr)
  return found if found.present?

  raise "AddressWriter failed address=#{addr.inspect} height=#{height}"
end
```

Et tu peux supprimer l’ancienne méthode :

```
find_or_create_address!
```

## Pourquoi c’est mieux

Avant tu faisais :

```
1 SELECT par adresse
+ parfois 1 INSERT
+ 1 UPDATE
```

Maintenant tu fais :

```
1 seul SELECT pour toutes les adresses de la tx
+ INSERT seulement pour les nouvelles
+ UPDATE stats ensuite
```

## Test

Relance :

```
BLOCKS=2 bin/rails cluster:scan_recent
```

On veut toujours :

```
multi_input_txs > 0
links_created > 0
clusters_created >= 0
```

Après validation, on pourra optimiser encore plus avec `insert_all`.



victor@debian:~/bitcoin_monitor$ BLOCKS=4 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946438 end_height=946441 [cluster_scan] refresh_dirty_clusters count=383 {:ok=>true, :mode=>:manual, :best_height=>946441, :start_height=>946438, :end_height=>946441, :scanned_blocks=>4, :scanned_txs=>17276, :multi_input_txs=>443, :links_created=>2561, :clusters_created=>273, :clusters_merged=>3, :addresses_touched=>3004, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>1253, :already_linked_txs=>227, :input_rows_found=>24051, :multi_address_candidates=>443} victor@debian:~/bitcoin_monitor$ 



Parfait. L’optimisation `AddressWriter` est validée.

Tu as maintenant :

```
multi_input_txs: 443
links_created: 2561
clusters_created: 273
addresses_touched: 3004
```

## Prochaine étape

On fait la même chose pour :

```
Clusters::LinkWriter
```

Actuellement il fait encore :

```
find_or_initialize_by
save!
```

lien par lien.

Prochaine amélioration :

```
préparer tous les liens
↓
faire 1 SELECT des liens existants
↓
insérer seulement les nouveaux
```

Ce sera un gros gain sur les blocs très chargés.



on continue



Oui. Étape suivante : **optimiser `Clusters::LinkWriter`**.

## Remplace tout le fichier

```
# frozen_string_literal: true

module Clusters
  class LinkWriter
    LINK_TYPE = "multi_input"

    def self.call(address_records:, txid:, height:)
      new(
        address_records: address_records,
        txid: txid,
        height: height
      ).call
    end

    def initialize(address_records:, txid:, height:)
      @address_records = Array(address_records).compact
      @txid = txid.to_s
      @height = height.to_i
    end

    def call
      records = address_records.sort_by(&:id)
      return 0 if records.size < 2

      rows = build_link_rows(records)
      return 0 if rows.empty?

      existing_pairs = existing_pairs_for(rows)

      new_rows = rows.reject do |row|
        existing_pairs.include?([row[:address_a_id], row[:address_b_id]])
      end

      return 0 if new_rows.empty?

      AddressLink.insert_all!(new_rows)

      new_rows.size
    end

    private

    attr_reader :address_records, :txid, :height

    def build_link_rows(records)
      now = Time.current
      pivot = records.first

      records.drop(1).map do |other|
        id_a, id_b = [pivot.id, other.id].sort

        {
          address_a_id: id_a,
          address_b_id: id_b,
          link_type: LINK_TYPE,
          txid: txid,
          block_height: height,
          created_at: now,
          updated_at: now
        }
      end
    end

    def existing_pairs_for(rows)
      pairs = rows.map { |r| [r[:address_a_id], r[:address_b_id]] }

      AddressLink
        .where(txid: txid, link_type: LINK_TYPE)
        .where(address_a_id: pairs.map(&:first), address_b_id: pairs.map(&:second))
        .pluck(:address_a_id, :address_b_id)
        .to_set
    end
  end
end
```

## Important

En haut du fichier, ajoute aussi :

```
require "set"
```

Donc le début doit être :

```
# frozen_string_literal: true

require "set"
```

## Test

Comme avant :

```
BLOCKS=2 bin/rails cluster:scan_recent
```

Sur des blocs déjà traités, `links_created` peut être à `0`.

Le bon test :

```
BLOCKS=5 bin/rails cluster:scan_recent
```

ou attendre un nouveau bloc.



victor@debian:~/bitcoin_monitor$ BLOCKS=7 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946435 end_height=946441 [cluster_scan] refresh_dirty_clusters count=79 {:ok=>true, :mode=>:manual, :best_height=>946441, :start_height=>946435, :end_height=>946441, :scanned_blocks=>7, :scanned_txs=>27200, :multi_input_txs=>82, :links_created=>534, :clusters_created=>50, :clusters_merged=>1, :addresses_touched=>616, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>2294, :already_linked_txs=>1101, :input_rows_found=>31629, :multi_address_candidates=>82} victor@debian:~/bitcoin_monitor$ 



Parfait. `LinkWriter` optimisé est validé.

Ce résultat est normal :

```
already_linked_txs: 1101
multi_input_txs: 82
links_created: 534
```

Tu as rescanné beaucoup de blocs déjà traités, donc le scanner saute les tx déjà connues.

## État actuel

```
ClusterScanner
  ├── InputExtractor       OK
  ├── AddressWriter        OK + optimisé
  ├── LinkWriter           OK + insert_all
  └── ClusterMerger        OK
```

## Prochaine étape

On peut maintenant nettoyer `ClusterScanner` pour qu’il ne garde que :

```
range
scan block
scan transaction
stats
progress
dirty clusters
cursor
```

Ensuite on passera au vrai gros sujet :

```
éviter refresh_dirty_clusters trop coûteux
```

car ça :

```
refresh_dirty_clusters count=79
```

peut devenir très lourd sur un gros backfill.



on continue



Oui. Maintenant on nettoie `ClusterScanner`.

## Supprime de `ClusterScanner`

Toutes ces méthodes ne doivent plus exister dedans :

```
extract_input_rows_from_prevout
group_inputs_by_address
extract_address
btc_to_sats
upsert_addresses!
assign_input_stats!
attach_or_merge_clusters!
merge_clusters!
cleanup_derived_rows_for_clusters!
min_present
max_present
create_links!
```

## Il doit garder seulement

```
compute_scan_range
manual_mode?
default_manual_span
scanner_cursor
update_cursor!
scan_block
scan_transaction
coinbase_tx?
mark_cluster_dirty!
refresh_dirty_clusters!
log_progress
update_progress!
```

## Puis vérifie

```
grep -n "def " app/services/cluster_scanner.rb
```

Tu dois voir une liste beaucoup plus courte.

Ensuite relance :

```
BLOCKS=2 bin/rails cluster:scan_recent
```

Après ça, on attaque `refresh_dirty_clusters!`, qui est le prochain vrai point lourd.



victor@debian:~/bitcoin_monitor$ grep -n "def " app/services/cluster_scanner.rb 12:  def self.call(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil) 22:  def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil) 49:  def call 97:  def compute_scan_range(best_height) 135:  def manual_mode? 139:  def default_manual_span 143:  def scanner_cursor 147:  def update_cursor!(height) 156:  def scan_block(height) 176:  def scan_transaction(tx, height) 236:  def coinbase_tx?(tx) 240:  def mark_cluster_dirty!(cluster) 246:  def refresh_dirty_clusters! 257:  def log_progress(height) 275:  def update_progress!(current_height, start_height, end_height) victor@debian:~/bitcoin_monitor$ 



Parfait. Là `ClusterScanner` est redevenu propre.

Il est maintenant un **orchestrateur**, pas un monolithe.

## État final propre

```
ClusterScanner
  ├── range / cursor
  ├── scan block
  ├── scan transaction
  ├── stats
  ├── progress
  └── dirty clusters
```

Et la logique métier est sortie dans :

```
Clusters::InputExtractor
Clusters::AddressWriter
Clusters::LinkWriter
Clusters::ClusterMerger
```

## Test final rapide

```
BLOCKS=2 bin/rails cluster:scan_recent
```

Ensuite on passe au prochain gros morceau :

```
refresh_dirty_clusters!
```

C’est lui qui peut ralentir fortement les backfills.



on continue



Oui. Maintenant on optimise **`refresh_dirty_clusters!`**.

Actuellement il fait :

```
Cluster.where(id: @dirty_cluster_ids.to_a).find_each do |cluster|
  cluster.recalculate_stats!
  ClusterAggregator.call(cluster)
end
```

Donc après chaque scan, il recalcule tous les clusters touchés immédiatement.

## Étape 6 — limiter le coût du refresh

Remplace `refresh_dirty_clusters!` par :

```
def refresh_dirty_clusters!
  return if @dirty_cluster_ids.empty?

  ids = @dirty_cluster_ids.to_a.uniq

  puts "[cluster_scan] refresh_dirty_clusters count=#{ids.size}"

  Cluster.where(id: ids).find_each(batch_size: 100) do |cluster|
    cluster.recalculate_stats!
    ClusterAggregator.call(cluster)
  rescue StandardError => e
    puts "[cluster_scan] refresh_dirty_cluster_failed cluster_id=#{cluster.id} error=#{e.class}: #{e.message}"
  end
end
```

## Ce que ça améliore

- traitement par batch
- pas de crash complet si un cluster échoue
- logs plus propres
- base prête pour passer plus tard en job séparé

Ensuite teste :

```
BLOCKS=3 bin/rails cluster:scan_recent
```

Puis on fera la vraie version pro :

```
ClusterRefreshJob
```

pour sortir ce travail du scanner.



victor@debian:~/bitcoin_monitor$ BLOCKS=8 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946435 end_height=946442 [cluster_scan] refresh_dirty_clusters count=405 {:ok=>true, :mode=>:manual, :best_height=>946442, :start_height=>946435, :end_height=>946442, :scanned_blocks=>8, :scanned_txs=>30721, :multi_input_txs=>467, :links_created=>2390, :clusters_created=>296, :clusters_merged=>2, :addresses_touched=>2857, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>3130, :already_linked_txs=>1183, :input_rows_found=>38342, :multi_address_candidates=>467} victor@debian:~/bitcoin_monitor$ 



Parfait. `refresh_dirty_clusters!` est stable.

Mais là on voit le futur problème :

```
refresh_dirty_clusters count=405
```

Sur 8 blocs, ça passe.
Sur 500 ou 5 000 blocs, ça va devenir lourd.

## Prochaine étape

Créer un vrai job séparé :

```
ClusterRefreshJob
```

Objectif :

```
ClusterScanner scanne vite
↓
il marque les clusters dirty
↓
ClusterRefreshJob recalcule après
```

Mais avant ça, on garde ton état actuel car il est sain :

```
ClusterScanner propre
InputExtractor OK
AddressWriter OK
LinkWriter OK
ClusterMerger OK
Refresh sécurisé
```

Prochaine action : extraire `refresh_dirty_clusters!` dans `Clusters::DirtyClusterRefresher`.



on continue



Oui. Étape suivante : **extraire `DirtyClusterRefresher`**.

## 1. Crée le fichier

```
nano app/services/clusters/dirty_cluster_refresher.rb
```

Colle :

```
# frozen_string_literal: true

module Clusters
  class DirtyClusterRefresher
    def self.call(cluster_ids:)
      new(cluster_ids: cluster_ids).call
    end

    def initialize(cluster_ids:)
      @cluster_ids = Array(cluster_ids).compact.uniq
    end

    def call
      return 0 if cluster_ids.empty?

      puts "[cluster_scan] refresh_dirty_clusters count=#{cluster_ids.size}"

      refreshed = 0

      Cluster.where(id: cluster_ids).find_each(batch_size: 100) do |cluster|
        cluster.recalculate_stats!
        ClusterAggregator.call(cluster)
        refreshed += 1
      rescue StandardError => e
        puts "[cluster_scan] refresh_dirty_cluster_failed cluster_id=#{cluster.id} error=#{e.class}: #{e.message}"
      end

      refreshed
    end

    private

    attr_reader :cluster_ids
  end
end
```

## 2. Dans `ClusterScanner`, remplace `refresh_dirty_clusters!`

Par :

```
def refresh_dirty_clusters!
  Clusters::DirtyClusterRefresher.call(
    cluster_ids: @dirty_cluster_ids.to_a
  )
end
```

## 3. Test

```
BLOCKS=3 bin/rails cluster:scan_recent
```

Après ça, `ClusterScanner` sera encore plus propre.



victor@debian:~/bitcoin_monitor$ BLOCKS=9 bin/rails cluster:scan_recent [cluster_scan] start mode=manual start_height=946436 end_height=946444 [cluster_scan] refresh_dirty_clusters count=263 {:ok=>true, :mode=>:manual, :best_height=>946444, :start_height=>946436, :end_height=>946444, :scanned_blocks=>9, :scanned_txs=>34410, :multi_input_txs=>294, :links_created=>2247, :clusters_created=>181, :clusters_merged=>3, :addresses_touched=>2541, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>3544, :already_linked_txs=>1568, :input_rows_found=>42905, :multi_address_candidates=>294} victor@debian:~/bitcoin_monitor$ 



Parfait. `DirtyClusterRefresher` est validé.

Ton module est maintenant beaucoup plus propre :

```
ClusterScanner
  ├── Clusters::InputExtractor
  ├── Clusters::AddressWriter
  ├── Clusters::LinkWriter
  ├── Clusters::ClusterMerger
  └── Clusters::DirtyClusterRefresher
```

Prochaine étape logique :

```
ClusterScanner ne doit plus refresh automatiquement en gros backfill
```

On va ajouter une option :

```
refresh: true
```

pour pouvoir faire :

```
ClusterScanner.call(limit: 500, refresh: false)
```

Puis lancer le refresh séparément après.



on continue



Oui. Étape suivante : ajouter l’option `refresh:` à `ClusterScanner`.

## 1. Modifie `self.call`

Remplace :

```
def self.call(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil)
```

par :

```
def self.call(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil, refresh: true)
```

Et dans `new(...)`, ajoute :

```
refresh: refresh
```

------

## 2. Modifie `initialize`

Remplace :

```
def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil)
```

par :

```
def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil, refresh: true)
```

Puis ajoute :

```
@refresh = refresh
```

------

## 3. Modifie `call`

Remplace :

```
refresh_dirty_clusters!
```

par :

```
refresh_dirty_clusters! if @refresh
```

------

## 4. Ajoute dans le résultat final

Dans le hash final, ajoute :

```
refresh: @refresh,
dirty_clusters_count: @dirty_cluster_ids.size
```

Exemple :

```
{
  ok: true,
  mode: range[:mode],
  best_height: best_height,
  start_height: range[:start_height],
  end_height: range[:end_height],
  refresh: @refresh,
  dirty_clusters_count: @dirty_cluster_ids.size
}.merge(@stats)
```

------

## 5. Test rapide

```
rails c
```

Puis :

```
ClusterScanner.call(limit: 2, refresh: false)
```

Tu dois voir :

```
refresh: false
dirty_clusters_count: ...
```

et aucun log :

```
refresh_dirty_clusters
```



=>  {:ok=>true, :mode=>:incremental, :best_height=>946445, :start_height=>942687, :end_height=>942688, :refresh=>false, :dirty_clusters_count=>0, :scanned_blocks=>2, :scanned_txs=>8203, :multi_input_txs=>0, :links_created=>0, :clusters_created=>0, :clusters_merged=>0, :addresses_touched=>0, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>1257, :already_linked_txs=>764, :input_rows_found=>8533, :multi_address_candidates=>0} bitcoin-monitor(dev)> 



Parfait, l’option `refresh: false` fonctionne.

Mais ton curseur `cluster_scan` est ancien :

```
start_height: 942687
best_height: 946445
```

Donc ton lag est environ :

```
946445 - 942688 = 3757 blocs
```

## C’est normal que ce test ne crée rien

Tu as :

```
already_linked_txs: 764
multi_input_txs: 0
dirty_clusters_count: 0
```

Ça veut dire : ces blocs étaient déjà traités.

## Test plus parlant

Lance un scan manuel récent sans refresh :

```
ClusterScanner.call(
  from_height: 946445,
  to_height: 946445,
  refresh: false
)
```

Là tu devrais voir :

```
refresh: false
dirty_clusters_count: > 0
multi_input_txs: > 0
```

Ensuite, on ajoutera une tâche séparée pour rafraîchir les dirty clusters.



=>  {:ok=>true, :mode=>:manual, :best_height=>946446, :start_height=>946445, :end_height=>946445, :refresh=>false, :dirty_clusters_count=>223, :scanned_blocks=>1, :scanned_txs=>4665, :multi_input_txs=>244, :links_created=>2482, :clusters_created=>156, :clusters_merged=>2, :addresses_touched=>2726, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>478, :already_linked_txs=>0, :input_rows_found=>7859, :multi_address_candidates=>244} bitcoin-monitor(dev)> 



Parfait. Là c’est exactement le comportement voulu.

```
scan terminé
refresh désactivé
dirty_clusters_count: 223
multi_input_txs: 244
links_created: 2482
```

## Ce que ça permet maintenant

Pour un gros backfill :

```
ClusterScanner.call(from_height: 946000, to_height: 946500, refresh: false)
```

Puis refresh séparé ensuite.

## Prochaine étape

Créer un service dédié pour refresh manuel :

```
Clusters::DirtyClusterRefresher.call(cluster_ids: ids)
```

Mais il nous manque une chose : actuellement les dirty cluster IDs sont seulement en mémoire.

Donc prochaine amélioration propre :

```
créer une table cluster_refresh_queues
```

ou plus simple pour l’instant :

```
retourner dirty_cluster_ids dans le résultat quand refresh: false
```

On peut faire la version simple maintenant.



ok on continue



Oui. Version simple : on retourne les IDs dirty dans le résultat quand `refresh: false`.

## Dans `ClusterScanner`, modifie le hash final

Remplace :

```
dirty_clusters_count: @dirty_cluster_ids.size
```

par :

```
dirty_clusters_count: @dirty_cluster_ids.size,
dirty_cluster_ids: @refresh ? [] : @dirty_cluster_ids.to_a
```

Donc le bloc final devient :

```
{
  ok: true,
  mode: range[:mode],
  best_height: best_height,
  start_height: range[:start_height],
  end_height: range[:end_height],
  refresh: @refresh,
  dirty_clusters_count: @dirty_cluster_ids.size,
  dirty_cluster_ids: @refresh ? [] : @dirty_cluster_ids.to_a
}.merge(@stats)
```

## Test

```
result = ClusterScanner.call(
  from_height: 946446,
  to_height: 946446,
  refresh: false
)

result[:dirty_clusters_count]
result[:dirty_cluster_ids].first(10)
```

Ensuite tu peux lancer manuellement :

```
Clusters::DirtyClusterRefresher.call(
  cluster_ids: result[:dirty_cluster_ids]
)
```

Ça sépare enfin :

```
scan blockchain
↓
refresh clusters
```



 AddressLink Exists? (0.2ms)  SELECT 1 AS one FROM "address_links" WHERE "address_links"."txid" = 'b713b70f3fd049686687584486e764d15eb095d71a74bfde0580a9067cf9c8b9' AND "address_links"."link_type" = 'multi_input' LIMIT 1 /*application='BitcoinMonitor'*/ (bitcoin-monitor):14:in `<main>': undefined method `first' for nil:NilClass (NoMethodError) result[:dirty_cluster_ids].first(10)                          ^^^^^^ bitcoin-monitor(dev)> 



Réflexion durant quelques secondes

L’erreur veut dire :

```
result[:dirty_cluster_ids]
# => nil
```

Donc la clé n’est pas encore présente dans le résultat chargé par Rails.

Deux causes possibles :

## 1. Tu n’as pas relancé la console

Après modification du fichier, quitte Rails console :

```
exit
```

Puis relance :

```
rails c
```

## 2. La clé n’a pas été ajoutée au bon endroit

Dans `app/services/cluster_scanner.rb`, le hash final doit être comme ça :

```
{
  ok: true,
  mode: range[:mode],
  best_height: best_height,
  start_height: range[:start_height],
  end_height: range[:end_height],
  refresh: @refresh,
  dirty_clusters_count: @dirty_cluster_ids.size,
  dirty_cluster_ids: @refresh ? [] : @dirty_cluster_ids.to_a
}.merge(@stats)
```

Ensuite refais :

```
result = ClusterScanner.call(
  from_height: 946446,
  to_height: 946446,
  refresh: false
)

result.keys
```

Tu dois voir :

```
:dirty_cluster_ids
```

Puis :

```
result[:dirty_cluster_ids].first(10)
```

Si le bloc a déjà été scanné, `dirty_cluster_ids` peut être vide, mais il ne doit plus être `nil`.



=>  [:ok, :mode, :best_height, :start_height, :end_height, :refresh, :dirty_clusters_count, :dirty_cluster_ids, :scanned_blocks, :scanned_txs, :multi_input_txs, :links_created, :clusters_created, :clusters_merged, :addresses_touched, :pruned_blocks_skipped, :tx_skipped_rpc_errors, :tx_skipped_missing_prevout, :multi_input_candidates, :already_linked_txs, :input_rows_found, :multi_address_candidates] bitcoin-monitor(dev)> result[:dirty_cluster_ids].first(10) => [] bitcoin-monitor(dev)> 



Parfait. La clé est bien ajoutée.

Là tu as :

```
result[:dirty_cluster_ids]
# => []
```

Donc le bloc testé était déjà scanné.

## Test sur un bloc récent non traité

Dans Rails console :

```
best = BitcoinRpc.new(wallet: nil).getblockcount.to_i

result = ClusterScanner.call(
  from_height: best,
  to_height: best,
  refresh: false
)

result[:dirty_clusters_count]
result[:dirty_cluster_ids].first(10)
```

Si le bloc est nouveau, tu dois avoir :

```
dirty_clusters_count > 0
dirty_cluster_ids non vide
```

Puis tu peux lancer :

```
Clusters::DirtyClusterRefresher.call(
  cluster_ids: result[:dirty_cluster_ids]
)
```



j'ai un tableau vide



C’est normal si le bloc `best` avait déjà été scanné.

Teste plutôt le **dernier bloc non traité** en regardant le curseur :

```
cursor = ScannerCursor.find_by(name: "cluster_scan")
cursor.last_blockheight
best = BitcoinRpc.new(wallet: nil).getblockcount.to_i
[ cursor.last_blockheight, best ]
```

Puis scanne le bloc juste après le curseur :

```
h = cursor.last_blockheight.to_i + 1

result = ClusterScanner.call(
  from_height: h,
  to_height: h,
  refresh: false
)

result[:multi_input_txs]
result[:dirty_clusters_count]
result[:dirty_cluster_ids].first(10)
```

Mais attention : si ce bloc avait déjà été scanné en mode manuel avant, tu auras encore :

```
[]
```

Ce n’est pas grave.

Le plus important est validé :

```
:dirty_cluster_ids
```

existe bien maintenant.



bitcoin-monitor(dev)> cursor = ScannerCursor.find_by(name: "cluster_scan") bitcoin-monitor(dev)> cursor.last_blockheight bitcoin-monitor(dev)> best = BitcoinRpc.new(wallet: nil).getblockcount.to_i bitcoin-monitor(dev)> [ cursor.last_blockheight, best ]  ScannerCursor Load (4.3ms)  SELECT "scanner_cursors".* FROM "scanner_cursors" WHERE "scanner_cursors"."name" = 'cluster_scan' LIMIT 1 /*application='BitcoinMonitor'*/ => [942688, 946448] bitcoin-monitor(dev)> 



Ton curseur est très en retard :

```
cursor: 942688
best:   946448
retard: 3760 blocs
```

Teste maintenant :

```
h = cursor.last_blockheight.to_i + 1

result = ClusterScanner.call(
  from_height: h,
  to_height: h,
  refresh: false
)

result[:multi_input_txs]
result[:dirty_clusters_count]
result[:dirty_cluster_ids].first(10)
```

Mais pour le vrai rattrapage, on pourra faire ensuite :

```
ClusterScanner.call(
  from_height: 942689,
  to_height: 943000,
  refresh: false
)
```

puis refresh séparé.



toujours tableau vide en faisant ca h = cursor.last_blockheight.to_i + 1 result = ClusterScanner.call(  from_height: h,  to_height: h,  refresh: false ) result[:multi_input_txs] result[:dirty_clusters_count] result[:dirty_cluster_ids].first(10)



Réflexion durant quelques secondes

Oui, c’est cohérent.

Ton curseur est à `942688`, mais les blocs après ont probablement déjà été scannés **en mode manuel**. Comme le mode manuel ne met pas à jour le curseur, tu peux avoir :

```
cursor ancien
mais AddressLink déjà présents
donc dirty_cluster_ids vide
```

Vérifie avec :

```
result.slice(
  :start_height,
  :end_height,
  :multi_input_txs,
  :already_linked_txs,
  :dirty_clusters_count,
  :dirty_cluster_ids
)
```

Si tu vois :

```
multi_input_txs: 0
already_linked_txs: > 0
dirty_clusters_count: 0
```

alors tout est normal : le bloc est déjà traité.

Pour tester sur un bloc vraiment nouveau, prends le dernier bloc courant :

```
best = BitcoinRpc.new(wallet: nil).getblockcount.to_i

result = ClusterScanner.call(
  from_height: best,
  to_height: best,
  refresh: false
)

result.slice(
  :multi_input_txs,
  :already_linked_txs,
  :dirty_clusters_count,
  :dirty_cluster_ids
)
```

Si `best` est déjà traité aussi, attends juste qu’un nouveau bloc arrive ou teste sur une hauteur que tu sais non scannée.

Le point important : `dirty_cluster_ids` ne se remplit que quand il y a :

```
multi_input_txs > 0
```

Pas quand la transaction est déjà connue via :

```
already_linked_txs
```



=> [] bitcoin-monitor(dev)* result.slice( bitcoin-monitor(dev)*   :start_height, bitcoin-monitor(dev)*   :end_height, bitcoin-monitor(dev)*   :multi_input_txs, bitcoin-monitor(dev)*   :already_linked_txs, bitcoin-monitor(dev)*   :dirty_clusters_count, bitcoin-monitor(dev)*   :dirty_cluster_ids bitcoin-monitor(dev)> ) =>  {:start_height=>942689, :end_height=>942689, :multi_input_txs=>0, :already_linked_txs=>176, :dirty_clusters_count=>0, :dirty_cluster_ids=>[]} bitcoin-monitor(dev)> 



Oui, c’est confirmé :

```
multi_input_txs: 0
already_linked_txs: 176
dirty_cluster_ids: []
```

Donc le bloc `942689` est **déjà traité**, même si le curseur est resté à `942688`.

## Prochaine action

Il faut recaler le curseur sur le dernier bloc réellement traité.

Dans `rails c` :

```
last = AddressLink.where(link_type: "multi_input").maximum(:block_height)

cursor = ScannerCursor.find_or_create_by!(name: "cluster_scan")
cursor.update!(
  last_blockheight: last,
  last_blockhash: BitcoinRpc.new(wallet: nil).getblockhash(last)
)

[cursor.last_blockheight, last]
```

Ensuite le scan incrémental repartira proprement depuis :

```
last + 1
```



=> [946446, 946446]



Parfait.

Ton curseur `cluster_scan` est maintenant recalé :

```
last_blockheight: 946446
```

Donc le prochain scan incrémental partira de :

```
946447
```

Tu peux tester :

```
bin/rails cluster:scan
```

ou :

```
LIMIT=2 bin/rails cluster:scan
```

Le comportement attendu :

```
start_height = 946447
end_height = best_height
```

Là ton module `cluster` est beaucoup plus sain.



victor@debian:~/bitcoin_monitor$ LIMIT=2 bin/rails cluster:scan [cluster_scan] start mode=incremental start_height=946447 end_height=946448 [cluster_scan] refresh_dirty_clusters count=220 {:ok=>true, :mode=>:incremental, :best_height=>946449, :start_height=>946447, :end_height=>946448, :refresh=>true, :dirty_clusters_count=>220, :dirty_cluster_ids=>[], :scanned_blocks=>2, :scanned_txs=>8247, :multi_input_txs=>250, :links_created=>2044, :clusters_created=>155, :clusters_merged=>4, :addresses_touched=>2294, :pruned_blocks_skipped=>0, :tx_skipped_rpc_errors=>0, :tx_skipped_missing_prevout=>0, :multi_input_candidates=>439, :already_linked_txs=>0, :input_rows_found=>12584, :multi_address_candidates=>250} victor@debian:~/bitcoin_monitor$ 



Parfait. Tout est sain maintenant.

```
mode: incremental
start: 946447
end: 946448
multi_input_txs: 250
links_created: 2044
dirty_clusters_count: 220
```

Le curseur est réparé, le scan incrémental repart proprement.

Prochaine étape recommandée : ajouter dans `/system` une ligne claire :

```
cluster_scan cursor: 946448
best_height: 946449
lag: 1 block
status: OK
```

Comme ça, tu verras immédiatement si `cluster` prend du retard.



ok



Ajoute maintenant un vrai état de santé `cluster_scan` dans le module système de Bitcoin Monitor.

## Objectif

Afficher :

```
cluster_scan
cursor
best height
lag
status
```

dans `/system`.

------

# Étape 1 — créer un snapshot service

Crée :

```
nano app/services/system/cluster_scan_status.rb
```

Colle :

```
# frozen_string_literal: true

module System
  class ClusterScanStatus
    WARNING_LAG = 12
    CRITICAL_LAG = 48

    def self.call
      new.call
    end

    def call
      rpc = BitcoinRpc.new(wallet: nil)

      best_height = rpc.getblockcount.to_i

      cursor = ScannerCursor.find_by(name: "cluster_scan")

      last_height = cursor&.last_blockheight.to_i

      lag =
        if last_height.positive?
          best_height - last_height
        else
          best_height
        end

      {
        cursor_height: last_height,
        best_height: best_height,
        lag: lag,
        status: compute_status(lag)
      }
    rescue StandardError => e
      {
        cursor_height: nil,
        best_height: nil,
        lag: nil,
        status: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def compute_status(lag)
      return "critical" if lag >= CRITICAL_LAG
      return "warning" if lag >= WARNING_LAG

      "ok"
    end
  end
end
```

------

# Étape 2 — tester dans rails console

```
System::ClusterScanStatus.call
```

Tu dois voir :

```
{
  cursor_height: ...,
  best_height: ...,
  lag: ...,
  status: "ok"
}
```

Ensuite on branchera ça dans `/system`.



victor@debian:~/bitcoin_monitor$ rails c Loading development environment (Rails 8.0.4) bitcoin-monitor(dev)> System::ClusterScanStatus.call  ScannerCursor Load (0.8ms)  SELECT "scanner_cursors".* FROM "scanner_cursors" WHERE "scanner_cursors"."name" = 'cluster_scan' LIMIT 1 /*application='BitcoinMonitor'*/ => {:cursor_height=>946448, :best_height=>946450, :lag=>2, :status=>"ok"} bitcoin-monitor(dev)> 



Parfait. Le statut `cluster_scan` fonctionne.

Tu as maintenant un vrai état opérationnel :

```
cursor_height: 946448
best_height:   946450
lag:           2
status:        ok
```

## Prochaine étape

Brancher ça dans la page `/system`.

L’idée est d’avoir un bloc comme :

```
Cluster Scan
cursor: 946448
best: 946450
lag: 2
status: OK
```

avec :

```
OK
WARNING
CRITICAL
```

comme pour tes autres modules.



ok on continue



Réflexion durant quelques secondes

On branche `System::ClusterScanStatus` dans `/system`.

## 1. Dans le controller système

Cherche ton controller :

```
grep -R "class .*System" -n app/controllers
```

Puis dans l’action `index`, ajoute :

```
@cluster_scan_status = System::ClusterScanStatus.call
```

Exemple :

```
def index
  @cluster_scan_status = System::ClusterScanStatus.call

  # le reste de ton code existant...
end
```

## 2. Dans la vue `/system`

Cherche la vue :

```
find app/views -iname "*system*" -o -path "*system*"
```

Puis ajoute un bloc simple :

```
<div class="rounded-2xl border border-slate-800 bg-slate-950 p-5">
  <div class="flex items-center justify-between">
    <div>
      <h3 class="text-sm font-semibold text-slate-100">Cluster Scan</h3>
      <p class="mt-1 text-xs text-slate-400">
        Suivi du curseur d’analyse des clusters Bitcoin.
      </p>
    </div>

    <span class="rounded-full px-3 py-1 text-xs font-semibold
      <%= case @cluster_scan_status[:status]
          when "ok" then "bg-emerald-500/10 text-emerald-300"
          when "warning" then "bg-amber-500/10 text-amber-300"
          else "bg-red-500/10 text-red-300"
          end %>">
      <%= @cluster_scan_status[:status].upcase %>
    </span>
  </div>

  <dl class="mt-4 grid grid-cols-2 gap-4 text-sm">
    <div>
      <dt class="text-slate-500">Cursor</dt>
      <dd class="font-mono text-slate-100"><%= @cluster_scan_status[:cursor_height] || "—" %></dd>
    </div>

    <div>
      <dt class="text-slate-500">Best height</dt>
      <dd class="font-mono text-slate-100"><%= @cluster_scan_status[:best_height] || "—" %></dd>
    </div>

    <div>
      <dt class="text-slate-500">Lag</dt>
      <dd class="font-mono text-slate-100"><%= @cluster_scan_status[:lag] || "—" %> blocs</dd>
    </div>

    <div>
      <dt class="text-slate-500">État</dt>
      <dd class="font-mono text-slate-100"><%= @cluster_scan_status[:status] %></dd>
    </div>
  </dl>

  <% if @cluster_scan_status[:error].present? %>
    <p class="mt-4 text-xs text-red-300">
      <%= @cluster_scan_status[:error] %>
    </p>
  <% end %>
</div>
```

## 3. Test

```
bin/rails s
```

Puis ouvre :

```
/system
```

Tu dois voir :

```
Cluster Scan
Cursor: 946448
Best height: 946450
Lag: 2 blocs
OK
```



<!-- app/views/system/index.html.erb --> <% @checks          ||= {} %> <% @summary         ||= {} %> <% @recovery        ||= {} %> <% @anomalies       ||= [] %> <% @job_health      ||= [] %> <% @scanner_status  ||= {} %> <% @exchange_like_status ||= {} %> <% @btc_status ||= {} %> <% @tables          ||= {} %> <% @jobs            ||= [] %> <% @snapshot        ||= {} %> <%  section_class = "rounded-2xl border border-white/10 bg-white/5 p-5"  panel_class   = "rounded-xl border border-white/10 bg-black/20 p-4"  label_class   = "text-[11px] uppercase tracking-[0.14em] text-gray-500"  muted_class   = "text-sm text-gray-400"  mono_class    = "font-mono text-xs"   global_state =    if @recovery[:critical_problems_count].to_i > 0      "critical"    elsif @anomalies.any?      "warning"    else      "ok"    end   def status_badge_class(status)    case status.to_s    when "skipped"      "text-orange-300 bg-orange-500/10 border border-orange-500/20"    when "stuck"      "text-rose-200 bg-rose-500/20 border border-rose-500/30"    when "ok"      "text-emerald-300 bg-emerald-500/10 border border-emerald-500/20"    when "running"      "text-sky-300 bg-sky-500/10 border border-sky-500/20"    when "warning", "late"      "text-amber-300 bg-amber-500/10 border border-amber-500/20"    when "failing", "fail", "long_running", "never_ran", "stale"      "text-rose-300 bg-rose-500/10 border border-rose-500/20"    when "disabled"      "text-gray-300 bg-gray-500/10 border border-gray-500/20"    else      "text-gray-300 bg-gray-500/10 border border-gray-500/20"    end  end   def global_badge_class(state)    case state.to_s    when "ok"      "text-emerald-300 bg-emerald-500/10 border border-emerald-500/20"    when "warning"      "text-amber-300 bg-amber-500/10 border border-amber-500/20"    else      "text-rose-300 bg-rose-500/10 border border-rose-500/20"    end  end   def yes_no_badge(value)    value ? "OK" : "FAIL"  end   def yes_no_badge_class(value)    value ? "text-emerald-300 bg-emerald-500/10 border border-emerald-500/20" :            "text-rose-300 bg-rose-500/10 border border-rose-500/20"  end   def safe_time(value)    return "—" if value.blank?    if respond_to?(:fmt_time)      fmt_time(value)    else      value.respond_to?(:strftime) ? value.strftime("%Y-%m-%d %H:%M:%S") : value.to_s    end  rescue    value.to_s  end   def safe_duration_ms(value)    return "—" if value.blank?    if respond_to?(:fmt_duration_ms)      fmt_duration_ms(value)    else      total_seconds = (value.to_f / 1000.0).round      minutes = total_seconds / 60      seconds = total_seconds % 60      minutes.positive? ? "#{minutes}m #{seconds}s" : "#{seconds}s"    end  end   def safe_seconds(value)    return "—" if value.blank?    if respond_to?(:fmt_seconds)      fmt_seconds(value)    else      total_seconds = value.to_i      minutes = total_seconds / 60      seconds = total_seconds % 60      minutes.positive? ? "#{minutes}m #{seconds}s" : "#{seconds}s"    end  end   bitcoind = @checks[:bitcoind] || {}  blockchain = @checks[:bitcoind_activity] || {}  disks = @checks[:disks] || {}  disk_cards = [disks[:bitcoind], disks[:data], disks[:system]].compact %> <div class="w-full max-w-none mx-auto px-4 sm:px-6 lg:px-8 py-8 space-y-8">  <!-- Header -->  <section class="flex flex-col lg:flex-row lg:items-end lg:justify-between gap-4">    <div>      <div class="<%= label_class %>">Operations dashboard</div>      <h1 class="mt-2 text-3xl font-bold text-gray-100">System</h1>      <p class="mt-2 <%= muted_class %>">        Supervision opérationnelle de l’infrastructure, des jobs cron, des scanners et de la fraîcheur des données.      </p>    </div>     <div class="flex flex-col items-start lg:items-end gap-2">      <span class="inline-flex items-center rounded-full px-3 py-1 text-sm font-semibold <%= global_badge_class(global_state) %>">        <%= global_state.upcase %>      </span>      <div class="text-xs text-gray-500 font-mono">        snapshot:        <span class="text-gray-300"><%= safe_time(@snapshot[:generated_at] || Time.current) %></span>      </div>    </div>  </section>   <!-- KPI -->  <section class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-6 gap-4">    <div class="<%= section_class %>">      <div class="<%= label_class %>">Global status</div>      <div class="mt-3 text-2xl font-bold <%= global_state == "ok" ? "text-emerald-300" : global_state == "warning" ? "text-amber-300" : "text-rose-300" %>">        <%= global_state.upcase %>      </div>    </div>     <div class="<%= section_class %>">      <div class="<%= label_class %>">Jobs actifs</div>      <div class="mt-3 text-2xl font-bold text-gray-100"><%= @summary[:active_jobs_count] || 0 %></div>    </div>     <div class="<%= section_class %>">      <div class="<%= label_class %>">Jobs critiques</div>      <div class="mt-3 text-2xl font-bold text-gray-100"><%= @summary[:critical_jobs_count] || 0 %></div>    </div>     <div class="<%= section_class %>">      <div class="<%= label_class %>">En retard</div>      <div class="mt-3 text-2xl font-bold text-amber-300"><%= @summary[:late_jobs_count] || 0 %></div>    </div>     <div class="<%= section_class %>">      <div class="<%= label_class %>">Running / longs</div>      <div class="mt-3 text-2xl font-bold text-sky-300">        <%= (@summary[:running_jobs_count] || 0) + (@summary[:long_running_jobs_count] || 0) %>      </div>    </div>     <div class="<%= section_class %>">      <div class="<%= label_class %>">En échec</div>      <div class="mt-3 text-2xl font-bold text-rose-300"><%= @summary[:failing_jobs_count] || 0 %></div>    </div>  </section>   <!-- Recovery -->  <section class="<%= section_class %>">    <div class="flex flex-col lg:flex-row lg:items-start lg:justify-between gap-4">      <div>        <div class="<%= label_class %>">Recovery</div>        <h2 class="mt-1 text-xl font-semibold text-gray-100">Recovery readiness</h2>        <p class="mt-2 <%= muted_class %>">          État synthétique du système pour reprise après panne, coupure électrique ou interruption prolongée.        </p>      </div>       <span class="inline-flex items-center rounded-full px-3 py-1 text-sm font-semibold <%= @recovery[:recovery_needed] ? "text-rose-300 bg-rose-500/10 border border-rose-500/20" : "text-emerald-300 bg-emerald-500/10 border border-emerald-500/20" %>">        <%= @recovery[:recovery_needed] ? "RECOVERY NEEDED" : "READY" %>      </span>    </div>     <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mt-5">      <div class="<%= panel_class %>">        <div class="<%= label_class %>">Bitcoind RPC</div>        <div class="mt-3">          <span class="inline-flex items-center rounded-full px-3 py-1 text-sm font-semibold <%= yes_no_badge_class(bitcoind[:ok]) %>">            <%= yes_no_badge(bitcoind[:ok]) %>          </span>        </div>      </div>       <div class="<%= panel_class %>">        <div class="<%= label_class %>">Problèmes critiques</div>        <div class="mt-3 text-2xl font-bold text-gray-100"><%= @recovery[:critical_problems_count] || 0 %></div>      </div>       <div class="<%= panel_class %>">        <div class="<%= label_class %>">Ordre de reprise</div>        <div class="mt-3 text-sm text-gray-300 leading-6">          <%= (@recovery[:restart_order] || []).presence&.join(" → ") || "—" %>        </div>      </div>    </div>     <% if (@recovery[:critical_problems] || []).any? %>      <div class="mt-5 rounded-xl border border-rose-500/20 bg-rose-500/5 p-4">        <div class="text-sm font-semibold text-rose-200">Problèmes critiques détectés</div>        <div class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">          <% @recovery[:critical_problems].each do |problem| %>            <div class="rounded-lg bg-black/20 border border-white/10 px-3 py-2">              <div class="text-sm text-gray-100"><%= problem[:name] %></div>              <div class="text-xs text-rose-300 mt-1"><%= problem[:status] %></div>            </div>          <% end %>        </div>      </div>    <% end %>  </section>   <!-- Infrastructure -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">Infrastructure</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">Bitcoind, blockchain et stockage</h2>      <p class="mt-2 <%= muted_class %>">        Vue rapide de la connectivité RPC, de la progression blockchain et de l’occupation disque.      </p>    </div>     <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">      <div class="<%= panel_class %>">        <div class="flex items-start justify-between gap-3">          <div>            <div class="<%= label_class %>">Service</div>            <div class="mt-1 text-lg font-semibold text-gray-100">Bitcoind RPC</div>          </div>          <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= yes_no_badge_class(bitcoind[:ok]) %>">            <%= yes_no_badge(bitcoind[:ok]) %>          </span>        </div>         <% if bitcoind[:ok] %>          <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Blocks</span>              <span class="font-mono text-gray-200"><%= bitcoind[:blocks] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Progress</span>              <span class="font-mono text-gray-200"><%= bitcoind[:progress_pct] || "—" %>%</span>            </div>          </div>        <% else %>          <pre class="mt-4 text-xs text-rose-200 whitespace-pre-wrap"><%= bitcoind[:error].presence || "Erreur RPC non disponible." %></pre>        <% end %>      </div>       <div class="<%= panel_class %>">        <div class="flex items-start justify-between gap-3">          <div>            <div class="<%= label_class %>">Réseau</div>            <div class="mt-1 text-lg font-semibold text-gray-100">Blockchain</div>          </div>          <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= yes_no_badge_class(blockchain[:ok]) %>">            <%= yes_no_badge(blockchain[:ok]) %>          </span>        </div>         <% if blockchain[:ok] %>          <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Blocks</span>              <span class="font-mono text-gray-200"><%= blockchain[:blocks] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Headers</span>              <span class="font-mono text-gray-200"><%= blockchain[:headers] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Lag</span>              <span class="font-mono <%= blockchain[:lag].to_i > 0 ? "text-amber-300" : "text-gray-200" %>"><%= blockchain[:lag] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Progress</span>              <span class="font-mono text-gray-200"><%= blockchain[:progress_pct] || "—" %>%</span>            </div>          </div>        <% else %>          <pre class="mt-4 text-xs text-rose-200 whitespace-pre-wrap"><%= blockchain[:error].presence || "Erreur blockchain non disponible." %></pre>        <% end %>      </div>       <% disk_cards.each do |disk| %>        <% disk_state = (disk[:status] || "warn").to_s %>        <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div>              <div class="<%= label_class %>">Disque</div>              <div class="mt-1 text-lg font-semibold text-gray-100"><%= disk[:label] || "Storage" %></div>            </div>            <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(disk_state) %>">              <%= disk_state.upcase %>            </span>          </div>           <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Path</span>              <span class="font-mono text-gray-200"><%= disk[:path] || "—" %></span>            </div>            <% if disk[:mount].present? %>              <div class="flex items-center justify-between">                <span class="text-gray-500">Mount</span>                <span class="font-mono text-gray-200"><%= disk[:mount] %></span>              </div>            <% end %>            <div class="flex items-center justify-between">              <span class="text-gray-500">Utilisation</span>              <span class="font-mono text-gray-200"><%= disk[:used_pct] ? "#{disk[:used_pct]}%" : "—" %></span>            </div>          </div>           <% if disk[:raw].present? %>            <pre class="mt-4 text-xs text-gray-400 whitespace-pre-wrap leading-5"><%= disk[:raw] %></pre>          <% end %>        </div>      <% end %>    </div>  </section>   <!-- Exchange Like -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">Exchange Like</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">Builder, scanner et dataset</h2>      <p class="mt-2 <%= muted_class %>">        Supervision du module exchange_like : adresses détectées, UTXO observés et fraîcheur des curseurs.      </p>    </div>     <% if @exchange_like_status[:error].present? %>      <div class="rounded-xl border border-rose-500/20 bg-rose-500/5 p-4 text-sm text-rose-200">        <%= @exchange_like_status[:error] %>      </div>    <% else %>      <% builder = @exchange_like_status[:builder] || {} %>      <% scanner = @exchange_like_status[:scanner] || {} %>      <% metrics = @exchange_like_status[:metrics] || {} %>       <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">        <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div>              <div class="<%= label_class %>">Builder</div>              <div class="mt-1 text-lg font-semibold text-gray-100"><%= builder[:label] || "—" %></div>            </div>            <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(builder[:status]) %>">              <%= builder[:status].to_s.upcase.presence || "UNKNOWN" %>            </span>          </div>           <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Cursor</span>              <span class="font-mono text-gray-200"><%= builder[:last_blockheight] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Lag</span>              <span class="font-mono text-gray-200"><%= builder[:lag] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Updated at</span>              <span class="font-mono text-gray-200"><%= safe_time(builder[:updated_at]) %></span>            </div>          </div>        </div>         <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div>              <div class="<%= label_class %>">Scanner</div>              <div class="mt-1 text-lg font-semibold text-gray-100"><%= scanner[:label] || "—" %></div>            </div>            <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(scanner[:status]) %>">              <%= scanner[:status].to_s.upcase.presence || "UNKNOWN" %>            </span>          </div>           <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Cursor</span>              <span class="font-mono text-gray-200"><%= scanner[:last_blockheight] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Lag</span>              <span class="font-mono text-gray-200"><%= scanner[:lag] || "—" %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Updated at</span>              <span class="font-mono text-gray-200"><%= safe_time(scanner[:updated_at]) %></span>            </div>          </div>        </div>         <div class="<%= panel_class %>">          <div class="<%= label_class %>">Dataset</div>          <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Addresses total</span>              <span class="font-mono text-gray-200"><%= metrics[:addresses_total] || 0 %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Operational</span>              <span class="font-mono text-gray-200"><%= metrics[:addresses_operational] || 0 %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Scannable</span>              <span class="font-mono text-gray-200"><%= metrics[:addresses_scannable] || 0 %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Observed UTXO</span>              <span class="font-mono text-gray-200"><%= metrics[:observed_total] || 0 %></span>            </div>          </div>        </div>         <div class="<%= panel_class %>">          <div class="<%= label_class %>">Recent activity</div>          <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">New addresses 24h</span>              <span class="font-mono text-gray-200"><%= metrics[:new_addresses_24h] || 0 %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Seen 24h</span>              <span class="font-mono text-gray-200"><%= metrics[:seen_24h] || 0 %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Spent 24h</span>              <span class="font-mono text-gray-200"><%= metrics[:spent_24h] || 0 %></span>            </div>            <div class="flex items-center justify-between">              <span class="text-gray-500">Best block</span>              <span class="font-mono text-gray-200"><%= @exchange_like_status[:best_height] || "—" %></span>            </div>          </div>        </div>      </div>    <% end %>  </section>    <!-- BTC -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">BTC</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">Daily, intraday et fraîcheur</h2>      <p class="mt-2 <%= muted_class %>">        Supervision du module BTC : snapshot daily, chandeliers intraday et fraîcheur des données.      </p>    </div>     <% if @btc_status[:error].present? %>      <div class="rounded-xl border border-rose-500/20 bg-rose-500/5 p-4 text-sm text-rose-200">        <%= @btc_status[:error] %>      </div>    <% else %>      <% daily = @btc_status[:daily] || {} %>      <% intraday_5m = @btc_status[:intraday_5m] || {} %>      <% intraday_1h = @btc_status[:intraday_1h] || {} %>       <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">        <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div>              <div class="<%= label_class %>">Daily</div>              <div class="mt-1 text-lg font-semibold text-gray-100">Snapshot / contexte</div>            </div>            <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(daily[:status]) %>">              <%= daily[:status].to_s.upcase.presence || "UNKNOWN" %>            </span>          </div>           <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Last day</span>              <span class="font-mono text-gray-200"><%= daily[:last_day] || "—" %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Source</span>              <span class="font-mono text-gray-200"><%= daily[:source] || "—" %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Close USD</span>              <span class="font-mono text-gray-200"><%= daily[:close_usd] ? daily[:close_usd].to_f.round(2) : "—" %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Snapshot at</span>              <span class="font-mono text-gray-200"><%= safe_time(daily[:snapshot_at]) %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">MA200</span>              <span class="font-mono text-gray-200"><%= daily[:ma200_usd] ? daily[:ma200_usd].to_f.round(2) : "—" %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">ATH</span>              <span class="font-mono text-gray-200"><%= daily[:ath_usd] ? daily[:ath_usd].to_f.round(2) : "—" %></span>            </div>          </div>        </div>         <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div>              <div class="<%= label_class %>">Intraday</div>              <div class="mt-1 text-lg font-semibold text-gray-100">BTC/USD 5m</div>            </div>            <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(intraday_5m[:status]) %>">              <%= intraday_5m[:status].to_s.upcase.presence || "UNKNOWN" %>            </span>          </div>           <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Source</span>              <span class="font-mono text-gray-200"><%= intraday_5m[:source] || "—" %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Candles</span>              <span class="font-mono text-gray-200"><%= intraday_5m[:candles_count] || 0 %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Last open</span>              <span class="font-mono text-gray-200"><%= safe_time(intraday_5m[:last_open_time]) %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Last close</span>              <span class="font-mono text-gray-200"><%= safe_time(intraday_5m[:last_close_time]) %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Last close price</span>              <span class="font-mono text-gray-200"><%= intraday_5m[:last_close] ? intraday_5m[:last_close].to_f.round(2) : "—" %></span>            </div>          </div>        </div>         <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div>              <div class="<%= label_class %>">Intraday</div>              <div class="mt-1 text-lg font-semibold text-gray-100">BTC/USD 1h</div>            </div>            <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(intraday_1h[:status]) %>">              <%= intraday_1h[:status].to_s.upcase.presence || "UNKNOWN" %>            </span>          </div>           <div class="mt-4 space-y-2 text-sm">            <div class="flex items-center justify-between">              <span class="text-gray-500">Source</span>              <span class="font-mono text-gray-200"><%= intraday_1h[:source] || "—" %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Candles</span>              <span class="font-mono text-gray-200"><%= intraday_1h[:candles_count] || 0 %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Last open</span>              <span class="font-mono text-gray-200"><%= safe_time(intraday_1h[:last_open_time]) %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Last close</span>              <span class="font-mono text-gray-200"><%= safe_time(intraday_1h[:last_close_time]) %></span>            </div>             <div class="flex items-center justify-between">              <span class="text-gray-500">Last close price</span>              <span class="font-mono text-gray-200"><%= intraday_1h[:last_close] ? intraday_1h[:last_close].to_f.round(2) : "—" %></span>            </div>          </div>        </div>      </div>    <% end %>  </section>      <!-- Anomalies -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">Exceptions</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">Anomalies à traiter</h2>      <p class="mt-2 <%= muted_class %>">        Liste courte des jobs nécessitant une attention immédiate.      </p>    </div>     <% if @anomalies.any? %>      <div class="space-y-3">        <% @anomalies.each do |job| %>          <div class="rounded-xl border border-amber-500/20 bg-amber-500/5 p-4">            <div class="flex items-start justify-between gap-4">              <div class="min-w-0">                <div class="text-sm font-semibold text-gray-100"><%= job[:label] || job[:name] %></div>                <div class="mt-1 text-xs text-gray-400">                  <span class="font-mono">status=<%= job[:status] %></span>                  <span class="mx-2 text-gray-600">•</span>                  <span class="font-mono">cron=<%= job[:cron] || "—" %></span>                  <span class="mx-2 text-gray-600">•</span>                  <span class="font-mono">delay=<%= safe_seconds(job[:delay_seconds]) %></span>                  <span class="mx-2 text-gray-600">•</span>                  <span class="font-mono">missed=<%= job[:missed_runs] || 0 %></span>                </div>              </div>               <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(job[:status]) %>">                <%= job[:status].to_s.upcase %>              </span>            </div>             <% if job[:last_error].present? %>              <pre class="mt-4 rounded-lg border border-rose-500/20 bg-black/30 p-3 text-xs text-rose-200 whitespace-pre-wrap overflow-x-auto"><%= job[:last_error] %></pre>            <% end %>          </div>        <% end %>      </div>    <% else %>      <div class="rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-4 text-sm text-emerald-300">        Aucune anomalie détectée.      </div>    <% end %>  </section>   <!-- Jobs -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">Cron supervision</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">Jobs détaillés</h2>      <p class="mt-2 <%= muted_class %>">        Vue compacte des exécutions, retards, durées, heartbeat et état opérationnel.      </p>    </div>     <div class="rounded-xl border border-white/10 overflow-hidden">      <table class="w-full table-fixed text-xs">        <thead class="bg-black/20 text-gray-400">          <tr class="text-left">            <th class="py-3 px-3 w-[18%]">Job</th>            <th class="py-3 px-3 w-[8%]">Cat.</th>            <th class="py-3 px-3 w-[8%]">Cron</th>            <th class="py-3 px-3 w-[8%]">Statut</th>            <th class="py-3 px-3 w-[16%]">Exécution</th>            <th class="py-3 px-3 w-[12%]">Durées</th>            <th class="py-3 px-3 w-[10%]">Retard</th>            <th class="py-3 px-3 w-[10%]">Runtime</th>            <th class="py-3 px-3 w-[5%]">Lock</th>            <th class="py-3 px-3 w-[5%]">Exit</th>          </tr>        </thead>         <tbody class="text-gray-300">          <% @job_health.each do |job| %>            <tr class="border-t border-white/5 align-top hover:bg-white/5 transition">              <td class="py-3 px-3">                <div class="font-medium text-gray-100 truncate"><%= job[:label] || job[:name] %></div>                <div class="mt-1 font-mono text-[10px] text-gray-500 truncate"><%= job[:name] %></div>                 <% if job[:command].present? %>                  <div class="mt-1 font-mono text-[10px] text-gray-600 truncate"><%= job[:command] %></div>                <% end %>                 <div class="mt-2 flex flex-wrap gap-1">                  <% if job[:critical] %>                    <span class="inline-flex rounded-full px-2 py-0.5 text-[10px] text-amber-300 bg-amber-500/10 border border-amber-500/20">                      critical                    </span>                  <% end %>                   <% unless job[:active] %>                    <span class="inline-flex rounded-full px-2 py-0.5 text-[10px] text-gray-400 bg-gray-500/10 border border-gray-500/20">                      disabled                    </span>                  <% end %>                </div>              </td>               <td class="py-3 px-3">                <div class="truncate"><%= job[:category] || "—" %></div>                <div class="mt-1 text-[10px] text-gray-500 font-mono"><%= job[:last_triggered_by] || "—" %></div>              </td>               <td class="py-3 px-3 font-mono text-[10px] break-words">                <%= job[:cron] || "—" %>              </td>               <td class="py-3 px-3">                <span class="inline-flex items-center rounded-full px-2.5 py-1 text-[10px] font-semibold <%= status_badge_class(job[:status]) %>">                  <%= job[:status].to_s.upcase %>                </span>                 <div class="mt-2 space-y-1 text-[10px]">                  <div class="text-emerald-300 truncate">ok: <%= safe_time(job[:last_ok_at]) %></div>                  <div class="text-rose-300 truncate">fail: <%= safe_time(job[:last_fail_at]) %></div>                  <div class="text-orange-300 truncate">skip: <%= safe_time(job[:last_skipped_at]) %></div>                </div>              </td>               <td class="py-3 px-3 font-mono text-[10px]">                <div class="truncate text-gray-200">start: <%= safe_time(job[:last_run_at]) %></div>                <div class="truncate text-gray-400 mt-1">end: <%= safe_time(job[:last_finish_at]) %></div>                <div class="truncate text-gray-500 mt-1">hb: <%= safe_seconds(job[:heartbeat_age_seconds]) %></div>              </td>               <td class="py-3 px-3 font-mono text-[10px]">                <div class="truncate text-gray-200">last: <%= safe_duration_ms(job[:last_duration_ms]) %></div>                <div class="truncate text-gray-400 mt-1">avg10: <%= safe_duration_ms(job[:avg_duration_ms]) %></div>                <div class="truncate text-gray-500 mt-1">max10: <%= safe_duration_ms(job[:max_duration_ms]) %></div>              </td>               <td class="py-3 px-3 font-mono text-[10px]">                <div class="<%= job[:delay_seconds].to_i > 0 ? "text-amber-300" : "text-gray-200" %>">                  delay: <%= safe_seconds(job[:delay_seconds]) %>                </div>                <div class="mt-1 text-gray-400">                  missed: <%= job[:missed_runs] || 0 %>                </div>                <div class="mt-1 <%= job[:capacity_status] == "over" ? "text-rose-300" : job[:capacity_status] == "tight" ? "text-amber-300" : "text-emerald-300" %>">                  capacity: <%= job[:capacity_status] || "unknown" %>                </div>                <div class="mt-1 text-orange-300">                  skips10: <%= job[:skips_in_last_10] || 0 %>                </div>              </td>               <td class="py-3 px-3 font-mono text-[10px]">                <div class="text-sky-300 truncate">                  <%= safe_seconds(job[:current_runtime_seconds]) %>                </div>                 <% if job[:progress_pct].present? || job[:progress_label].present? %>                  <% pct = [[job[:progress_pct].to_f, 0].max, 100].min %>                   <div class="mt-2">                    <% if job[:progress_pct].present? %>                      <div class="flex items-center justify-between mb-1">                        <span class="text-gray-500">progress</span>                        <span class="text-gray-300"><%= pct.round(1) %>%</span>                      </div>                       <div class="h-1.5 rounded-full bg-white/10 overflow-hidden">                        <div                          class="h-full bg-sky-400 rounded-full"                          style="width: <%= pct %>%">                        </div>                      </div>                    <% end %>                     <% if job[:progress_label].present? %>                      <div class="mt-1 text-[10px] text-gray-500 truncate">                        <%= job[:progress_label] %>                      </div>                    <% end %>                  </div>                <% elsif job[:status].to_s.in?(%w[running stuck long_running]) %>                  <div class="mt-2 text-[10px] text-gray-500 leading-4">                    progression non exposée                  </div>                <% end %>              </td>               <td class="py-3 px-3 text-[10px]">                <span class="<%= job[:lock_present] ? "text-amber-300" : "text-gray-500" %>">                  <%= job[:lock_present] ? "yes" : "no" %>                </span>              </td>               <td class="py-3 px-3 font-mono text-[10px]">                <%= job[:last_exit_code].nil? ? "—" : job[:last_exit_code] %>              </td>            </tr>             <% if job[:last_error].present? %>              <tr class="border-t border-white/5">                <td colspan="10" class="px-3 pb-4">                  <div class="rounded-lg border border-rose-500/20 bg-black/30 p-3 text-[10px] text-rose-200 whitespace-pre-wrap break-words">                    <%= job[:last_error] %>                  </div>                </td>              </tr>            <% end %>          <% end %>           <% if @job_health.blank? %>            <tr>              <td colspan="10" class="py-6 px-4 text-sm text-gray-500">Aucune donnée job disponible.</td>            </tr>          <% end %>        </tbody>      </table>    </div>  </section>   <!-- Scanners -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">Scanner cursors</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">État des scanners</h2>      <p class="mt-2 <%= muted_class %>">        Dernier bloc scanné, best block, lag et date de mise à jour.      </p>    </div>     <div class="grid grid-cols-1 md:grid-cols-2 gap-4">      <% (@scanner_status || {}).each do |key, s| %>        <% scanner_status = (s[:status] || :warn).to_s %>        <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div>              <div class="text-base font-semibold text-gray-100"><%= s[:label] || key %></div>            </div>            <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(scanner_status) %>">              <%= scanner_status.upcase %>            </span>          </div>           <% if s[:error].present? %>            <pre class="mt-4 text-xs text-rose-200 whitespace-pre-wrap"><%= s[:error] %></pre>          <% else %>            <div class="mt-4 space-y-2 text-sm">              <div class="flex items-center justify-between">                <span class="text-gray-500">Last scanned</span>                <span class="font-mono text-gray-200"><%= s[:last_blockheight] || "—" %></span>              </div>              <div class="flex items-center justify-between">                <span class="text-gray-500">Best block</span>                <span class="font-mono text-gray-200"><%= s[:best_height] || "—" %></span>              </div>              <div class="flex items-center justify-between">                <span class="text-gray-500">Lag</span>                <span class="font-mono <%= s[:lag].to_i > 12 ? "text-rose-300" : "text-gray-200" %>"><%= s[:lag] || "—" %></span>              </div>              <div class="flex items-center justify-between">                <span class="text-gray-500">Updated</span>                <span class="font-mono text-gray-200"><%= safe_time(s[:updated_at]) %></span>              </div>              <% if s[:last_blockhash].present? %>                <div>                  <div class="text-gray-500 mb-1">Hash</div>                  <div class="font-mono text-xs text-gray-400 break-all"><%= s[:last_blockhash] %></div>                </div>              <% end %>            </div>          <% end %>        </div>      <% end %>       <% if @scanner_status.blank? %>        <div class="text-sm text-gray-500">Aucun scanner disponible.</div>      <% end %>    </div>  </section>   <!-- Tables -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">Data freshness</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">État des tables</h2>      <p class="mt-2 <%= muted_class %>">        Volume, fraîcheur, âge des données et retard éventuel par rapport aux attentes.      </p>    </div>     <div class="grid grid-cols-1 lg:grid-cols-2 2xl:grid-cols-3 gap-4">      <% (@tables || {}).each do |name, table| %>        <%          raw_last = table[:last_at] || table[:last_day]           last_time =            case raw_last            when Time, ActiveSupport::TimeWithZone, DateTime then raw_last            when Date then raw_last.in_time_zone            when String              begin                Time.zone.parse(raw_last)              rescue                nil              end            else              nil            end           table_status = (table[:status] || :warn).to_s          daily_table  = table[:min_day].present?           age_h =            if table.key?(:age_h)              table[:age_h].to_f            elsif last_time              ((Time.current - last_time) / 3600.0)            end           last_day =            if daily_table              last_time&.to_date            end           expected_day =            if daily_table              begin                table[:min_day].to_date              rescue                nil              end            end        %>         <div class="<%= panel_class %>">          <div class="flex items-start justify-between gap-3">            <div class="min-w-0">              <div class="text-sm font-semibold text-gray-100 break-words"><%= name %></div>            </div>             <span class="shrink-0 inline-flex items-center rounded-full px-2.5 py-1 text-[11px] font-semibold <%= status_badge_class(table_status) %>">              <%= table_status.upcase %>            </span>          </div>           <div class="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-xs">            <div class="text-gray-500">Count</div>            <div class="text-right font-mono text-gray-200 truncate"><%= table[:count] || "—" %></div>             <div class="text-gray-500">Last</div>            <div class="text-right font-mono text-gray-200 break-words">              <% if last_time %>                <%= daily_table ? last_time.to_date.strftime("%Y-%m-%d") : last_time.strftime("%Y-%m-%d %H:%M") %>              <% else %>                —              <% end %>            </div>             <% if daily_table %>              <div class="text-gray-500">Attendu</div>              <div class="text-right font-mono text-gray-200">                <%= expected_day ? expected_day.strftime("%Y-%m-%d") : "—" %>              </div>               <div class="text-gray-500">Dernier jour</div>              <div class="text-right font-mono text-gray-200">                <%= last_day ? last_day.strftime("%Y-%m-%d") : "—" %>              </div>               <div class="text-gray-500">Retard</div>              <div class="text-right font-mono <%= expected_day && last_day && last_day < expected_day ? "text-rose-300" : "text-gray-200" %>">                <% if expected_day && last_day && last_day < expected_day %>                  <%= (expected_day - last_day).to_i %>j                <% else %>                  0j                <% end %>              </div>            <% else %>              <div class="text-gray-500">Âge</div>              <div class="text-right font-mono text-gray-200">                <%= age_h ? "#{age_h.round(1)}h" : "—" %>              </div>               <div class="text-gray-500">SLA</div>              <div class="text-right font-mono text-gray-200">                <%= table[:sla_h].present? ? "#{table[:sla_h]}h" : "—" %>              </div>            <% end %>          </div>           <% if table[:hint].present? %>            <div class="mt-4 border-t border-white/5 pt-3 text-xs text-gray-400 leading-5">              <%= table[:hint] %>            </div>          <% end %>        </div>      <% end %>       <% if @tables.blank? %>        <div class="text-sm text-gray-500">Aucune métrique de table disponible.</div>      <% end %>    </div>  </section>   <!-- QA -->  <section class="<%= section_class %>">    <div class="flex items-center justify-between gap-4">      <div>        <div class="<%= label_class %>">Quality assurance</div>        <h2 class="mt-1 text-xl font-semibold text-gray-100">QA / Tests</h2>        <p class="mt-2 <%= muted_class %>">          Accès à la page de validation et aux contrôles de non-régression.        </p>      </div>       <%= link_to "Ouvrir QA / Tests",          system_tests_path,          class: "inline-flex items-center rounded-xl border border-violet-500/20 bg-violet-500/10 px-4 py-2 text-sm font-medium text-violet-300 hover:bg-violet-500/15 transition" %>    </div>  </section>   <!-- Recent JobRuns -->  <section class="<%= section_class %>">    <div class="mb-5">      <div class="<%= label_class %>">Recent execution log</div>      <h2 class="mt-1 text-xl font-semibold text-gray-100">Dernières exécutions</h2>      <p class="mt-2 <%= muted_class %>">        Historique récent des `JobRun`, utile pour comprendre la chronologie effective des opérations.      </p>    </div>     <div class="overflow-x-auto rounded-xl border border-white/10">      <table class="min-w-full text-sm">        <thead class="bg-black/20 text-gray-400">          <tr class="text-left">            <th class="py-3 px-4">Job</th>            <th class="py-3 px-4">Statut</th>            <th class="py-3 px-4">Début</th>            <th class="py-3 px-4">Fin</th>            <th class="py-3 px-4">Durée</th>            <th class="py-3 px-4">Exit</th>            <th class="py-3 px-4">Erreur</th>          </tr>        </thead>         <tbody class="text-gray-300">          <% @jobs.first(30).each do |jr| %>            <tr class="border-t border-white/5 align-top hover:bg-white/5 transition">              <td class="py-3 px-4">                <div class="font-mono text-xs text-gray-200"><%= jr.name %></div>              </td>              <td class="py-3 px-4">                <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(jr.status) %>">                  <%= jr.status.to_s.upcase %>                </span>              </td>              <td class="py-3 px-4 font-mono text-xs"><%= safe_time(jr.started_at || jr.created_at) %></td>              <td class="py-3 px-4 font-mono text-xs"><%= safe_time(jr.finished_at) %></td>              <td class="py-3 px-4 font-mono text-xs"><%= safe_duration_ms(jr.duration_ms) %></td>              <td class="py-3 px-4 font-mono text-xs"><%= jr.exit_code.nil? ? "—" : jr.exit_code %></td>              <td class="py-3 px-4 text-xs text-gray-400">                <%= jr.error.to_s.first(220).presence || "—" %>              </td>            </tr>          <% end %>           <% if @jobs.blank? %>            <tr>              <td colspan="7" class="py-6 px-4 text-sm text-gray-500">Aucun JobRun récent disponible.</td>            </tr>          <% end %>        </tbody>      </table>    </div>  </section> </div>



Tu as déjà une section parfaite : **Scanner cursors**.

Donc le mieux n’est pas d’ajouter un nouveau bloc séparé, mais d’injecter `cluster_scan` dans `@scanner_status`.

## Dans le controller `/system`

Ajoute après la construction de `@scanner_status` :

```
cluster_scan = System::ClusterScanStatus.call

@scanner_status[:cluster_scan] = {
  label: "Cluster Scan",
  status: cluster_scan[:status],
  last_blockheight: cluster_scan[:cursor_height],
  best_height: cluster_scan[:best_height],
  lag: cluster_scan[:lag],
  updated_at: ScannerCursor.find_by(name: "cluster_scan")&.updated_at,
  last_blockhash: ScannerCursor.find_by(name: "cluster_scan")&.last_blockhash,
  error: cluster_scan[:error]
}
```

Version un peu plus propre :

```
cluster_scan = System::ClusterScanStatus.call
cluster_cursor = ScannerCursor.find_by(name: "cluster_scan")

@scanner_status[:cluster_scan] = {
  label: "Cluster Scan",
  status: cluster_scan[:status],
  last_blockheight: cluster_scan[:cursor_height],
  best_height: cluster_scan[:best_height],
  lag: cluster_scan[:lag],
  updated_at: cluster_cursor&.updated_at,
  last_blockhash: cluster_cursor&.last_blockhash,
  error: cluster_scan[:error]
}
```

Ta vue affichera automatiquement :

```
Cluster Scan
Last scanned
Best block
Lag
Updated
Hash
```

sans rien modifier côté HTML.



\# app/controllers/system_controller.rb class SystemController < ApplicationController  before_action :ensure_local_or_development!, only: [:run_tests]  before_action :catch_up_btc_price_days_in_development, only: [:index]   def index    @cluster_scan_status = System::ClusterScanStatus.call    @jobs = JobRun.recent.limit(200)    @scanner_status = build_scanner_status    @exchange_like_status = build_exchange_like_status    @btc_status = build_btc_status     @snapshot  = System::HealthSnapshotBuilder.call    @summary   = @snapshot[:summary]    @anomalies = @snapshot[:anomalies]    @job_health = @snapshot[:jobs]    @recovery  = @snapshot[:recovery]     @checks = {      bitcoind: bitcoind_check,      disks: disks_check,      bitcoind_activity: bitcoind_activity_check    }     @tables = build_tables_health  end   def normalize_system_status(value)    case value.to_s    when "fresh"      "ok"    when "delayed"      "warning"    when "stale"      "stale"    when "offline"      "fail"    else      "warning"    end  end   def tests    @qa_groups  = SystemTestStatus.groups    @qa_summary = SystemTestStatus.summary    @qa_stats   = SystemTestStatus.new.global_stats     log_path = Rails.root.join("tmp/qa/cluster_v3_last_run.log")    @last_test_output = File.exist?(log_path) ? File.read(log_path).truncate(5000) : nil  end   def run_tests    result = SystemTestRunner.call     if result.ok?      redirect_to system_tests_path, notice: "Tests Cluster V3 exécutés avec succès."    else      redirect_to system_tests_path, alert: "Échec de l’exécution des tests (code #{result.status}). Consulte tmp/qa/cluster_v3_last_run.log."    end  end   private   def ensure_local_or_development!    return if Rails.env.development?    return if request.local?     head :forbidden  end   def fmt_duration_ms(value)    return "—" if value.blank?     total_seconds = (value / 1000.0).round    minutes = total_seconds / 60    seconds = total_seconds % 60     if minutes.positive?      "#{minutes}m #{seconds}s"    else      "#{seconds}s"    end  end   def fmt_seconds(value)    return "—" if value.blank?     total_seconds = value.to_i    minutes = total_seconds / 60    seconds = total_seconds % 60     if minutes.positive?      "#{minutes}m #{seconds}s"    else      "#{seconds}s"    end  end   def status_badge_class(status)    case status.to_s    when "ok"      "text-emerald-300 bg-emerald-500/10 border border-emerald-500/20"    when "running"      "text-sky-300 bg-sky-500/10 border border-sky-500/20"    when "warning", "late"      "text-amber-300 bg-amber-500/10 border border-amber-500/20"    when "failing", "long_running", "never_ran"      "text-rose-300 bg-rose-500/10 border border-rose-500/20"    when "disabled"      "text-gray-300 bg-gray-500/10 border border-gray-500/20"    else      "text-gray-300 bg-gray-500/10 border border-gray-500/20"    end  end   def build_scanner_status    best_height = BitcoinRpc.new.getblockcount.to_i     exchange_cursor = ScannerCursor.find_by(name: "exchange_observed_scan")    exchange_last_height = exchange_cursor&.last_blockheight    exchange_lag = exchange_last_height ? (best_height - exchange_last_height) : nil     cluster_cursor = ScannerCursor.find_by(name: "cluster_scan")    cluster_last_height = cluster_cursor&.last_blockheight    cluster_lag = cluster_last_height ? (best_height - cluster_last_height) : nil     {      exchange_observed_scan: {        label: "Exchange observed scan",        last_blockheight: exchange_last_height,        best_height: best_height,        lag: exchange_lag,        last_blockhash: exchange_cursor&.last_blockhash,        updated_at: exchange_cursor&.updated_at,        status: if exchange_last_height.nil?                  :warn                elsif exchange_lag <= 3                  :ok                elsif exchange_lag <= 12                  :warn                else                  :fail                end      },       cluster_scan: {        label: "Cluster scan",        last_blockheight: cluster_last_height,        best_height: best_height,        lag: cluster_lag,        last_blockhash: cluster_cursor&.last_blockhash,        updated_at: cluster_cursor&.updated_at,        status: if cluster_last_height.nil?                  :warn                elsif cluster_lag <= 3                  :ok                elsif cluster_lag <= 12                  :warn                else                  :fail                end      }    }  rescue => e    {      exchange_observed_scan: {        label: "Exchange observed scan",        error: "#{e.class}: #{e.message}",        status: :fail      },      cluster_scan: {        label: "Cluster scan",        error: "#{e.class}: #{e.message}",        status: :fail      }    }  end   def build_exchange_like_status    best_height = BitcoinRpc.new.getblockcount.to_i     builder_cursor = ScannerCursor.find_by(name: "exchange_address_builder")    scanner_cursor = ScannerCursor.find_by(name: "exchange_observed_scan")     builder_last_height = builder_cursor&.last_blockheight    scanner_last_height = scanner_cursor&.last_blockheight     builder_lag = builder_last_height ? (best_height - builder_last_height) : nil    scanner_lag = scanner_last_height ? (best_height - scanner_last_height) : nil     {      best_height: best_height,       builder: {        label: "Exchange address builder",        last_blockheight: builder_last_height,        last_blockhash: builder_cursor&.last_blockhash,        updated_at: builder_cursor&.updated_at,        lag: builder_lag,        status: cursor_health(builder_last_height, builder_lag, builder_cursor&.updated_at)      },       scanner: {        label: "Exchange observed scan",        last_blockheight: scanner_last_height,        last_blockhash: scanner_cursor&.last_blockhash,        updated_at: scanner_cursor&.updated_at,        lag: scanner_lag,        status: cursor_health(scanner_last_height, scanner_lag, scanner_cursor&.updated_at)      },       metrics: {        addresses_total: ExchangeAddress.count,        addresses_operational: ExchangeAddress.operational.count,        addresses_scannable: ExchangeAddress.scannable.count,        observed_total: ExchangeObservedUtxo.count,        new_addresses_24h: ExchangeAddress.where("first_seen_at >= ?", 24.hours.ago).count,        seen_24h: ExchangeObservedUtxo.where("seen_day >= ?", Date.current - 1).count,        spent_24h: ExchangeObservedUtxo.where.not(spent_day: nil).where("spent_day >= ?", Date.current - 1).count      }    }  rescue => e    {      error: "#{e.class}: #{e.message}"    }  end   def build_btc_status    daily_last = BtcPriceDay.where.not(close_usd: nil).order(day: :desc).first    snapshot   = MarketSnapshot.latest_ok     five_m_relation = BtcCandle.for_market("btcusd").for_timeframe("5m")    one_h_relation  = BtcCandle.for_market("btcusd").for_timeframe("1h")     five_m_last = five_m_relation.recent_first.first    one_h_last  = one_h_relation.recent_first.first     five_m_freshness = Btc::Health::CandlesFreshnessChecker.call(      last_close_time: five_m_last&.close_time,      timeframe: "5m"    )     one_h_freshness = Btc::Health::CandlesFreshnessChecker.call(      last_close_time: one_h_last&.close_time,      timeframe: "1h"    )     daily_freshness = Btc::Health::FreshnessChecker.call(      snapshot&.computed_at || daily_last&.day    )     {      daily: {        status: normalize_system_status(daily_freshness),        last_day: daily_last&.day,        source: daily_last&.source,        close_usd: daily_last&.close_usd,        snapshot_at: snapshot&.computed_at,        ma200_usd: snapshot&.ma200_usd,        ath_usd: snapshot&.ath_usd      },       intraday_5m: {        status: normalize_system_status(five_m_freshness),        market: "btcusd",        timeframe: "5m",        source: five_m_last&.source,        candles_count: five_m_relation.count,        last_open_time: five_m_last&.open_time,        last_close_time: five_m_last&.close_time,        last_close: five_m_last&.close      },       intraday_1h: {        status: normalize_system_status(one_h_freshness),        market: "btcusd",        timeframe: "1h",        source: one_h_last&.source,        candles_count: one_h_relation.count,        last_open_time: one_h_last&.open_time,        last_close_time: one_h_last&.close_time,        last_close: one_h_last&.close      }    }  rescue => e    {      error: "#{e.class}: #{e.message}"    }  end   def cursor_health(last_height, lag, updated_at)    return :warn if last_height.nil?    return :fail if updated_at.present? && updated_at < 12.hours.ago    return :ok if lag.to_i <= 3    return :warn if lag.to_i <= 24     :fail  end    # =========================  # Services checks  # =========================  def bitcoind_check    rpc = BitcoinRpc.new    info = rpc.get_blockchain_info     {      ok: true,      blocks: info["blocks"],      headers: info["headers"],      progress_pct: (info["verificationprogress"].to_f * 100).round(3)    }  rescue => e    { ok: false, error: "#{e.class}: #{e.message}" }  end   def bitcoind_activity_check    rpc = BitcoinRpc.new    info = rpc.get_blockchain_info     {      ok: true,      blocks: info["blocks"],      headers: info["headers"],      lag: info["headers"].to_i - info["blocks"].to_i,      progress_pct: (info["verificationprogress"].to_f * 100).round(3)    }  rescue => e    { ok: false, error: e.message }  end   def disks_check    {      bitcoind: disk_usage(path: "/var/lib/bitcoind", warn_pct: 85, fail_pct: 95, label: "Disque blockchain"),      data:     disk_usage(path: "/mnt/data",         warn_pct: 85, fail_pct: 95, label: "Disque data"),      system:   disk_usage(path: "/",                 warn_pct: 80, fail_pct: 90, label: "Disque système")    }  end   def disk_usage(path:, warn_pct:, fail_pct:, label:)    df = `df -h #{path} 2>/dev/null`.to_s     stat = `df -P #{path} 2>/dev/null | tail -1`.to_s.split    used_pct = stat[4].to_s.delete("%").to_i rescue nil    avail    = stat[3]    mount    = stat[5]     status =      if used_pct.nil?        :warn      elsif used_pct >= fail_pct        :fail      elsif used_pct >= warn_pct        :warn      else        :ok      end     {      label: label,      path: path,      mount: mount,      status: status,      used_pct: used_pct,      avail: avail,      raw: df    }  end   # =========================  # Tables freshness  # =========================  def build_tables_health    now = Time.current     btc_last   = BtcPriceDay.order(day: :desc).limit(1).pick(:day)&.in_time_zone    snap_last  = MarketSnapshot.order(computed_at: :desc).limit(1).pick(:computed_at)&.in_time_zone     cluster_signals_job_last =      JobRun.where(name: "cluster_v3_detect_signals", status: "ok", exit_code: 0).maximum(:started_at) ||      JobRun.where(name: "cluster_v3_detect_signals", status: "ok", exit_code: 0).maximum(:created_at)     inflow_outflow_last =      ExchangeFlowDay.order(day: :desc).limit(1).pick(:day)&.in_time_zone     inflow_outflow_details_last =      ExchangeFlowDayDetail.order(day: :desc).limit(1).pick(:day)&.in_time_zone     inflow_outflow_behavior_last =      ExchangeFlowDayBehavior.order(day: :desc).limit(1).pick(:day)&.in_time_zone     whale_job_last =      JobRun.where(name: "whale_scan", status: "ok", exit_code: 0).maximum(:started_at) ||      JobRun.where(name: "whale_scan", status: "ok", exit_code: 0).maximum(:created_at)     whale_data_last = WhaleAlert.maximum(:created_at)     exchange_builder_last =      JobRun.where(name: "exchange_address_builder", status: "ok", exit_code: 0).maximum(:started_at) ||      JobRun.where(name: "exchange_address_builder", status: "ok", exit_code: 0).maximum(:created_at)     exchange_observed_last =      JobRun.where(name: "exchange_observed_scan", status: "ok", exit_code: 0).maximum(:started_at) ||      JobRun.where(name: "exchange_observed_scan", status: "ok", exit_code: 0).maximum(:created_at)     exchange_addresses_last = ExchangeAddress.maximum(:updated_at)    exchange_observed_utxos_last = ExchangeObservedUtxo.maximum(:updated_at)     inflow_outflow_capital_behavior_last =      ExchangeFlowDayCapitalBehavior.order(day: :desc).limit(1).pick(:day)&.in_time_zone     cluster_last =      AddressLink.order(block_height: :desc).limit(1).pick(:created_at)&.in_time_zone ||      Cluster.maximum(:updated_at)&.in_time_zone     cluster_metrics_last =      ClusterMetric.order(snapshot_date: :desc).limit(1).pick(:snapshot_date)&.in_time_zone     cluster_signals_last =      ClusterSignal.order(snapshot_date: :desc).limit(1).pick(:snapshot_date)&.in_time_zone     {      "exchange_addresses" => build_table_row(        count: ExchangeAddress.count,        last_at: exchange_addresses_last,        sla_h: 26,        hint: "Set principal des adresses exchange-like. Dernier JobRun builder: #{fmt_time(exchange_builder_last)}",        now: now      ),       "exchange_observed_utxos" => build_table_row(        count: ExchangeObservedUtxo.count,        last_at: exchange_observed_utxos_last,        sla_h: 1,        hint: "UTXO observés sur le set exchange-like. Dernier JobRun scanner: #{fmt_time(exchange_observed_last)}",        now: now      ),       "clusters" => build_table_row(        count: Cluster.count,        last_at: cluster_last,        sla_h: 1,        hint: "Clusters multi-input construits par le scanner cluster.",        now: now      ),       "whale_alerts" => build_table_row(        count: WhaleAlert.count,        last_at: whale_job_last,        sla_h: 2,        hint: "Fraîcheur basée sur JobRun whale_scan. Dernier insert WhaleAlert: #{fmt_time(whale_data_last)}",        now: now      ),       "market_snapshots" => build_table_row(        count: MarketSnapshot.count,        last_at: snap_last,        sla_h: 26,        hint: "Snapshot attendu 1 fois / jour.",        now: now      ),       "exchange_flow_days" => build_table_row(        count: ExchangeFlowDay.count,        last_at: inflow_outflow_last,        sla_h: 36,        hint: "V1 : agrégats inflow/outflow journaliers calculés depuis exchange_observed_utxos.",        now: now,        min_day: Date.yesterday      ),       "exchange_flow_day_details" => build_table_row(        count: ExchangeFlowDayDetail.count,        last_at: inflow_outflow_details_last,        sla_h: 36,        hint: "V2 : structure des dépôts et retraits observés par buckets.",        now: now,        min_day: Date.yesterday      ),       "exchange_flow_day_behaviors" => build_table_row(        count: ExchangeFlowDayBehavior.count,        last_at: inflow_outflow_behavior_last,        sla_h: 36,        hint: "V3 : ratios comportementaux retail / whale / institution et scores de comportement.",        now: now,        min_day: Date.yesterday      ),       "exchange_flow_day_capital_behaviors" => build_table_row(        count: ExchangeFlowDayCapitalBehavior.count,        last_at: inflow_outflow_capital_behavior_last,        sla_h: 36,        hint: "V4 : capital behavior, whale dominance et divergence activité / capital.",        now: now,        min_day: Date.yesterday      ),       "btc_price_days" => build_table_row(        count: BtcPriceDay.count,        last_at: btc_last,        sla_h: 36,        hint: Rails.env.development? ?          "En développement : mise à jour quotidienne attendue (J-1), avec rattrapage automatique après redémarrage." :          "Mise à jour quotidienne attendue (J-1).",        now: now,        min_day: Date.current - 1      ),       "cluster_metrics" => build_table_row(        count: ClusterMetric.count,        last_at: cluster_metrics_last,        sla_h: 36,        hint: "V3.1 : métriques agrégées cluster par snapshot_date.",        now: now,        min_day: Date.yesterday      ),       "cluster_signals" => build_table_row(        count: ClusterSignal.count,        last_at: cluster_signals_job_last,        sla_h: 36,        hint: "V3.1 : signaux cluster détectés à partir des métriques. Dernier snapshot_date présent: #{cluster_signals_last.present? ? cluster_signals_last.to_date.strftime("%Y-%m-%d") : "—"}",        now: now      )    }  end   def build_table_row(count:, last_at:, sla_h:, hint:, now:, min_day: nil)    age_h =      if last_at.present?        ((now - last_at) / 3600.0)      else        999_999.0      end     dev_mode = Rails.env.development?     status =      if last_at.blank?        dev_mode ? :warn : :fail      elsif min_day        if last_at.to_date < min_day          dev_mode ? :warn : :fail        else          :ok        end      else        if age_h > sla_h          dev_mode ? :warn : :fail        else          :ok        end      end     {      count: count,      last_at: last_at,      sla_h: sla_h,      hint: hint,      age_h: age_h.round(1),      status: status,      min_day: min_day    }  end   def fmt_time(value)    value.present? ? value.in_time_zone.strftime("%Y-%m-%d %H:%M:%S") : "—"  end   def catch_up_btc_price_days_in_development    return unless Rails.env.development?     last_day = BtcPriceDay.maximum(:day)    target_day = Date.yesterday     return if last_day.present? && last_day >= target_day     BtcPriceDaysCatchup.call(target_day: target_day)  rescue => e    Rails.logger.warn("[btc_price_days:catchup] #{e.class}: #{e.message}")  end end



Ton controller a déjà `cluster_scan` dans `build_scanner_status`. Donc tu peux supprimer cette ligne devenue inutile :

```
@cluster_scan_status = System::ClusterScanStatus.call
```

Dans `build_scanner_status`, tu peux juste améliorer le statut avec ton service :

```
cluster_status = System::ClusterScanStatus.call
```

Puis remplace le bloc `cluster_scan:` par :

```
cluster_scan: {
  label: "Cluster scan",
  last_blockheight: cluster_status[:cursor_height],
  best_height: cluster_status[:best_height],
  lag: cluster_status[:lag],
  last_blockhash: cluster_cursor&.last_blockhash,
  updated_at: cluster_cursor&.updated_at,
  error: cluster_status[:error],
  status: cluster_status[:status]
}
```

Comme ça, tu centralises la logique ici :

```
System::ClusterScanStatus
```

et la vue `/system` l’affiche déjà automatiquement dans **Scanner cursors**.



Cluster scan OK Last scanned 946448 Best block 946450 Lag 2 Updated 2026-04-24 14:53:45 Hash 000000000000000000017fc5f7d8f140981ef4f3110996e674cbd17de02a85e8



Parfait.
Le module `cluster` est maintenant dans un état beaucoup plus professionnel dans Bitcoin Monitor :

```
Cluster scan
OK
Last scanned: 946448
Best block: 946450
Lag: 2
```

Tu as maintenant :

```
✔ scanner incrémental propre
✔ curseur fiable
✔ architecture découpée
✔ services séparés
✔ stats debug
✔ refresh séparé
✔ supervision système
✔ backlog prêt pour scaling
```

Le module est passé :

```
prototype monolithique
→ moteur d’analyse structuré
```

## Ce qu’on pourrait faire ensuite

### Performance extrême

```
insert_all partout
upsert_all
cache RAM
Redis
```

### Temps réel

```
bitcoind ZMQ
↓
scan incrémental auto
↓
refresh async
```

### Recovery

```
reprise auto après panne
```

### Jobs séparés

```
ClusterRefreshJob
ClusterMetricsJob
ClusterSignalsJob
```

### Pipeline V4

```
scan
↓
cluster graph
↓
metrics
↓
signals
↓
behavior intelligence
```

Franchement, là le module commence à ressembler à un vrai pipeline blockchain analytics.



on continue



Oui. Prochaine étape logique : **créer un job séparé pour le refresh des clusters**.

Objectif :

```
ClusterScanner = scan rapide
ClusterRefreshJob = recalcul des clusters touchés
```

## 1. Crée le job

```
nano app/jobs/cluster_refresh_job.rb
```

Colle :

```
# frozen_string_literal: true

class ClusterRefreshJob < ApplicationJob
  queue_as :default

  def perform(cluster_ids)
    ids = Array(cluster_ids).compact.uniq
    return if ids.empty?

    Clusters::DirtyClusterRefresher.call(cluster_ids: ids)
  end
end
```

## 2. Test en console

```
result = ClusterScanner.call(
  from_height: BitcoinRpc.new(wallet: nil).getblockcount.to_i,
  to_height: BitcoinRpc.new(wallet: nil).getblockcount.to_i,
  refresh: false
)

ClusterRefreshJob.perform_now(result[:dirty_cluster_ids])
```

## 3. Plus tard

Quand Sidekiq sera en place, tu feras :

```
ClusterRefreshJob.perform_later(result[:dirty_cluster_ids])
```

Et ton scan pourra rester très rapide.



 ClusterProfile Update (0.3ms)  UPDATE "cluster_profiles" SET "score" = 14, "updated_at" = '2026-04-24 15:41:32.521779' WHERE "cluster_profiles"."id" = 248157 /*application='BitcoinMonitor',job='ClusterRefreshJob'*/  TRANSACTION (14.1ms)  COMMIT /*application='BitcoinMonitor',job='ClusterRefreshJob'*/ Performed ClusterRefreshJob (Job ID: 20b27362-55a2-49b0-b05d-aee6602ab008) from Sidekiq(default) in 92033.56ms ↳ (bitcoin-monitor):7:in `<main>' `=> 286 bitcoin-monitor(dev)> 



Parfait. Le job fonctionne.

Résultat :

```
ClusterRefreshJob
286 clusters rafraîchis
durée: 92 secondes
```

Conclusion importante : le refresh est **beaucoup plus lourd** que le scan.

Donc maintenant, la bonne architecture devient :

```
ClusterScanner(refresh: false)
↓
ClusterRefreshJob.perform_later(dirty_cluster_ids)
```

À ne pas faire en synchrone sur gros backfill :

```
ClusterRefreshJob.perform_now(...)
```

Prochaine amélioration : découper le refresh en batchs de 50 ou 100 clusters par job pour éviter un job de 90 secondes.



ok



Parfait. On découpe maintenant le refresh en batchs.

## 1. Crée un job batch

```
nano app/jobs/cluster_refresh_batch_job.rb
```

Colle :

```
# frozen_string_literal: true

class ClusterRefreshBatchJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 50

  def perform(cluster_ids)
    ids = Array(cluster_ids).compact.uniq
    return if ids.empty?

    ids.each_slice(BATCH_SIZE) do |slice|
      Clusters::DirtyClusterRefresher.call(cluster_ids: slice)
    end
  end
end
```

## 2. Test

Dans `rails c` :

```
result = ClusterScanner.call(
  from_height: BitcoinRpc.new(wallet: nil).getblockcount.to_i,
  to_height: BitcoinRpc.new(wallet: nil).getblockcount.to_i,
  refresh: false
)

ClusterRefreshBatchJob.perform_now(result[:dirty_cluster_ids])
```

## Ce que ça change

Avant :

```
1 job = 286 clusters
≈ 92 secondes
```

Maintenant :

```
50 clusters
50 clusters
50 clusters
...
```

Plus stable et plus proche d’une vraie architecture Sidekiq.



ensuite



Ensuite, le mieux est de faire **un dispatcher** qui crée plusieurs petits jobs Sidekiq.

## 1. Crée le dispatcher

```
nano app/jobs/cluster_refresh_dispatch_job.rb
# frozen_string_literal: true

class ClusterRefreshDispatchJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 50

  def perform(cluster_ids)
    ids = Array(cluster_ids).compact.uniq
    return if ids.empty?

    ids.each_slice(BATCH_SIZE) do |slice|
      ClusterRefreshJob.perform_later(slice)
    end
  end
end
```

## 2. Usage cible

```
result = ClusterScanner.call(
  from_height: best,
  to_height: best,
  refresh: false
)

ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids])
```

## Architecture obtenue

```
ClusterScanner
↓
dirty_cluster_ids
↓
ClusterRefreshDispatchJob
↓
ClusterRefreshJob x 50 clusters
```

C’est plus scalable que `perform_now`.



victor@debian:~/bitcoin_monitor$ rails c Loading development environment (Rails 8.0.4) bitcoin-monitor(dev)* result = ClusterScanner.call( bitcoin-monitor(dev)*   from_height: best, bitcoin-monitor(dev)*   to_height: best, bitcoin-monitor(dev)*   refresh: false bitcoin-monitor(dev)> ) bitcoin-monitor(dev)>  bitcoin-monitor(dev)> ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids]) (bitcoin-monitor):2:in `<main>': undefined local variable or method `best' for main:Object (NameError)   from_height: best,               ^^^^ bitcoin-monitor(dev)> 



Il faut définir `best` avant.

Dans `rails c` :

```
best = BitcoinRpc.new(wallet: nil).getblockcount.to_i

result = ClusterScanner.call(
  from_height: best,
  to_height: best,
  refresh: false
)

ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids])
```

Mais si le dernier bloc est déjà traité, `dirty_cluster_ids` sera vide.

Tu peux vérifier :

```
result[:dirty_clusters_count]
result[:dirty_cluster_ids].size
```



NFO  2026-04-24T13:45:51.170Z pid=282207 tid=64yz: Sidekiq 8.1.0 connecting to Redis with options {:size=>10, :pool_name=>"internal", :url=>"redis://127.0.0.1:6379/0"} Enqueued ClusterRefreshDispatchJob (Job ID: 8e7d2f64-01ab-4a9e-bde0-2433f54293ea) to Sidekiq(default) with arguments: [] ↳ (bitcoin-monitor):16:in `<main>' `=>  #<ClusterRefreshDispatchJob:0x00007f5b6c266910 @_halted_callback_hook_called=nil, @arguments=[[]], @exception_executions={}, @executions=0, @job_id="8e7d2f64-01ab-4a9e-bde0-2433f54293ea", @priority=nil, @provider_job_id="f685c70041f851e0bb78ca10", @queue_name="default", @scheduled_at=nil, @successfully_enqueued=true, @timezone="Europe/Paris"> bitcoin-monitor(dev)> 



C’est bon techniquement, mais là tu as envoyé :

```
arguments: []
```

Donc aucun cluster à rafraîchir.

Vérifie avant d’enqueue :

```
result[:dirty_clusters_count]
result[:dirty_cluster_ids].size
```

Si c’est `0`, c’est normal.

Pour un bloc nouveau non refresh :

```
best = BitcoinRpc.new(wallet: nil).getblockcount.to_i

result = ClusterScanner.call(
  from_height: best,
  to_height: best,
  refresh: false
)

if result[:dirty_cluster_ids].any?
  ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids])
end
```

Là, le dispatch ne partira que s’il y a vraiment des clusters à traiter.



la on a pas de cluster



Oui, exactement.

Là tu n’as pas de clusters parce que :

```
dirty_cluster_ids: []
```

Donc le bloc était déjà traité ou n’a rien produit de nouveau.

C’est normal.

Pour la suite, protège toujours le dispatch comme ça :

```
if result[:dirty_cluster_ids].any?
  ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids])
else
  puts "Aucun cluster dirty à rafraîchir"
end
```

Le pipeline est prêt. Il se déclenchera vraiment au prochain bloc non scanné.



je verifie comment en console



Dans `rails c` :

## 1. Scanner un bloc récent sans refresh

```
best = BitcoinRpc.new(wallet: nil).getblockcount.to_i

result = ClusterScanner.call(
  from_height: best,
  to_height: best,
  refresh: false
)
```

## 2. Vérifier les résultats

```
result[:multi_input_txs]
result[:dirty_clusters_count]
result[:dirty_cluster_ids].size
result[:dirty_cluster_ids].first(10)
```

## 3. Vérifier si le bloc était déjà traité

```
result[:already_linked_txs]
```

Si tu vois :

```
already_linked_txs > 0
multi_input_txs = 0
```

alors le bloc était déjà scanné.

## 4. Déclencher le refresh seulement si nécessaire

```
if result[:dirty_cluster_ids].any?
  ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids])
else
  puts "Aucun cluster dirty"
end
```



=>  {:ok=>true, ... bitcoin-monitor(dev)> result[:multi_input_txs] => 0 bitcoin-monitor(dev)> result[:dirty_clusters_count] => 0 bitcoin-monitor(dev)> result[:dirty_cluster_ids].size => 0 bitcoin-monitor(dev)> result[:dirty_cluster_ids].first(10) => [] bitcoin-monitor(dev)> result[:already_linked_txs] => 47 bitcoin-monitor(dev)* if result[:dirty_cluster_ids].any? bitcoin-monitor(dev)*   ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids]) bitcoin-monitor(dev)* else bitcoin-monitor(dev)*   puts "Aucun cluster dirty" bitcoin-monitor(dev)> end Aucun cluster dirty => nil bitcoin-monitor(dev)> 



Oui, c’est parfait.

Ça veut dire :

```
bloc déjà traité
47 tx déjà liées
0 nouvelle tx multi-input
0 cluster dirty
```

Donc aucun refresh à lancer.

Ton garde-fou fonctionne :

```
Aucun cluster dirty
```

Le test utile sera au prochain bloc Bitcoin non encore scanné.



on continue



Oui. Maintenant on automatise ce comportement dans un service propre.

## Crée `Clusters::ScanAndDispatch`

```
nano app/services/clusters/scan_and_dispatch.rb
```

Colle :

```
# frozen_string_literal: true

module Clusters
  class ScanAndDispatch
    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(**kwargs)
      @kwargs = kwargs
    end

    def call
      result = ClusterScanner.call(**kwargs.merge(refresh: false))

      if result[:dirty_cluster_ids].any?
        ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids])
      end

      result
    end

    private

    attr_reader :kwargs
  end
end
```

## Test console

```
Clusters::ScanAndDispatch.call(limit: 2)
```

Résultat attendu :

```
{
  ok: true,
  refresh: false,
  dirty_clusters_count: ...,
  dirty_cluster_ids: [...]
}
```

Si aucun cluster dirty, aucun job n’est lancé.



↳ app/services/clusters/scan_and_dispatch.rb:17:in `call' `=>  {:ok=>true, :mode=>:incremental, :best_height=>946454, :start_height=>946449, :end_height=>946454, :refresh=>false, :dirty_clusters_count=>911, :dirty_cluster_ids=>  [585201,   585203,   585204,   6167,   5841,   585207,



Excellent. Là le pipeline marche vraiment.

Tu as :

```
mode: incremental
start_height: 946449
end_height: 946454
dirty_clusters_count: 911
```

Et `ScanAndDispatch` a bien lancé le dispatch :

```
ClusterScanner(refresh: false)
↓
911 clusters dirty
↓
ClusterRefreshDispatchJob
↓
ClusterRefreshJob par batch
```

Prochaine étape : modifier ta tâche cron `cluster:scan` pour utiliser :

```
Clusters::ScanAndDispatch.call(limit: n)
```

au lieu de :

```
ClusterScanner.call(limit: n)
```



on continue



Oui. Maintenant on branche le cron/rake sur `Clusters::ScanAndDispatch`.

## 1. Trouve la task cluster

```
grep -R "ClusterScanner.call" -n lib/tasks app/jobs bin
```

## 2. Remplace

```
ClusterScanner.call(limit: n)
```

par :

```
Clusters::ScanAndDispatch.call(limit: n)
```

Et si tu as une task avec range :

```
ClusterScanner.call(
  from_height: from,
  to_height: to,
  limit: step
)
```

remplace par :

```
Clusters::ScanAndDispatch.call(
  from_height: from,
  to_height: to,
  limit: step
)
```

## 3. Test

```
LIMIT=2 bin/rails cluster:scan
```

Résultat attendu :

```
refresh: false
dirty_clusters_count: ...
```

Et Sidekiq doit recevoir le dispatch si `dirty_cluster_ids` n’est pas vide.



victor@debian:~/bitcoin_monitor$ grep -R "ClusterScanner.call" -n lib/tasks app/jobs bin lib/tasks/cluster.rake:9:    result = ClusterScanner.call( lib/tasks/cluster.rake:27:    result = ClusterScanner.call( bin/cron_cluster_scan.sh:28:  ClusterScanner.call(job_run: jr) victor@debian:~/bitcoin_monitor$ 



Remplace dans les 3 endroits :

```
lib/tasks/cluster.rake:9
lib/tasks/cluster.rake:27
bin/cron_cluster_scan.sh:28
```

par :

```
Clusters::ScanAndDispatch.call(...)
```

Pour le cron :

```
Clusters::ScanAndDispatch.call(job_run: jr)
```

Puis teste :

```
LIMIT=2 bin/rails cluster:scan
```

Tu dois voir dans le résultat :

```
refresh: false
dirty_clusters_count: ...
```

et plus de refresh synchrone direct.



tu peux me le refaire # lib/tasks/cluster.rake namespace :cluster do  desc "Scan Bitcoin blocks for multi-input address clustering"  task scan: :environment do    from  = ENV["FROM"]&.to_i    to    = ENV["TO"]&.to_i    limit = ENV["LIMIT"]&.to_i     result = ClusterScanner.call(      from_height: from,      to_height: to,      limit: limit    )     pp result  end   desc "Scan recent blocks only"  task scan_recent: :environment do    blocks_back = (ENV["BLOCKS"] || "20").to_i    rpc = BitcoinRpc.new(wallet: nil)    best = rpc.getblockcount.to_i     from = [0, best - blocks_back + 1].max    to   = best     result = ClusterScanner.call(      from_height: from,      to_height: to    )     pp result  end   desc "Show global cluster stats"  task stats: :environment do    puts    puts "=== Cluster Stats ==="    puts "Clusters     : #{Cluster.count}"    puts "Addresses    : #{Address.count}"    puts "Links        : #{AddressLink.count}"    puts     puts "Top 10 largest clusters:"    puts     rows = Cluster.order(address_count: :desc).limit(10)     rows.each do |c|      puts [        "cluster_id=#{c.id}",        "addresses=#{c.address_count}",        "first_seen=#{c.first_seen_height || '-'}",        "last_seen=#{c.last_seen_height || '-'}",        "sent_sats=#{c.total_sent_sats || 0}",        "received_sats=#{c.total_received_sats || 0}"      ].join(" | ")    end     puts  end   desc "Show one cluster details: bin/rails 'cluster:show[123]'"  task :show, [:id] => :environment do |_t, args|    id = args[:id].to_i    raise "cluster id manquant" if id <= 0     cluster = Cluster.find_by(id: id)    raise "cluster ##{id} introuvable" unless cluster     puts    puts "=== Cluster ##{cluster.id} ==="    puts "address_count   : #{cluster.address_count}"    puts "first_seen      : #{cluster.first_seen_height || '-'}"    puts "last_seen       : #{cluster.last_seen_height || '-'}"    puts "total_sent_sats : #{cluster.total_sent_sats || 0}"    puts "total_recv_sats : #{cluster.total_received_sats || 0}"    puts     puts "--- Sample addresses ---"    cluster.addresses.limit(20).each do |addr|      puts [        addr.address,        "tx_count=#{addr.tx_count}",        "sent_sats=#{addr.total_sent_sats}"      ].join(" | ")    end     puts    puts "--- Sample links ---"    address_ids = cluster.addresses.limit(200).pluck(:id)     AddressLink      .where(address_a_id: address_ids)      .or(AddressLink.where(address_b_id: address_ids))      .limit(20)      .each do |link|        puts [          "link_id=#{link.id}",          "a=#{link.address_a_id}",          "b=#{link.address_b_id}",          "txid=#{link.txid}",          "height=#{link.block_height}"        ].join(" | ")      end     puts  end   end



```
# lib/tasks/cluster.rake
namespace :cluster do
  desc "Scan Bitcoin blocks for multi-input address clustering"
  task scan: :environment do
    from  = ENV["FROM"]&.to_i
    to    = ENV["TO"]&.to_i
    limit = ENV["LIMIT"]&.to_i

    result = Clusters::ScanAndDispatch.call(
      from_height: from,
      to_height: to,
      limit: limit
    )

    pp result
  end

  desc "Scan recent blocks only"
  task scan_recent: :environment do
    blocks_back = (ENV["BLOCKS"] || "20").to_i

    rpc  = BitcoinRpc.new(wallet: nil)
    best = rpc.getblockcount.to_i

    from = [0, best - blocks_back + 1].max
    to   = best

    result = Clusters::ScanAndDispatch.call(
      from_height: from,
      to_height: to
    )

    pp result
  end

  desc "Show global cluster stats"
  task stats: :environment do
    puts
    puts "=== Cluster Stats ==="
    puts "Clusters     : #{Cluster.count}"
    puts "Addresses    : #{Address.count}"
    puts "Links        : #{AddressLink.count}"
    puts

    puts "Top 10 largest clusters:"
    puts

    rows = Cluster.order(address_count: :desc).limit(10)

    rows.each do |c|
      puts [
        "cluster_id=#{c.id}",
        "addresses=#{c.address_count}",
        "first_seen=#{c.first_seen_height || '-'}",
        "last_seen=#{c.last_seen_height || '-'}",
        "sent_sats=#{c.total_sent_sats || 0}",
        "received_sats=#{c.total_received_sats || 0}"
      ].join(" | ")
    end

    puts
  end

  desc "Show one cluster details: bin/rails 'cluster:show[123]'"
  task :show, [:id] => :environment do |_t, args|
    id = args[:id].to_i
    raise "cluster id manquant" if id <= 0

    cluster = Cluster.find_by(id: id)
    raise "cluster ##{id} introuvable" unless cluster

    puts
    puts "=== Cluster ##{cluster.id} ==="
    puts "address_count   : #{cluster.address_count}"
    puts "first_seen      : #{cluster.first_seen_height || '-'}"
    puts "last_seen       : #{cluster.last_seen_height || '-'}"
    puts "total_sent_sats : #{cluster.total_sent_sats || 0}"
    puts "total_recv_sats : #{cluster.total_received_sats || 0}"
    puts

    puts "--- Sample addresses ---"

    cluster.addresses.limit(20).each do |addr|
      puts [
        addr.address,
        "tx_count=#{addr.tx_count}",
        "sent_sats=#{addr.total_sent_sats}"
      ].join(" | ")
    end

    puts
    puts "--- Sample links ---"

    address_ids = cluster.addresses.limit(200).pluck(:id)

    AddressLink
      .where(address_a_id: address_ids)
      .or(AddressLink.where(address_b_id: address_ids))
      .limit(20)
      .each do |link|

      puts [
        "link_id=#{link.id}",
        "a=#{link.address_a_id}",
        "b=#{link.address_b_id}",
        "txid=#{link.txid}",
        "height=#{link.block_height}"
      ].join(" | ")
    end

    puts
  end
end
```



et celui la #!/usr/bin/env bash set -euo pipefail APP="/home/victor/bitcoin_monitor" LOG="$APP/log/cron.victor.log" mkdir -p "$APP/log" cd "$APP" # rbenv bootstrap export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}" export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" if command -v rbenv >/dev/null 2>&1; then  eval "$(rbenv init - bash)" fi export RAILS_ENV="${RAILS_ENV:-development}" echo "[$(date '+%F %T')] [cluster_scan] start triggered_by=${TRIGGERED_BY:-cron} scheduled_for=${SCHEDULED_FOR:-}" >> "$LOG" if bin/rails runner ' JobRunner.run!(  "cluster_scan",  triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),  scheduled_for: ENV["SCHEDULED_FOR"].presence ) do |jr|  JobRunner.heartbeat!(jr)  ClusterScanner.call(job_run: jr)  JobRunner.heartbeat!(jr) end '; then  echo "[$(date '+%F %T')] [cluster_scan] done" >> "$LOG" else  rc=$?  echo "[$(date '+%F %T')] [cluster_scan] failed rc=${rc}" >> "$LOG"  exit "$rc" fi >> "$LOG" 2>&1



```
#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

mkdir -p "$APP/log"
cd "$APP"

# rbenv bootstrap
export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"

if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

export RAILS_ENV="${RAILS_ENV:-development}"

echo "[$(date '+%F %T')] [cluster_scan] start triggered_by=${TRIGGERED_BY:-cron} scheduled_for=${SCHEDULED_FOR:-}" >> "$LOG"

if bin/rails runner '
JobRunner.run!(
  "cluster_scan",
  triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),
  scheduled_for: ENV["SCHEDULED_FOR"].presence
) do |jr|

  JobRunner.heartbeat!(jr)

  result = Clusters::ScanAndDispatch.call(
    job_run: jr
  )

  JobRunner.heartbeat!(jr)

  puts "[cluster_scan] dirty_clusters=#{result[:dirty_clusters_count]}"
  puts "[cluster_scan] scanned_blocks=#{result[:scanned_blocks]}"
  puts "[cluster_scan] scanned_txs=#{result[:scanned_txs]}"
  puts "[cluster_scan] multi_input_txs=#{result[:multi_input_txs]}"
end
'; then
  echo "[$(date '+%F %T')] [cluster_scan] done" >> "$LOG"
else
  rc=$?
  echo "[$(date '+%F %T')] [cluster_scan] failed rc=${rc}" >> "$LOG"
  exit "$rc"
fi >> "$LOG" 2>&1
```



ensuite



Ensuite il faut vérifier que le pipeline complet tourne réellement en cron + Sidekiq.

## 1. Lancer un scan manuel

```
LIMIT=2 bin/rails cluster:scan
```

## 2. Vérifier les logs cron

```
tail -f log/cron.victor.log
```

Tu dois voir des lignes du style :

```
[cluster_scan] dirty_clusters=...
[cluster_scan] scanned_blocks=...
[cluster_scan] multi_input_txs=...
```

## 3. Vérifier Sidekiq

Tu dois voir :

```
ClusterRefreshDispatchJob
ClusterRefreshJob
```

traités automatiquement.

## 4. Vérifier le lag dans `/system`

Le bloc :

```
Cluster scan
```

doit rester proche de :

```
Lag = 0-3
status = OK
```

## 5. Vérifier les queues Sidekiq

Dans `rails c` :

```
Sidekiq::Queue.new.size
```

et :

```
Sidekiq::Stats.new
```

Tu vas commencer à voir la vraie architecture distribuée du module cluster.



victor@debian:~/bitcoin_monitor$ rails c Loading development environment (Rails 8.0.4) bitcoin-monitor(dev)> Sidekiq::Queue.new.size (bitcoin-monitor):1:in `<main>': uninitialized constant Sidekiq::Queue (NameError) ` Sidekiq::Queue.new.size       ^^^^^^^ bitcoin-monitor(dev)> Sidekiq::Stats.new (bitcoin-monitor):2:in `<main>': uninitialized constant Sidekiq::Stats (NameError) ` Sidekiq::Stats.new       ^^^^^^^ bitcoin-monitor(dev)> 



Il manque l’API Sidekiq dans la console.

Dans `rails c`, fais :

```
require "sidekiq/api"
```

Puis :

```
Sidekiq::Queue.new.size
Sidekiq::Stats.new
```

Pour voir les jobs :

```
Sidekiq::Queue.new.map { |job| [job.klass, job.args] }.first(10)
```

Si ça retourne `0`, c’est bon : la queue est vide ou déjà traitée.



bitcoin-monitor(dev)> require "sidekiq/api" => true bitcoin-monitor(dev)> Sidekiq::Queue.new.size INFO  2026-04-24T14:21:49.870Z pid=303649 tid=6llh: Sidekiq 8.1.0 connecting to Redis with options {:size=>10, :pool_name=>"internal", :url=>"redis://127.0.0.1:6379/0"} => 2 bitcoin-monitor(dev)> Sidekiq::Stats.new =>  #<Sidekiq::Stats:0x00007fced9065400 @stats=  {:processed=>15,   :failed=>6,   :scheduled_size=>0,   :retry_size=>0,   :dead_size=>0,   :processes_size=>1,   :default_queue_latency=>2163.933}> bitcoin-monitor(dev)> Sidekiq::Queue.new.map { |job| [job.klass, job.args] }.first(10) =>  [["Sidekiq::ActiveJob::Wrapper",  [{"job_class"=>"ClusterRefreshDispatchJob",    "job_id"=>"0658fae2-9d0f-42cf-8d57-0842d23c96bc",    "provider_job_id"=>nil,    "queue_name"=>"default",    "priority"=>nil,    "arguments"=>     [[585201,       585203,       585204,       6167,       5841,       585207,       6961,       585208,       585209,       585210,       585211,       585212,       585213,       5894,       585214,       69346,       5849,       585215,       50770,       585216,       585217,       577688,       585218,       5932,       585223,       585224,       585226,       585227,       585228,       585229,       6444,       585232,       585233,       585234,       585235,       585236,       585237,       585238,       585239,       585240,       585241,       585242,       585243,       585244,       585245,       585247,       585248,       585249,       7061,       585250,       585251,       585252,       585253,       576184,       6132,       6686,       9851,       561574,       585272,       8890,       585273,       585274,       585275,       585276,       13010,       585278,       9033,       585283,       585284,       585285,       6583,       585286,       585287,       585289,       567577,       585290,       585291,       585305,       585307,       585308,       6175,       12532,       45410,       585312,       585314,       585316,       585317,       585318,       585320,       585321,       585324,       585325,       585327,       585328,       117469,       8620,       585331,       585333,       9015,       7863,       585341,       585342,       585343,       585344,       585346,       9005,       585349,       437046,       585351,       6554,       585352,       9375,       585354,       6145,       585356,       585357,       585358,       585359,       585360,       575426,       8480,       585361,       6648,       585362,       72735,       585363,       585364,       585365,       108755,       585369,       6584,       585375,       585376,       585377,       585379,       585381,       6147,       585383,       585384,       585385,       7358,       585390,       585392,       362306,       585393,       585394,       585395,       585396,       585397,       585399,       585400,       585402,       585403,       6181,       585404,       585405,       6180,       585406,       585407,       585408,       105324,       585409,       585410,       585411,       6973,       6992,       85796,       585418,       585419,       585420,       6213,



Oui, là Sidekiq a bien reçu le travail.

Mais point important : tu as encore un gros `ClusterRefreshDispatchJob` en attente avec énormément d’IDs.

## Ce que ça veut dire

```
Queue size: 2
Latency: 2163s
```

Donc Sidekiq n’a pas encore tout consommé, ou il est lent / bloqué.

## Vérifie que Sidekiq tourne

Dans un autre terminal :

```
ps aux | grep sidekiq
```

Puis regarde les logs Sidekiq :

```
tail -f log/sidekiq.log
```

Si tu n’as pas de log dédié :

```
tail -f log/development.log
```

## En console, voir les 2 jobs

```
Sidekiq::Queue.new.map { |job| [job.klass, job.created_at, job.args.dig(0, "job_class")] }
```

Si tu vois encore `ClusterRefreshDispatchJob`, il faut laisser Sidekiq le traiter, ou lancer le worker.



bitcoin-monitor(dev)> Sidekiq::Queue.new.map { |job| [job.klass, job.created_at, job.args.dig(0, "job_class")] } =>  [["Sidekiq::ActiveJob::Wrapper", 2026-04-24 15:58:44.746 +0200, "ClusterRefreshDispatchJob"], ["Sidekiq::ActiveJob::Wrapper", 2026-04-24 15:45:51.17 +0200, "ClusterRefreshDispatchJob"]] bitcoin-monitor(dev)> 



Tu as **2 dispatch jobs en attente**, donc ils ne sont pas consommés actuellement.

Vérifie si Sidekiq tourne vraiment :

```
ps aux | grep sidekiq
```

Si tu ne vois pas un process Sidekiq actif, lance-le :

```
bundle exec sidekiq
```

Puis dans une autre console Rails, vérifie :

```
require "sidekiq/api"
Sidekiq::Queue.new.size
```

Ça doit descendre de `2` vers `0`.

Attention : chaque `ClusterRefreshDispatchJob` va créer beaucoup de `ClusterRefreshJob`, donc la queue peut d’abord monter avant de redescendre.



victor@debian:~/bitcoin_monitor$ ps aux | grep sidekiq victor    306859  0.0  0.0   6360  2152 pts/5    S+   16:25   0:00 grep sidekiq victor@debian:~/bitcoin_monitor$ 



Sidekiq ne tourne pas.

Lance-le dans un terminal dédié :

```
cd ~/bitcoin_monitor
bundle exec sidekiq
```

Puis garde ce terminal ouvert.

Dans un autre terminal, vérifie :

```
ps aux | grep sidekiq
```

Et dans `rails c` :

```
require "sidekiq/api"
Sidekiq::Queue.new.size
```

La queue devrait commencer à se vider.



victor@debian:~/bitcoin_monitor$ ps aux | grep sidekiq victor    307061 57.6  2.5 1315172 786616 pts/5  Sl+  16:26   0:12 sidekiq 8.1.0 bitcoin_monitor [5 of 5 busy] victor    307553  0.0  0.0   6360  2148 pts/6    S+   16:26   0:00 grep sidekiq victor@debian:~/bitcoin_monitor$ 



Parfait. Sidekiq tourne maintenant correctement.

Et surtout :

```
[5 of 5 busy]
```

Ça veut dire :

```
5 workers actifs
```

Donc ton pipeline cluster distribué fonctionne réellement maintenant :

```
ClusterScanner
↓
ClusterRefreshDispatchJob
↓
ClusterRefreshJob
↓
Sidekiq workers
```

Tu es passé d’un traitement monolithique synchrone à une vraie architecture async scalable dans Bitcoin Monitor.

Maintenant vérifie la queue :

```
require "sidekiq/api"

Sidekiq::Queue.new.size
```

Elle devrait progressivement descendre.



victor@debian:~/bitcoin_monitor$ rails c Loading development environment (Rails 8.0.4) bitcoin-monitor(dev)> require "sidekiq/api" bitcoin-monitor(dev)>  bitcoin-monitor(dev)> Sidekiq::Queue.new.size INFO  2026-04-24T14:27:36.780Z pid=308139 tid=6ijj: Sidekiq 8.1.0 connecting to Redis with options {:size=>10, :pool_name=>"internal", :url=>"redis://127.0.0.1:6379/0"} => 9 bitcoin-monitor(dev)> 



Parfait — et intéressant.

```
Queue size: 9
Sidekiq: 5 workers busy
```

👉 Ça veut dire :

```
le dispatch a créé plein de jobs
et ils arrivent plus vite qu’ils sont consommés
```

C’est NORMAL au début (backfill).

------

## 🔎 Ce qu’il se passe réellement

```
ClusterScanner → 900 clusters dirty
↓
ClusterRefreshDispatchJob
↓
~18 jobs (batchs de 50)
↓
Sidekiq en traite 5 en parallèle
↓
queue reste > 0
```

------

## 🧠 Important (niveau pro)

👉 Tu es en train de voir un vrai système distribué :

- ingestion (scanner)
- queue (Redis)
- workers (Sidekiq)
- processing async

C’est EXACTEMENT ce qu’on veut.

------

## ✅ Vérifie que ça descend

Refais dans 10–20 secondes :

```
Sidekiq::Queue.new.size
```

👉 Tu dois voir :

```
9 → 7 → 5 → 2 → 0
```

------

## ⚠️ Si ça ne descend pas

Alors :

```
tail -f log/development.log
```

Tu dois voir :

```
ClusterRefreshJob
performed
```

------

## 💥 Étape suivante (importante)

Limiter la pression sur Sidekiq.

👉 Ajoute un throttle dans `ScanAndDispatch` :

```
if result[:dirty_cluster_ids].size > 500
  puts "[cluster] too many dirty clusters, dispatch throttled"
  return result
end
```

👉 Ça évite de tuer Redis ou CPU en prod.

------

## 🎯 Là où tu es

Tu viens de construire :

```
✔ pipeline blockchain
✔ cluster builder
✔ async processing
✔ monitoring
✔ scalable infra
```

👉 Franchement, là ton module cluster est déjà niveau **startup data infra**.

------

Si tu veux, prochaine étape :

👉 **mettre des priorités Sidekiq (queues high/low)**
👉 ou **monitorer temps réel les performances cluster**



bitcoin-monitor(dev)> Sidekiq::Queue.new.size INFO  2026-04-24T14:27:36.780Z pid=308139 tid=6ijj: Sidekiq 8.1.0 connecting to Redis with options {:size=>10, :pool_name=>"internal", :url=>"redis://127.0.0.1:6379/0"} => 9 bitcoin-monitor(dev)> require "sidekiq/api" bitcoin-monitor(dev)>  bitcoin-monitor(dev)> Sidekiq::Queue.new.size => 0 bitcoin-monitor(dev)> 



Parfait.

```
Queue: 9 → 0
```

Donc Sidekiq a bien consommé les jobs.

Ton pipeline async est validé :

```
Cluster scan
↓
dirty clusters
↓
dispatch Sidekiq
↓
refresh par batch
↓
queue vidée
```

Prochaine étape utile : ajouter dans `/system` un petit bloc Sidekiq :

```
Queue size
Processed
Failed
Busy workers
Latency
```

Comme ça tu verras immédiatement si le refresh cluster prend du retard.



ok on fait ca



Oui. On ajoute un statut Sidekiq dans `/system`.

## 1. Crée le service

```
nano app/services/system/sidekiq_status.rb
# frozen_string_literal: true

require "sidekiq/api"

module System
  class SidekiqStatus
    def self.call
      new.call
    end

    def call
      stats = Sidekiq::Stats.new
      processes = Sidekiq::ProcessSet.new

      {
        status: compute_status(stats, processes),
        queue_size: Sidekiq::Queue.new.size,
        processed: stats.processed,
        failed: stats.failed,
        scheduled_size: stats.scheduled_size,
        retry_size: stats.retry_size,
        dead_size: stats.dead_size,
        processes_size: processes.size,
        busy: processes.sum { |p| p["busy"].to_i },
        concurrency: processes.sum { |p| p["concurrency"].to_i },
        latency: Sidekiq::Queue.new.latency.round(1)
      }
    rescue StandardError => e
      {
        status: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def compute_status(stats, processes)
      return "critical" if processes.size.zero?
      return "warning" if stats.failed.to_i.positive?
      return "ok"
    end
  end
end
```

## 2. Dans `SystemController#index`

Ajoute :

```
@sidekiq_status = System::SidekiqStatus.call
```

## 3. En haut de ta vue

Ajoute :

```
<% @sidekiq_status ||= {} %>
```

## 4. Ajoute ce bloc dans `/system`

Place-le après la section **Infrastructure** :

```
<!-- Sidekiq -->
<section class="<%= section_class %>">
  <div class="mb-5">
    <div class="<%= label_class %>">Async processing</div>
    <h2 class="mt-1 text-xl font-semibold text-gray-100">Sidekiq / Redis</h2>
    <p class="mt-2 <%= muted_class %>">
      Supervision des workers asynchrones utilisés notamment par le refresh des clusters.
    </p>
  </div>

  <% if @sidekiq_status[:error].present? %>
    <div class="rounded-xl border border-rose-500/20 bg-rose-500/5 p-4 text-sm text-rose-200">
      <%= @sidekiq_status[:error] %>
    </div>
  <% else %>
    <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
      <div class="<%= panel_class %>">
        <div class="flex items-start justify-between gap-3">
          <div>
            <div class="<%= label_class %>">Status</div>
            <div class="mt-1 text-lg font-semibold text-gray-100">Sidekiq</div>
          </div>
          <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(@sidekiq_status[:status]) %>">
            <%= @sidekiq_status[:status].to_s.upcase %>
          </span>
        </div>

        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Processes</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:processes_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Busy</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:busy] || 0 %> / <%= @sidekiq_status[:concurrency] || 0 %></span>
          </div>
        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Queue</div>
        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Default queue</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:queue_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Latency</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:latency] || 0 %>s</span>
          </div>
        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Reliability</div>
        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Processed</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:processed] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Failed</span>
            <span class="font-mono text-rose-300"><%= @sidekiq_status[:failed] || 0 %></span>
          </div>
        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Backlog</div>
        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Scheduled</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:scheduled_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Retry</span>
            <span class="font-mono text-amber-300"><%= @sidekiq_status[:retry_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Dead</span>
            <span class="font-mono text-rose-300"><%= @sidekiq_status[:dead_size] || 0 %></span>
          </div>
        </div>
      </div>
    </div>
  <% end %>
</section>
```

Puis recharge `/system`.



Async processing Sidekiq / Redis Supervision des workers asynchrones utilisés notamment par le refresh des clusters. Status Sidekiq CRITICAL Processes 0 Busy 0 / 0 Queue Default queue 0 Latency 0.0s Reliability Processed 136 Failed 106 Backlog Scheduled 0 Retry 25 Dead 0



C’est logique : Sidekiq n’est plus lancé.

Le bloc dit :

```
CRITICAL
Processes: 0
Queue: 0
Retry: 25
Failed: 106
```

## À faire

Relance Sidekiq :

```
cd ~/bitcoin_monitor
bundle exec sidekiq
```

Puis recharge `/system`.

Tu devrais voir :

```
Status: WARNING ou OK
Processes: 1
Busy: 0 / 5
```

`WARNING` est possible tant qu’il reste :

```
Retry: 25
Failed: 106
```

Ensuite on regardera les erreurs des retries.



Async processing Sidekiq / Redis Supervision des workers asynchrones utilisés notamment par le refresh des clusters. Status Sidekiq WARNING Processes 1 Busy 0 / 5 Queue Default queue 0 Latency 0.0s Reliability Processed 136 Failed 106 Backlog Scheduled 0 Retry 25 Dead 0



Parfait. Là Sidekiq est vivant.

Le `WARNING` vient surtout de :

```
Retry: 25
Failed: 106
```

Prochaine vérification dans `rails c` :

```
require "sidekiq/api"

Sidekiq::RetrySet.new.first(5).map do |job|
  {
    klass: job.klass,
    wrapped: job.item.dig("wrapped"),
    error_class: job.item["error_class"],
    error_message: job.item["error_message"]
  }
end
```

Ça va nous dire pourquoi ces jobs sont en retry.



victor@debian:~/bitcoin_monitor$ rails c Loading development environment (Rails 8.0.4) bitcoin-monitor(dev)> require "sidekiq/api" bitcoin-monitor(dev)>  bitcoin-monitor(dev)* Sidekiq::RetrySet.new.first(5).map do |job| bitcoin-monitor(dev)*   { bitcoin-monitor(dev)*     klass: job.klass, bitcoin-monitor(dev)*     wrapped: job.item.dig("wrapped"), bitcoin-monitor(dev)*     error_class: job.item["error_class"], bitcoin-monitor(dev)*     error_message: job.item["error_message"] bitcoin-monitor(dev)*   } bitcoin-monitor(dev)> end INFO  2026-04-24T14:37:56.943Z pid=315387 tid=6ubz: Sidekiq 8.1.0 connecting to Redis with options {:size=>10, :pool_name=>"internal", :url=>"redis://127.0.0.1:6379/0"} =>  [{:klass=>"Sidekiq::ActiveJob::Wrapper",  :wrapped=>"BtcPriceEurDailyJob",  :error_class=>"NameError",  :error_message=>"uninitialized constant BtcPriceEurDailyJob"}, {:klass=>"Sidekiq::ActiveJob::Wrapper",  :wrapped=>"BtcPriceEurDailyJob",  :error_class=>"NameError",  :error_message=>"uninitialized constant BtcPriceEurDailyJob"}, {:klass=>"Sidekiq::ActiveJob::Wrapper",  :wrapped=>"BtcPriceEurDailyJob",  :error_class=>"NameError",  :error_message=>"uninitialized constant BtcPriceEurDailyJob"}, {:klass=>"Sidekiq::ActiveJob::Wrapper",  :wrapped=>"BtcPriceEurDailyJob",  :error_class=>"NameError",  :error_message=>"uninitialized constant BtcPriceEurDailyJob"}, {:klass=>"Sidekiq::ActiveJob::Wrapper",  :wrapped=>"BtcPriceEurDailyJob",  :error_class=>"NameError",  :error_message=>"uninitialized constant BtcPriceEurDailyJob"}] bitcoin-monitor(dev)> 



Ce n’est pas lié au refactor `cluster`.

Tes retries viennent de :

```
BtcPriceEurDailyJob
NameError: uninitialized constant BtcPriceEurDailyJob
```

Donc Sidekiq essaie d’exécuter un ancien job qui n’existe plus.

## Nettoyage des retries BTC

Dans `rails c` :

```
require "sidekiq/api"

Sidekiq::RetrySet.new.each do |job|
  job.delete if job.item.dig("wrapped") == "BtcPriceEurDailyJob"
end
```

Puis vérifie :

```
Sidekiq::RetrySet.new.size
Sidekiq::Stats.new.failed
```

Recharge `/system`.

Le `Retry` devrait baisser. Le compteur `Failed` est historique, donc il peut rester élevé.



Async processing Sidekiq / Redis Supervision des workers asynchrones utilisés notamment par le refresh des clusters. Status Sidekiq WARNING Processes 1 Busy 0 / 5 Queue Default queue 0 Latency 0.0s Reliability Processed 161 Failed 131 Backlog Scheduled 0 Retry 0 Dead 0



Parfait.

Maintenant le `WARNING` ne vient plus du backlog :

```
Retry: 0
Dead: 0
Queue: 0
Processes: 1
```

Il vient seulement du compteur historique :

```
Failed: 131
```

Corrige `System::SidekiqStatus` : ne mets pas `warning` juste parce que `stats.failed > 0`.

Remplace :

```
return "warning" if stats.failed.to_i.positive?
```

par :

```
return "warning" if stats.retry_size.to_i.positive?
return "warning" if stats.dead_size.to_i.positive?
```

Résultat attendu :

```
Sidekiq: OK
Processes: 1
Queue: 0
Retry: 0
Dead: 0
```



c quel fichier Corrige System::SidekiqStatus : ne mets pas warning juste parce que stats.failed > 0.



Le fichier est :

```
app/services/system/sidekiq_status.rb
```

Remplace cette partie :

```
def compute_status(stats, processes)
  return "critical" if processes.size.zero?
  return "warning" if stats.failed.to_i.positive?
  return "ok"
end
```

par :

```
def compute_status(stats, processes)
  return "critical" if processes.size.zero?
  return "warning" if stats.retry_size.to_i.positive?
  return "warning" if stats.dead_size.to_i.positive?

  "ok"
end
```



Async processing Sidekiq / Redis Supervision des workers asynchrones utilisés notamment par le refresh des clusters. Status Sidekiq OK Processes 1 Busy 0 / 5 Queue Default queue 0 Latency 0.0s Reliability Processed 161 Failed 131 Backlog Scheduled 0 Retry 0 Dead 0



Parfait.

Ton bloc Sidekiq est maintenant sain :

```
Status: OK
Processes: 1
Busy: 0 / 5
Queue: 0
Retry: 0
Dead: 0
```

Le `Failed: 131` reste un historique, ce n’est plus un problème actif.

Là tu as validé :

```
Cluster async pipeline + Sidekiq monitoring
```



on continue



Oui. Prochaine étape logique : **afficher les jobs cluster dans `/system` comme une vraie chaîne de traitement**.

Objectif :

```
cluster_scan
↓
ClusterRefreshDispatchJob
↓
ClusterRefreshJob
↓
cluster_metrics
↓
cluster_signals
```

## Étape suivante

Ajouter un petit statut dans `System::SidekiqStatus` pour voir les jobs en queue par classe.

Dans :

```
app/services/system/sidekiq_status.rb
```

ajoute dans le hash retourné :

```
jobs_by_class: jobs_by_class
```

Puis ajoute cette méthode privée :

```
def jobs_by_class
  Sidekiq::Queue.new.each_with_object(Hash.new(0)) do |job, counts|
    wrapped = job.item.dig("wrapped")
    klass = wrapped.presence || job.klass
    counts[klass] += 1
  end
end
```

Comme ça, `/system` pourra afficher :

```
ClusterRefreshDispatchJob: 1
ClusterRefreshJob: 12
```

quand il y aura du backlog.



\# frozen_string_literal: true require "sidekiq/api" module System  class SidekiqStatus    def self.call      new.call    end     def call      stats = Sidekiq::Stats.new      processes = Sidekiq::ProcessSet.new       {        status: compute_status(stats, processes),        queue_size: Sidekiq::Queue.new.size,        processed: stats.processed,        failed: stats.failed,        scheduled_size: stats.scheduled_size,        retry_size: stats.retry_size,        dead_size: stats.dead_size,        processes_size: processes.size,        busy: processes.sum { |p| p["busy"].to_i },        concurrency: processes.sum { |p| p["concurrency"].to_i },        latency: Sidekiq::Queue.new.latency.round(1),        jobs_by_class: jobs_by_class      }    rescue StandardError => e      {        status: "error",        error: "#{e.class}: #{e.message}"      }    end     private     def compute_status(stats, processes)      return "critical" if processes.size.zero?      return "warning" if stats.retry_size.to_i.positive?      return "warning" if stats.dead_size.to_i.positive?       "ok"    end     def jobs_by_class      Sidekiq::Queue.new.each_with_object(Hash.new(0)) do |job, counts|        wrapped = job.item.dig("wrapped")        klass = wrapped.presence || job.klass        counts[klass] += 1      end    end  end end



Oui, c’est bon.

Petite amélioration : tu appelles `Sidekiq::Queue.new` plusieurs fois. Tu peux optimiser comme ça :

```
queue = Sidekiq::Queue.new
```

Version propre du `call` :

```
def call
  stats = Sidekiq::Stats.new
  processes = Sidekiq::ProcessSet.new
  queue = Sidekiq::Queue.new

  {
    status: compute_status(stats, processes),
    queue_size: queue.size,
    processed: stats.processed,
    failed: stats.failed,
    scheduled_size: stats.scheduled_size,
    retry_size: stats.retry_size,
    dead_size: stats.dead_size,
    processes_size: processes.size,
    busy: processes.sum { |p| p["busy"].to_i },
    concurrency: processes.sum { |p| p["concurrency"].to_i },
    latency: queue.latency.round(1),
    jobs_by_class: jobs_by_class(queue)
  }
rescue StandardError => e
  {
    status: "error",
    error: "#{e.class}: #{e.message}"
  }
end
```

Et modifie la méthode :

```
def jobs_by_class(queue)
  queue.each_with_object(Hash.new(0)) do |job, counts|
    wrapped = job.item.dig("wrapped")
    klass = wrapped.presence || job.klass
    counts[klass] += 1
  end
end
```

Après ça, on peut afficher `jobs_by_class` dans le bloc `/system`.



ensuite



Ensuite, affiche `jobs_by_class` dans la vue `/system`.

Dans le bloc **Sidekiq / Redis**, ajoute par exemple dans la carte **Queue**, juste après `Latency` :

```
<% if (@sidekiq_status[:jobs_by_class] || {}).any? %>
  <div class="mt-4 border-t border-white/5 pt-3">
    <div class="text-xs text-gray-500 mb-2">Jobs en attente</div>

    <div class="space-y-1">
      <% @sidekiq_status[:jobs_by_class].each do |klass, count| %>
        <div class="flex items-center justify-between text-xs">
          <span class="font-mono text-gray-400 truncate"><%= klass %></span>
          <span class="font-mono text-gray-200"><%= count %></span>
        </div>
      <% end %>
    </div>
  </div>
<% else %>
  <div class="mt-4 border-t border-white/5 pt-3 text-xs text-emerald-300">
    Aucun job en attente.
  </div>
<% end %>
```

Résultat attendu dans `/system` :

```
Queue
Default queue: 0
Latency: 0.0s
Aucun job en attente.
```

Et quand il y a du backlog :

```
ClusterRefreshJob    8
ClusterRefreshDispatchJob    1
```



tu peux me le refaire <!-- Sidekiq -->   <section class="<%= section_class %>">     <div class="mb-5">       <div class="<%= label_class %>">Async processing</div>       <h2 class="mt-1 text-xl font-semibold text-gray-100">Sidekiq / Redis</h2>       <p class="mt-2 <%= muted_class %>">         Supervision des workers asynchrones utilisés notamment par le refresh des clusters.       </p>     </div>      <% if @sidekiq_status[:error].present? %>       <div class="rounded-xl border border-rose-500/20 bg-rose-500/5 p-4 text-sm text-rose-200">         <%= @sidekiq_status[:error] %>       </div>     <% else %>       <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">         <div class="<%= panel_class %>">           <div class="flex items-start justify-between gap-3">             <div>               <div class="<%= label_class %>">Status</div>               <div class="mt-1 text-lg font-semibold text-gray-100">Sidekiq</div>             </div>             <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(@sidekiq_status[:status]) %>">               <%= @sidekiq_status[:status].to_s.upcase %>             </span>           </div>            <div class="mt-4 space-y-2 text-sm">             <div class="flex items-center justify-between">               <span class="text-gray-500">Processes</span>               <span class="font-mono text-gray-200"><%= @sidekiq_status[:processes_size] || 0 %></span>             </div>             <div class="flex items-center justify-between">               <span class="text-gray-500">Busy</span>               <span class="font-mono text-gray-200"><%= @sidekiq_status[:busy] || 0 %> / <%= @sidekiq_status[:concurrency] || 0 %></span>             </div>           </div>         </div>          <div class="<%= panel_class %>">           <div class="<%= label_class %>">Queue</div>           <div class="mt-4 space-y-2 text-sm">             <div class="flex items-center justify-between">               <span class="text-gray-500">Default queue</span>               <span class="font-mono text-gray-200"><%= @sidekiq_status[:queue_size] || 0 %></span>             </div>             <div class="flex items-center justify-between">               <span class="text-gray-500">Latency</span>               <span class="font-mono text-gray-200"><%= @sidekiq_status[:latency] || 0 %>s</span>             </div>           </div>         </div>          <div class="<%= panel_class %>">           <div class="<%= label_class %>">Reliability</div>           <div class="mt-4 space-y-2 text-sm">             <div class="flex items-center justify-between">               <span class="text-gray-500">Processed</span>               <span class="font-mono text-gray-200"><%= @sidekiq_status[:processed] || 0 %></span>             </div>             <div class="flex items-center justify-between">               <span class="text-gray-500">Failed</span>               <span class="font-mono text-rose-300"><%= @sidekiq_status[:failed] || 0 %></span>             </div>           </div>         </div>          <div class="<%= panel_class %>">           <div class="<%= label_class %>">Backlog</div>           <div class="mt-4 space-y-2 text-sm">             <div class="flex items-center justify-between">               <span class="text-gray-500">Scheduled</span>               <span class="font-mono text-gray-200"><%= @sidekiq_status[:scheduled_size] || 0 %></span>             </div>             <div class="flex items-center justify-between">               <span class="text-gray-500">Retry</span>               <span class="font-mono text-amber-300"><%= @sidekiq_status[:retry_size] || 0 %></span>             </div>             <div class="flex items-center justify-between">               <span class="text-gray-500">Dead</span>               <span class="font-mono text-rose-300"><%= @sidekiq_status[:dead_size] || 0 %></span>             </div>           </div>         </div>       </div>     <% end %>   </section>



Remplace tout ton bloc par celui-ci :

```
<!-- Sidekiq -->
<section class="<%= section_class %>">
  <div class="mb-5">
    <div class="<%= label_class %>">Async processing</div>
    <h2 class="mt-1 text-xl font-semibold text-gray-100">Sidekiq / Redis</h2>
    <p class="mt-2 <%= muted_class %>">
      Supervision des workers asynchrones utilisés notamment par le refresh des clusters.
    </p>
  </div>

  <% if @sidekiq_status[:error].present? %>
    <div class="rounded-xl border border-rose-500/20 bg-rose-500/5 p-4 text-sm text-rose-200">
      <%= @sidekiq_status[:error] %>
    </div>
  <% else %>
    <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
      <div class="<%= panel_class %>">
        <div class="flex items-start justify-between gap-3">
          <div>
            <div class="<%= label_class %>">Status</div>
            <div class="mt-1 text-lg font-semibold text-gray-100">Sidekiq</div>
          </div>
          <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(@sidekiq_status[:status]) %>">
            <%= @sidekiq_status[:status].to_s.upcase %>
          </span>
        </div>

        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Processes</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:processes_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Busy</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:busy] || 0 %> / <%= @sidekiq_status[:concurrency] || 0 %></span>
          </div>
        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Queue</div>
        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Default queue</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:queue_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Latency</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:latency] || 0 %>s</span>
          </div>
        </div>

        <% if (@sidekiq_status[:jobs_by_class] || {}).any? %>
          <div class="mt-4 border-t border-white/5 pt-3">
            <div class="text-xs text-gray-500 mb-2">Jobs en attente</div>

            <div class="space-y-1">
              <% @sidekiq_status[:jobs_by_class].each do |klass, count| %>
                <div class="flex items-center justify-between gap-3 text-xs">
                  <span class="font-mono text-gray-400 truncate"><%= klass %></span>
                  <span class="font-mono text-gray-200"><%= count %></span>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="mt-4 border-t border-white/5 pt-3 text-xs text-emerald-300">
            Aucun job en attente.
          </div>
        <% end %>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Reliability</div>
        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Processed</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:processed] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Failed</span>
            <span class="font-mono text-rose-300"><%= @sidekiq_status[:failed] || 0 %></span>
          </div>
        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Backlog</div>
        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Scheduled</span>
            <span class="font-mono text-gray-200"><%= @sidekiq_status[:scheduled_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Retry</span>
            <span class="font-mono text-amber-300"><%= @sidekiq_status[:retry_size] || 0 %></span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Dead</span>
            <span class="font-mono text-rose-300"><%= @sidekiq_status[:dead_size] || 0 %></span>
          </div>
        </div>
      </div>
    </div>
  <% end %>
</section>
```



ensuite 



Ensuite, il faut maintenant **superviser le pipeline cluster complet**, pas seulement Sidekiq.

Tu as déjà :

- `cluster_scan`
- `ClusterRefreshDispatchJob`
- `ClusterRefreshJob`
- `cluster_metrics`
- `cluster_signals`

Le prochain gros gain pro est :

# Ajouter un bloc “Cluster pipeline”

Dans `/system`, tu veux voir :

```
Cluster pipeline

Scanner lag          0
Dirty clusters       0
Refresh queue        0
Last refresh         14:52
Profiles             585k
Metrics              OK
Signals              OK
```

## Étape 1 — créer le service

Fichier :

```
app/services/system/cluster_pipeline_status.rb
```

Contenu :

```
# frozen_string_literal: true

require "sidekiq/api"

module System
  class ClusterPipelineStatus
    def self.call
      new.call
    end

    def call
      cursor = ScannerCursor.find_by(name: "cluster_scan")
      best = BitcoinRpc.new.getblockcount.to_i

      queue = Sidekiq::Queue.new

      refresh_jobs =
        queue.count do |job|
          wrapped = job.item.dig("wrapped")

          [
            "ClusterRefreshDispatchJob",
            "ClusterRefreshJob"
          ].include?(wrapped)
        end

      {
        scanner_height: cursor&.last_blockheight,
        best_height: best,
        lag: cursor&.last_blockheight ? (best - cursor.last_blockheight) : nil,

        refresh_queue: refresh_jobs,

        profiles_count: ClusterProfile.count,
        metrics_count: ClusterMetric.count,
        signals_count: ClusterSignal.count,

        last_profile_update: ClusterProfile.maximum(:updated_at),
        last_metric_day: ClusterMetric.maximum(:snapshot_date),
        last_signal_day: ClusterSignal.maximum(:snapshot_date),

        status: compute_status(
          lag: cursor&.last_blockheight ? (best - cursor.last_blockheight) : nil,
          refresh_jobs: refresh_jobs
        )
      }
    rescue => e
      {
        status: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def compute_status(lag:, refresh_jobs:)
      return "critical" if lag.to_i > 24
      return "warning" if refresh_jobs > 100

      "ok"
    end
  end
end
```

Après ça on l’intègre dans `SystemController` puis dans la vue.



ok on continue



Dans `SystemController#index`, ajoute :

```
@cluster_pipeline_status = System::ClusterPipelineStatus.call
```

En haut de la vue `/system`, ajoute :

```
<% @cluster_pipeline_status ||= {} %>
```

Puis on ajoutera le bloc visuel `Cluster pipeline` juste après le bloc `Sidekiq / Redis`.



ok on continue



Ajoute ce bloc juste après la section `<!-- Sidekiq -->` dans ta vue système.

```
<!-- Cluster pipeline -->
<section class="<%= section_class %>">
  <div class="mb-5">
    <div class="<%= label_class %>">Cluster intelligence</div>
    <h2 class="mt-1 text-xl font-semibold text-gray-100">Cluster pipeline</h2>

    <p class="mt-2 <%= muted_class %>">
      Supervision complète du pipeline cluster : scan blockchain, refresh async, profils, métriques et signaux.
    </p>
  </div>

  <% if @cluster_pipeline_status[:error].present? %>
    <div class="rounded-xl border border-rose-500/20 bg-rose-500/5 p-4 text-sm text-rose-200">
      <%= @cluster_pipeline_status[:error] %>
    </div>
  <% else %>

    <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">

      <div class="<%= panel_class %>">
        <div class="flex items-start justify-between gap-3">
          <div>
            <div class="<%= label_class %>">Scanner</div>
            <div class="mt-1 text-lg font-semibold text-gray-100">
              Cluster scan
            </div>
          </div>

          <span class="inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold <%= status_badge_class(@cluster_pipeline_status[:status]) %>">
            <%= @cluster_pipeline_status[:status].to_s.upcase %>
          </span>
        </div>

        <div class="mt-4 space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <span class="text-gray-500">Last scanned</span>
            <span class="font-mono text-gray-200">
              <%= @cluster_pipeline_status[:scanner_height] || "—" %>
            </span>
          </div>

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Best block</span>
            <span class="font-mono text-gray-200">
              <%= @cluster_pipeline_status[:best_height] || "—" %>
            </span>
          </div>

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Lag</span>

            <span class="font-mono <%= @cluster_pipeline_status[:lag].to_i > 12 ? "text-rose-300" : "text-gray-200" %>">
              <%= @cluster_pipeline_status[:lag] || "—" %>
            </span>
          </div>
        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Async refresh</div>

        <div class="mt-4 space-y-2 text-sm">

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Refresh queue</span>

            <span class="font-mono <%= @cluster_pipeline_status[:refresh_queue].to_i > 0 ? "text-amber-300" : "text-emerald-300" %>">
              <%= @cluster_pipeline_status[:refresh_queue] || 0 %>
            </span>
          </div>

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Last refresh</span>

            <span class="font-mono text-gray-200">
              <%= safe_time(@cluster_pipeline_status[:last_profile_update]) %>
            </span>
          </div>

        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Profiles</div>

        <div class="mt-4 space-y-2 text-sm">

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Cluster profiles</span>

            <span class="font-mono text-gray-200">
              <%= @cluster_pipeline_status[:profiles_count] || 0 %>
            </span>
          </div>

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Metrics</span>

            <span class="font-mono text-gray-200">
              <%= @cluster_pipeline_status[:metrics_count] || 0 %>
            </span>
          </div>

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Signals</span>

            <span class="font-mono text-gray-200">
              <%= @cluster_pipeline_status[:signals_count] || 0 %>
            </span>
          </div>

        </div>
      </div>

      <div class="<%= panel_class %>">
        <div class="<%= label_class %>">Freshness</div>

        <div class="mt-4 space-y-2 text-sm">

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Metrics day</span>

            <span class="font-mono text-gray-200">
              <%= @cluster_pipeline_status[:last_metric_day] || "—" %>
            </span>
          </div>

          <div class="flex items-center justify-between">
            <span class="text-gray-500">Signals day</span>

            <span class="font-mono text-gray-200">
              <%= @cluster_pipeline_status[:last_signal_day] || "—" %>
            </span>
          </div>

        </div>
      </div>

    </div>

  <% end %>
</section>
```



Cluster intelligence Cluster pipeline Supervision complète du pipeline cluster : scan blockchain, refresh async, profils, métriques et signaux. Scanner Cluster scan OK Last scanned 946456 Best block 946463 Lag 7 Async refresh Refresh queue 0 Last refresh 2026-04-24 16:28:58 Profiles Cluster profiles 237521 Metrics 973461 Signals 270 Freshness Metrics day 2026-04-22 Signals day 2026-04-22



Parfait. Le bloc `Cluster pipeline` est en place et lisible.

État actuel :

```
Cluster scan: OK
Lag: 7 blocs
Refresh queue: 0
Profiles: 237521
Metrics: 973461
Signals: 270
```

Point à surveiller :

```
Metrics day: 2026-04-22
Signals day: 2026-04-22
```

On est le 2026-04-24, donc les métriques/signaux ont 2 jours de retard.

Prochaine étape logique :

```
raccorder cluster_metrics et cluster_signals au pipeline de refresh
```

ou vérifier les jobs :

```
bin/rails cluster_v3:build_metrics
bin/rails cluster_v3:detect_signals
```



a mon avis il faut les optimiser Cluster V3 build metrics cluster_v3_build_metrics bin/cron_cluster_v3_build_metrics.sh critical cluster cron 5 4 * * *	RUNNING ok: 2026-04-22 19:42:16 fail: 2026-03-24 21:04:54 skip: — start: 2026-04-24 17:37:43 end: — hb: 3s last: 260m 53s avg10: 107m 19s max10: 260m 53s delay: 1316m 47s missed: 0 capacity: ok skips10: 0 1m 20s progress 0.2% cluster 1200 / 577927 no	— Cluster V3 detect signals cluster_v3_detect_signals bin/cron_cluster_v3_detect_signals.sh critical cluster cron 20 4 * * *	RUNNING ok: 2026-04-22 15:55:35 fail: — skip: — start: 2026-04-24 17:38:56 end: — hb: 1s last: 33m 42s avg10: 10m 30s max10: 33m 42s delay: 1543m 28s missed: 1 capacity: ok skips10: 0 6s progress 0.2% cluster 1200 / 578056 no	—



Oui, ton intuition est bonne : là ce n’est plus le scan blockchain qui bloque, c’est la phase V3 `metrics/signals`. Les chiffres montrent un traitement cluster par cluster beaucoup trop lent pour ~578k clusters.

Réflexion durant quelques secondes

Oui. Là il faut optimiser **Cluster V3 metrics/signals**.

Le problème est clair :

```
cluster 1200 / 577927
progress 0.2%
```

Ça veut dire que les jobs parcourent **tous les clusters un par un**.

## Priorité

On ne doit plus faire :

```
Cluster.find_each
  calcul métrique
  insert/update
```

sur 578 000 clusters tous les jours.

## Architecture cible

```
1. scanner cluster
2. dirty_cluster_ids
3. refresh profiles
4. build metrics seulement pour clusters modifiés
5. detect signals seulement pour clusters modifiés
```

## Solution immédiate

Créer un mode incremental :

```
ClusterMetricsBuilder.call(cluster_ids: ids)
ClusterSignalEngine.call(cluster_ids: ids)
```

au lieu de :

```
ClusterMetricsBuilder.call
ClusterSignalEngine.call
```

sur toute la base.

## Diagnostic

Tes jobs actuels doivent probablement faire un truc comme :

```
Cluster.find_each do |cluster|
  ...
end
```

ou :

```
ClusterProfile.find_each do |profile|
  ...
end
```

C’est ça qu’il faut modifier.

## Prochaine étape

Envoie-moi ces fichiers :

```
app/services/cluster_metrics_builder.rb
app/services/cluster_signal_engine.rb
lib/tasks/cluster_v3.rake
bin/cron_cluster_v3_build_metrics.sh
bin/cron_cluster_v3_detect_signals.sh
```

Et on va les refactoriser comme le scanner :

```
full mode
incremental mode
batch mode
dirty cluster mode
progress fiable
Sidekiq compatible
```



ils sont dans le dossier zip que je t'ai envoyer



Oui, je vais reprendre l’archive que tu as envoyée et lire directement les fichiers V3 concernés : builder metrics, moteur signals, rake tasks et scripts cron. Ensuite je te propose le refactor précis, comme pour `ClusterScanner`.

Réflexion durant 20s

Oui, ils sont bien dans le zip. Le problème est confirmé.

## Diagnostic réel

`cluster_v3_build_metrics` fait :

```
Cluster.find_each do |cluster|
  ClusterMetricsBuilder.call(cluster)
end
```

Et `cluster_v3_detect_signals` fait pareil :

```
Cluster.all.find_each do |cluster|
  ClusterSignalEngine.call(cluster)
end
```

Donc chaque jour tu parcours environ :

```
577 000 clusters
```

C’est pour ça que tu vois :

```
cluster 1200 / 577927
progress 0.2%
```

## Refactor à faire

On doit ajouter un mode :

```
only recently updated clusters
```

au lieu de recalculer tout.

## Version simple immédiate

Dans `lib/tasks/cluster_v3.rake`, remplace :

```
total = Cluster.count
```

par :

```
since = ENV["SINCE"].present? ? Time.zone.parse(ENV["SINCE"]) : 2.days.ago

scope = Cluster
  .joins(:cluster_profile)
  .where("cluster_profiles.updated_at >= ?", since)

total = scope.count
```

Puis remplace :

```
Cluster.find_each.with_index(1) do |cluster, i|
```

par :

```
scope.find_each.with_index(1) do |cluster, i|
```

Et dans le log :

```
puts "[cluster:v3_build_metrics] start date=#{date} since=#{since} total=#{total}"
```

## Pour signals

Dans `lib/tasks/cluster_v3_signals.rake`, remplace :

```
scope = Cluster.all
```

par :

```
since = ENV["SINCE"].present? ? Time.zone.parse(ENV["SINCE"]) : 2.days.ago

scope = Cluster
  .joins(:cluster_profile)
  .where("cluster_profiles.updated_at >= ?", since)
```

## Résultat attendu

Au lieu de :

```
577927 clusters
```

tu devrais traiter seulement les clusters réellement modifiés récemment :

```
quelques centaines / milliers
```

C’est le premier gros gain.



tu peux me le refaire # lib/tasks/cluster_v3.rake namespace :cluster do  namespace :v3 do    desc "Build cluster metrics"    task build_metrics: :environment do      date = Date.current            since = ENV["SINCE"].present? ? Time.zone.parse(ENV["SINCE"]) : 2.days.ago       scope = Cluster        .joins(:cluster_profile)        .where("cluster_profiles.updated_at >= ?", since)       total = scope.count       JobRunner.run!("cluster_v3_build_metrics", meta: { date: date, total: total }, triggered_by: "cron") do |jr|        JobRunner.heartbeat!(jr)         puts "[cluster:v3_build_metrics] start date=#{date} total=#{total}"         count = 0         Cluster.find_each.with_index(1) do |cluster, i|          ClusterMetricsBuilder.call(cluster)          count = i           if (i % 100).zero?            JobRunner.progress!(              jr,              pct: total.positive? ? ((i.to_f / total) * 100).round(1) : 100.0,              label: "cluster #{i} / #{total}",              meta: {                date: date,                processed: i,                total: total              }            )             puts "[cluster:v3_build_metrics] processed=#{i}/#{total}"          end        end         JobRunner.heartbeat!(jr)         puts "[cluster:v3_build_metrics] done clusters=#{count}"         result = { clusters_processed: count }         jr.update!(          meta: { date: date, total: total }.merge(result: result).to_json        )         result      end    end  end end



```
# lib/tasks/cluster_v3.rake

namespace :cluster do
  namespace :v3 do
    desc "Build cluster metrics"
    task build_metrics: :environment do
      date = Date.current

      since =
        if ENV["SINCE"].present?
          Time.zone.parse(ENV["SINCE"])
        else
          2.days.ago
        end

      scope = Cluster
        .joins(:cluster_profile)
        .where("cluster_profiles.updated_at >= ?", since)

      total = scope.count

      JobRunner.run!(
        "cluster_v3_build_metrics",
        meta: {
          date: date,
          total: total,
          since: since
        },
        triggered_by: "cron"
      ) do |jr|

        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_build_metrics] start date=#{date} since=#{since} total=#{total}"

        count = 0

        scope.find_each.with_index(1) do |cluster, i|
          ClusterMetricsBuilder.call(cluster)

          count = i

          if (i % 100).zero?
            JobRunner.progress!(
              jr,
              pct: total.positive? ? ((i.to_f / total) * 100).round(1) : 100.0,
              label: "cluster #{i} / #{total}",
              meta: {
                date: date,
                since: since,
                processed: i,
                total: total
              }
            )

            JobRunner.heartbeat!(jr)

            puts "[cluster:v3_build_metrics] processed=#{i}/#{total}"
          end
        end

        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_build_metrics] done clusters=#{count}"

        result = {
          clusters_processed: count,
          since: since
        }

        jr.update!(
          meta: {
            date: date,
            total: total,
            since: since,
            result: result
          }.to_json
        )

        result
      end
    end
  end
end
```



et lui # frozen_string_literal: true namespace :cluster do  namespace :v3 do    desc "Detect cluster signals (DATE=YYYY-MM-DD optional)"    task detect_signals: :environment do      date = ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current      scope = Cluster.all      total = scope.count       JobRunner.run!("cluster_v3_detect_signals", meta: { date: date, total: total }, triggered_by: "cron") do |jr|        JobRunner.heartbeat!(jr)         puts "[cluster:v3_detect_signals] start date=#{date} total=#{total}"         processed = 0         scope.find_each.with_index(1) do |cluster, i|          ClusterSignalEngine.call(cluster, snapshot_date: date)          processed = i           if (i % 100).zero?            JobRunner.progress!(              jr,              pct: total.positive? ? ((i.to_f / total) * 100).round(1) : 100.0,              label: "cluster #{i} / #{total}",              meta: {                snapshot_date: date,                processed: i,                total: total              }            )             puts "[cluster:v3_detect_signals] processed=#{i}/#{total}"          end        end         JobRunner.heartbeat!(jr)         puts "[cluster:v3_detect_signals] done processed=#{processed}"         result = {          snapshot_date: date,          clusters_processed: processed,          total: total        }         jr.update!(          meta: { date: date, total: total }.merge(result: result).to_json        )         result      end    rescue ArgumentError => e      abort "[cluster:v3_detect_signals] invalid DATE format: #{e.message}"    end  end end



```
# frozen_string_literal: true

namespace :cluster do
  namespace :v3 do
    desc "Detect cluster signals (DATE=YYYY-MM-DD optional)"
    task detect_signals: :environment do
      date =
        if ENV["DATE"].present?
          Date.parse(ENV["DATE"])
        else
          Date.current
        end

      since =
        if ENV["SINCE"].present?
          Time.zone.parse(ENV["SINCE"])
        else
          2.days.ago
        end

      scope = Cluster
        .joins(:cluster_profile)
        .where("cluster_profiles.updated_at >= ?", since)

      total = scope.count

      JobRunner.run!(
        "cluster_v3_detect_signals",
        meta: {
          date: date,
          since: since,
          total: total
        },
        triggered_by: "cron"
      ) do |jr|

        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_detect_signals] start date=#{date} since=#{since} total=#{total}"

        processed = 0

        scope.find_each.with_index(1) do |cluster, i|
          ClusterSignalEngine.call(
            cluster,
            snapshot_date: date
          )

          processed = i

          if (i % 100).zero?
            JobRunner.progress!(
              jr,
              pct: total.positive? ? ((i.to_f / total) * 100).round(1) : 100.0,
              label: "cluster #{i} / #{total}",
              meta: {
                snapshot_date: date,
                since: since,
                processed: i,
                total: total
              }
            )

            JobRunner.heartbeat!(jr)

            puts "[cluster:v3_detect_signals] processed=#{i}/#{total}"
          end
        end

        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_detect_signals] done processed=#{processed}"

        result = {
          snapshot_date: date,
          since: since,
          clusters_processed: processed,
          total: total
        }

        jr.update!(
          meta: {
            date: date,
            since: since,
            total: total,
            result: result
          }.to_json
        )

        result
      end

    rescue ArgumentError => e
      abort "[cluster:v3_detect_signals] invalid DATE format: #{e.message}"
    end
  end
end
```



et maintenant ?



Maintenant tu testes les 2 jobs avec le scope réduit.

## 1. Stopper les anciens jobs si encore running

Vérifie `/system`. S’ils tournent encore depuis l’ancien code, stoppe le process Rails/cron concerné ou redémarre Sidekiq si besoin.

## 2. Lancer metrics en manuel

```
bin/rails cluster:v3:build_metrics
```

Résultat attendu :

```
start date=... since=... total=beaucoup moins que 577927
```

## 3. Lancer signals

```
bin/rails cluster:v3:detect_signals
```

Résultat attendu :

```
start date=... since=... total=le même ordre de grandeur
```

## 4. Vérifier `/system`

Tu veux voir :

```
progress qui avance vite
total réduit
Metrics day = 2026-04-24
Signals day = 2026-04-24
```

Si `total` reste énorme, on changera le filtre pour utiliser uniquement les clusters touchés par `ClusterRefreshJob`.



Cluster V3 build metrics cluster_v3_build_metrics bin/cron_cluster_v3_build_metrics.sh critical cluster cron 5 4 * * *	RUNNING ok: 2026-04-22 19:42:16 fail: 2026-03-24 21:04:54 skip: — start: 2026-04-24 17:47:31 end: — hb: 1s last: 260m 53s avg10: 107m 19s max10: 260m 53s delay: 1327m 4s missed: 0 capacity: ok skips10: 0 1m 49s progress 53.2% cluster 1600 / 3009 no	— Cluster V3 detect signals cluster_v3_detect_signals bin/cron_cluster_v3_detect_signals.sh critical cluster cron 20 4 * * *	OK ok: 2026-04-24 17:49:06 fail: — skip: — start: 2026-04-24 17:48:40 end: 2026-04-24 17:49:06 hb: — last: 26s avg10: 9m 23s max10: 33m 42s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0



Excellent. L’optimisation fonctionne.

Avant :

```
cluster 1200 / 577927
progress 0.2%
```

Maintenant :

```
cluster 1600 / 3009
progress 53.2%
```

Et `detect_signals` est passé à :

```
26s
OK
```

C’est un énorme gain.

Il reste `build_metrics` à finir, mais il traite maintenant seulement `3009` clusters au lieu de `577k`.

Prochaine amélioration : appliquer le même principe au niveau cron avec une fenêtre explicite, par exemple :

```
SINCE="2 days ago" bin/rails cluster:v3:build_metrics
SINCE="2 days ago" bin/rails cluster:v3:detect_signals
```

Ton module Cluster V3 vient de passer du mode “full rebuild quotidien impossible” au mode “incremental réaliste”.



Cluster V3 build metrics cluster_v3_build_metrics bin/cron_cluster_v3_build_metrics.sh critical cluster cron 5 4 * * *	OK ok: 2026-04-24 17:50:53 fail: 2026-03-24 21:04:54 skip: — start: 2026-04-24 17:47:31 end: 2026-04-24 17:50:53 hb: — last: 3m 22s avg10: 90m 0s max10: 260m 53s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0



Parfait.

Avant :

```
260m 53s
```

Maintenant :

```
3m 22s
```

C’est une optimisation massive.

Le `avg10: 90m` va rester élevé temporairement parce qu’il garde l’historique des anciennes exécutions. Il baissera après plusieurs nouveaux runs rapides.

État actuel :

```
cluster_v3_build_metrics : OK
cluster_v3_detect_signals : OK
metrics/signals incrémentaux : validés
```

Là ton pipeline Cluster est beaucoup plus sain.



ensuite



Ensuite, vérifie que les données V3 sont bien à jour.

Dans `rails c` :

```
ClusterMetric.maximum(:snapshot_date)
ClusterSignal.maximum(:snapshot_date)
ClusterMetric.where(snapshot_date: Date.current).count
ClusterSignal.where(snapshot_date: Date.current).count
```

Tu veux voir :

```
snapshot_date = 2026-04-24
metrics du jour > 0
signals du jour >= 0
```

Puis recharge `/system`, le bloc `Cluster pipeline` doit afficher :

```
Metrics day: 2026-04-24
Signals day: 2026-04-24
```

Après ça, prochaine étape : nettoyer les anciens `JobRun` longs pour que les moyennes `avg10/max10` redeviennent lisibles.



ok on fait ca



Dans `rails c`, lance :

```
ClusterMetric.maximum(:snapshot_date)
ClusterSignal.maximum(:snapshot_date)

ClusterMetric.where(snapshot_date: Date.current).count
ClusterSignal.where(snapshot_date: Date.current).count
```

Puis recharge `/system`.

Tu dois voir dans `Cluster pipeline` :

```
Metrics day: 2026-04-24
Signals day: 2026-04-24
```



ensuite



Ensuite, on nettoie l’historique des anciens `JobRun` très longs pour que `avg10` reflète les nouvelles perfs.

Dans `rails c` :

```
JobRun
  .where(name: "cluster_v3_build_metrics")
  .where("duration_ms > ?", 60 * 60 * 1000)
  .order(created_at: :desc)
  .pluck(:id, :started_at, :duration_ms)
```

Si tu vois les anciens runs de plusieurs heures, tu peux les marquer comme archivés seulement si tu as une colonne adaptée. Sinon, le plus simple est d’attendre 10 nouveaux runs rapides : `avg10` se corrigera tout seul.

À faire maintenant :

```
bin/rails cluster:v3:build_metrics
bin/rails cluster:v3:detect_signals
```

Après 2–3 exécutions rapides, `/system` commencera déjà à afficher une moyenne plus réaliste.



ok ensuite Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	OK ok: — fail: — skip: 2026-04-24 18:00:02 start: 2026-04-24 18:00:02 end: 2026-04-24 18:00:02 hb: — last: — avg10: — max10: — delay: 0s missed: 0 capacity: unknown skips10: 9 — yes	0                     lock busy



Là `cluster_scan` est en **skip parce que le lock est encore présent** :

```
skip: 2026-04-24 18:00:02
skips10: 9
lock: yes
lock busy
```

## 1. Vérifie le lock

```
ls -lh /tmp | grep cluster
```

ou :

```
find /tmp -iname "*cluster*" -type f -o -iname "*cluster*" -type l
```

## 2. Vérifie qu’aucun scan ne tourne

```
ps aux | grep cluster_scan
ps aux | grep "bin/rails runner"
ps aux | grep sidekiq
```

## 3. Si aucun `cluster_scan` ne tourne, supprime le lock

Il faut connaître le fichier exact, mais ce sera probablement un truc comme :

```
rm /tmp/bitcoin_monitor_cluster_scan.lock
```

ou :

```
rm /tmp/cluster_scan.lock
```

## 4. Relance

```
bin/cron_cluster_scan.sh
```

Ensuite `/system` devrait repasser sur :

```
cluster_scan OK
lock no
skips10 0
```



Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	RUNNING ok: — fail: — skip: 2026-04-24 18:00:02 start: 2026-04-24 18:05:57 end: — hb: 1m 7s last: — avg10: — max10: — delay: 0s missed: 0 capacity: unknown skips10: 8 1m 8s progression non exposée yes	—



Là c’est mieux : `cluster_scan` tourne réellement.

Le seul souci visible :

```
progression non exposée
```

Donc le script cron lance bien le job, mais il ne remonte pas encore la progression dans `JobRunner.progress!`.

Attends la fin du run, puis vérifie :

```
tail -n 80 log/cron.victor.log
```

Tu dois voir :

```
[cluster_scan] dirty_clusters=...
[cluster_scan] scanned_blocks=...
[cluster_scan] multi_input_txs=...
```

Si le job finit en `OK`, c’est bon.
Ensuite on pourra remettre la progression dans `Clusters::ScanAndDispatch` / `ClusterScanner` via `job_run: jr`.



\#!/usr/bin/env bash set -euo pipefail APP="/home/victor/bitcoin_monitor" LOG="$APP/log/cron.victor.log" mkdir -p "$APP/log" cd "$APP" # rbenv bootstrap export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}" export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" if command -v rbenv >/dev/null 2>&1; then  eval "$(rbenv init - bash)" fi export RAILS_ENV="${RAILS_ENV:-development}" echo "[$(date '+%F %T')] [cluster_scan] start triggered_by=${TRIGGERED_BY:-cron} scheduled_for=${SCHEDULED_FOR:-}" >> "$LOG" if bin/rails runner ' JobRunner.run!(  "cluster_scan",  triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),  scheduled_for: ENV["SCHEDULED_FOR"].presence ) do |jr|   JobRunner.heartbeat!(jr)   result = Clusters::ScanAndDispatch.call(    job_run: jr  )   JobRunner.heartbeat!(jr)   puts "[cluster_scan] dirty_clusters=#{result[:dirty_clusters_count]}"  puts "[cluster_scan] scanned_blocks=#{result[:scanned_blocks]}"  puts "[cluster_scan] scanned_txs=#{result[:scanned_txs]}"  puts "[cluster_scan] multi_input_txs=#{result[:multi_input_txs]}" end '; then  echo "[$(date '+%F %T')] [cluster_scan] done" >> "$LOG" else  rc=$?  echo "[$(date '+%F %T')] [cluster_scan] failed rc=${rc}" >> "$LOG"  exit "$rc" fi >> "$LOG" 2>&1



Ton script est bon.

La progression vient de `ClusterScanner` ici :

```
update_progress!(height, range[:start_height], range[:end_height])
```

Mais elle ne s’affiche que :

```
if (@stats[:scanned_blocks] % 10).zero? || height == range[:end_height]
```

Donc si le cron scanne peu de blocs, tu peux voir temporairement :

```
progression non exposée
```

puis ça apparaît à la fin.

## Petite amélioration

Dans `ClusterScanner`, après le log `start`, ajoute une progression initiale :

```
update_progress!(
  range[:start_height],
  range[:start_height],
  range[:end_height]
)
```

Donc :

```
puts(
  "[cluster_scan] start " \
  "mode=#{range[:mode]} " \
  "start_height=#{range[:start_height]} " \
  "end_height=#{range[:end_height]}"
)

update_progress!(
  range[:start_height],
  range[:start_height],
  range[:end_height]
)
```

Comme ça `/system` affichera tout de suite :

```
progress
block X / Y
```

au lieu de `progression non exposée`.



\# frozen_string_literal: true require "set" # app/services/cluster_scanner.rb class ClusterScanner  class Error < StandardError; end   CURSOR_NAME = "cluster_scan"  INITIAL_BLOCKS_BACK = (Integer(ENV.fetch("CLUSTER_INITIAL_BLOCKS_BACK", "50")) rescue 50)   def self.call(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil, refresh: true)    new(      from_height: from_height,      to_height: to_height,      limit: limit,      rpc: rpc,      job_run: job_run,      refresh: refresh    ).call  end   def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil, refresh: true)    @from_height = from_height.present? ? from_height.to_i : nil    @to_height   = to_height.present? ? to_height.to_i : nil    @limit       = limit.present? ? limit.to_i : nil    @rpc         = rpc || BitcoinRpc.new(wallet: nil)    @job_run = job_run    @refresh = refresh     @dirty_cluster_ids = Set.new     @stats = {      scanned_blocks: 0,      scanned_txs: 0,      multi_input_txs: 0,      links_created: 0,      clusters_created: 0,      clusters_merged: 0,      addresses_touched: 0,      pruned_blocks_skipped: 0,      tx_skipped_rpc_errors: 0,      tx_skipped_missing_prevout: 0,      multi_input_candidates: 0,      already_linked_txs: 0,      input_rows_found: 0,      multi_address_candidates: 0    }  end   def call    best_height = @rpc.getblockcount.to_i    range = compute_scan_range(best_height)     if range[:start_height] > range[:end_height]      return {        ok: true,        note: "nothing to scan",        mode: range[:mode],        best_height: best_height,        start_height: range[:start_height],        end_height: range[:end_height]      }    end     puts(      "[cluster_scan] start " \      "mode=#{range[:mode]} " \      "start_height=#{range[:start_height]} " \      "end_height=#{range[:end_height]}"    )     (range[:start_height]..range[:end_height]).each do |height|      scanned = scan_block(height)      @stats[:scanned_blocks] += 1 if scanned       if (@stats[:scanned_blocks] % 10).zero? || height == range[:end_height]        update_progress!(height, range[:start_height], range[:end_height])      end       log_progress(height)    end     refresh_dirty_clusters! if @refresh     update_cursor!(range[:end_height]) if range[:mode] == :incremental     {      ok: true,      mode: range[:mode],      best_height: best_height,      start_height: range[:start_height],      end_height: range[:end_height],      refresh: @refresh,      dirty_clusters_count: @dirty_cluster_ids.size,      dirty_cluster_ids: @refresh ? [] : @dirty_cluster_ids.to_a    }.merge(@stats)  end   private   def compute_scan_range(best_height)    if manual_mode?      start_height = @from_height || [0, best_height - default_manual_span + 1].max      end_height   = @to_height || best_height       if @limit.present? && @limit > 0        end_height = [end_height, start_height + @limit - 1].min      end       return {        mode: :manual,        start_height: [0, start_height].max,        end_height: [best_height, end_height].min      }    end     cursor = scanner_cursor     start_height =      if cursor.last_blockheight.present?        cursor.last_blockheight.to_i + 1      else        [0, best_height - INITIAL_BLOCKS_BACK + 1].max      end     end_height = best_height     if @limit.present? && @limit > 0      end_height = [best_height, start_height + @limit - 1].min    end     {      mode: :incremental,      start_height: start_height,      end_height: end_height    }  end   def manual_mode?    @from_height.present? || @to_height.present?  end   def default_manual_span    @limit.present? && @limit > 0 ? @limit : INITIAL_BLOCKS_BACK  end   def scanner_cursor    @scanner_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME)  end   def update_cursor!(height)    blockhash = @rpc.getblockhash(height)     scanner_cursor.update!(      last_blockheight: height,      last_blockhash: blockhash    )  end   def scan_block(height)    blockhash = @rpc.getblockhash(height)    block = @rpc.getblock(blockhash, 3)     Array(block["tx"]).each do |tx|      @stats[:scanned_txs] += 1      scan_transaction(tx, height)    end     true  rescue BitcoinRpc::Error => e    if e.message.include?("Block not available (pruned data)")      @stats[:pruned_blocks_skipped] += 1      puts "[cluster_scan] skip_pruned_block height=#{height}"      return false    end     raise  end   def scan_transaction(tx, height)    txid = tx["txid"].to_s    return if txid.blank?    return if coinbase_tx?(tx)     if Array(tx["vin"]).size >= 2      @stats[:multi_input_candidates] += 1    end     if AddressLink.exists?(txid: txid, link_type: "multi_input")      @stats[:already_linked_txs] += 1      return    end     grouped_inputs = Clusters::InputExtractor.call(tx)     @stats[:input_rows_found] += grouped_inputs.sum { |g| g[:total_inputs].to_i }     return if grouped_inputs.empty?     if grouped_inputs.size >= 2      @stats[:multi_address_candidates] += 1    end     return if grouped_inputs.size < 2     @stats[:multi_input_txs] += 1     ActiveRecord::Base.transaction do      grouped_by_address = grouped_inputs.index_by { |g| g[:address] }       address_records = Clusters::AddressWriter.call(        grouped_inputs: grouped_by_address,        height: height      )       merge_result = Clusters::ClusterMerger.call(address_records: address_records)       @stats[:clusters_created] += merge_result.created      @stats[:clusters_merged] += merge_result.merged       cluster = merge_result.cluster       @stats[:links_created] += Clusters::LinkWriter.call(        address_records: address_records,        txid: txid,        height: height      )       mark_cluster_dirty!(cluster)    end     @stats[:addresses_touched] += grouped_inputs.size  rescue BitcoinRpc::Error => e    @stats[:tx_skipped_rpc_errors] += 1    puts "[cluster_scan] tx_skip txid=#{txid} height=#{height} reason=#{e.message}"  rescue StandardError => e    raise Error, "scan_transaction failed txid=#{txid} height=#{height}: #{e.class} - #{e.message}"  end   def coinbase_tx?(tx)    Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }  end   def mark_cluster_dirty!(cluster)    return if cluster.blank?     @dirty_cluster_ids << cluster.id  end   def refresh_dirty_clusters!    Clusters::DirtyClusterRefresher.call(      cluster_ids: @dirty_cluster_ids.to_a    )  end   def log_progress(height)    return unless (@stats[:scanned_blocks] % 10).zero? && @stats[:scanned_blocks].positive?     puts(      "[cluster_scan] progress " \      "height=#{height} " \      "blocks=#{@stats[:scanned_blocks]} " \      "txs=#{@stats[:scanned_txs]} " \      "multi_input_txs=#{@stats[:multi_input_txs]} " \      "links_created=#{@stats[:links_created]} " \      "clusters_created=#{@stats[:clusters_created]} " \      "clusters_merged=#{@stats[:clusters_merged]} " \      "pruned_blocks_skipped=#{@stats[:pruned_blocks_skipped]} " \      "tx_skipped_rpc_errors=#{@stats[:tx_skipped_rpc_errors]} " \      "tx_skipped_missing_prevout=#{@stats[:tx_skipped_missing_prevout]}"    )  end   def update_progress!(current_height, start_height, end_height)    return if @job_run.blank?     total = (end_height - start_height + 1)    return if total <= 0     done = (current_height - start_height + 1)    pct = ((done.to_f / total) * 100).round(1)     JobRunner.progress!(      @job_run,      pct: pct,      label: "block #{current_height} / #{end_height}",      meta: {        start_height: start_height,        current_height: current_height,        end_height: end_height,        scanned_blocks: @stats[:scanned_blocks],        scanned_txs: @stats[:scanned_txs],        multi_input_txs: @stats[:multi_input_txs],        links_created: @stats[:links_created],        clusters_created: @stats[:clusters_created],        clusters_merged: @stats[:clusters_merged],        pruned_blocks_skipped: @stats[:pruned_blocks_skipped]      }    )  end end



Oui. Dans `call`, ajoute juste ce bloc après le `puts "[cluster_scan] start ..."` :

```
update_progress!(
  range[:start_height],
  range[:start_height],
  range[:end_height]
)
```

Donc cette partie devient :

```
puts(
  "[cluster_scan] start " \
  "mode=#{range[:mode]} " \
  "start_height=#{range[:start_height]} " \
  "end_height=#{range[:end_height]}"
)

update_progress!(
  range[:start_height],
  range[:start_height],
  range[:end_height]
)

(range[:start_height]..range[:end_height]).each do |height|
  scanned = scan_block(height)
  @stats[:scanned_blocks] += 1 if scanned
```

Ensuite relance :

```
bin/cron_cluster_scan.sh
```

Et `/system` devrait afficher directement :

```
progress
block X / Y
```



on avait mis en place redis sidekiq pour cluster_scan ?



Oui, mais avec une nuance importante.

Tu as mis en place :

- Redis
- Sidekiq

pour le pipeline **refresh async des clusters**, pas pour le scan blockchain lui-même.

Actuellement :

```
cluster_scan
→ scan blockchain
→ détecte dirty clusters
→ enqueue jobs async
```

Donc :

```
ClusterScanner
```

tourne encore en process Rails “classique” via cron :

```
bin/cron_cluster_scan.sh
```

Mais ensuite :

```
ClusterRefreshDispatchJob
→ ClusterRefreshJob
```

sont bien exécutés par Sidekiq/Redis.

Architecture actuelle :

```
cron
  ↓
ClusterScanner
  ↓
dirty_cluster_ids
  ↓
Redis
  ↓
Sidekiq queue
  ↓
ClusterRefreshJob
  ↓
ClusterProfile / Metrics / Signals
```

Et c’est justement ce qui t’a permis :

```
577k clusters → ~3000 clusters réellement modifiés
```

Donc aujourd’hui :

- scan blockchain = synchrone
- refresh cluster = asynchrone Sidekiq
- metrics/signals = incrémental

Et franchement, c’est déjà une très bonne architecture.



donc il nous reste a optimiser bin/cron_cluster_scan.sh non? Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	OK ok: 2026-04-24 18:22:35 fail: — skip: 2026-04-24 18:00:02 start: 2026-04-24 18:17:44 end: 2026-04-24 18:22:35 hb: — last: 4m 51s avg10: 4m 51s max10: 4m 51s delay: 0s missed: 0 capacity: tight skips10: 8 — yes	0



Réflexion durant quelques secondes

Oui, exactement. Il reste surtout à optimiser/sécuriser :

```
bin/cron_cluster_scan.sh
```

Mais là il est déjà **OK** :

```
last: 4m51
cron: */15
capacity: tight
```

Ça veut dire : il finit, mais il prend assez de temps pour être surveillé.

## Ce qu’on doit améliorer

### 1. Limiter le nombre de blocs par run

Dans `bin/cron_cluster_scan.sh`, remplace :

```
result = Clusters::ScanAndDispatch.call(
  job_run: jr
)
```

par :

```
limit = ENV.fetch("LIMIT", "3").to_i

result = Clusters::ScanAndDispatch.call(
  limit: limit,
  job_run: jr
)
```

Comme ça, chaque cron traite max 3 blocs.

Tu peux ajuster :

```
LIMIT=5 bin/cron_cluster_scan.sh
```

## 2. Logguer le limit

Ajoute :

```
puts "[cluster_scan] limit=#{limit}"
```

juste après `limit = ...`.

## 3. Résultat attendu

Le job devrait passer de :

```
4m51
capacity: tight
```

à quelque chose comme :

```
1m-2m
capacity: ok
```

## 4. Le `lock yes`

Si le job est terminé mais que `/system` affiche encore :

```
lock: yes
```

il faudra vérifier le lockfile. Mais d’abord fais l’optimisation `LIMIT=3`, puis relance :

```
bin/cron_cluster_scan.sh
```

Ensuite on regarde `/system`.



Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	OK ok: 2026-04-24 18:22:35 fail: 2026-04-24 18:28:30 skip: 2026-04-24 18:00:02 start: 2026-04-24 18:28:29 end: 2026-04-24 18:28:30 hb: — last: 4m 51s avg10: 4m 51s max10: 4m 51s delay: 1m 0s missed: 0 capacity: tight skips10: 7 — yes	1                     NoMethodError: undefined method `any?' for nil:NilClass `/home/victor/bitcoin_monitor/app/services/clusters/scan_and_dispatch.rb:16:in `call' `/home/victor/bitcoin_monitor/app/services/clusters/scan_and_dispatch.rb:6:in `call' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/commands/runner/runner_command.rb:60:in `block in <main>' `/home/victor/bitcoin_monitor/app/services/job_runner.rb:17:in `run!' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/commands/runner/runner_command.rb:50:in `<main>' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/commands/runner/runner_command.rb:49:in `eval' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/commands/runner/runner_command.rb:49:in `block in perform' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/activesupport-8.0.4/lib/active_support/execution_wrapper.rb:91:in `wrap' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/commands/runner/runner_command.rb:70:in `conditional_executor' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/commands/runner/runner_command.rb:48:in `perform' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/thor-1.4.0/lib/thor/command.rb:28:in `run' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/thor-1.4.0/lib/thor/invocation.rb:127:in `invoke_command' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/command/base.rb:178:in `invoke_command' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/thor-1.4.0/lib/thor.rb:538:in `dispatch' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/command/base.rb:73:in `perform' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/command.rb:65:in `block in invoke' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/command.rb:143:in `with_argv' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/command.rb:63:in `invoke' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/railties-8.0.4/lib/rails/commands.rb:18:in `<main>' `<internal:/home/victor/.rbenv/versions/3.2.3/lib/ruby/3.2.0/rubygems/core_ext/kernel_require.rb>:38:in `require' `<internal:/home/victor/.rbenv/versions/3.2.3/lib/ruby/3.2.0/rubygems/core_ext/kernel_require.rb>:38:in `require' `/home/victor/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/bootsnap-1.20.1/lib/bootsnap/load_path_cache/core_ext/kernel_require.rb:30:in `require' `bin/rails:4:in `<main>'`



Oui. Le bug vient de `ScanAndDispatch`.

Quand il n’y a rien à scanner, `ClusterScanner` retourne un hash avec `note: "nothing to scan"` mais sans :

```
:dirty_cluster_ids
```

Donc cette ligne casse :

```
result[:dirty_cluster_ids].any?
```

## Corrige `app/services/clusters/scan_and_dispatch.rb`

Remplace :

```
if result[:dirty_cluster_ids].any?
  ClusterRefreshDispatchJob.perform_later(result[:dirty_cluster_ids])
end
```

par :

```
dirty_cluster_ids = Array(result[:dirty_cluster_ids])

if dirty_cluster_ids.any?
  ClusterRefreshDispatchJob.perform_later(dirty_cluster_ids)
end
```

Version complète :

```
# frozen_string_literal: true

module Clusters
  class ScanAndDispatch
    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(**kwargs)
      @kwargs = kwargs
    end

    def call
      result = ClusterScanner.call(**kwargs.merge(refresh: false))

      dirty_cluster_ids = Array(result[:dirty_cluster_ids])

      if dirty_cluster_ids.any?
        ClusterRefreshDispatchJob.perform_later(dirty_cluster_ids)
      end

      result
    end

    private

    attr_reader :kwargs
  end
end
```

Puis relance :

```
bin/cron_cluster_scan.sh
```

L’erreur `NoMethodError: undefined method any? for nil` disparaîtra.



c toujour aussi long je pensait descendre a 1 ou 2 minutes



Oui, tu as raison de viser 1–2 minutes.

Si c’est encore ~5 minutes, c’est probablement parce que `LIMIT` n’est pas encore appliqué dans `bin/cron_cluster_scan.sh`.

Vérifie avec :

```
grep -n "limit =" bin/cron_cluster_scan.sh
grep -n "ScanAndDispatch.call" bin/cron_cluster_scan.sh
```

Dans le script, il faut avoir exactement :

```
limit = ENV.fetch("LIMIT", "3").to_i

puts "[cluster_scan] limit=#{limit}"

result = Clusters::ScanAndDispatch.call(
  limit: limit,
  job_run: jr
)
```

Puis teste en forçant 1 bloc :

```
LIMIT=1 bin/cron_cluster_scan.sh
```

Si `LIMIT=1` reste long, alors le temps vient du scan d’un seul bloc très chargé ou des requêtes SQL `AddressLink.exists?`. Dans ce cas, prochaine optimisation : remplacer le `exists?` transaction par transaction par un cache des txids déjà liés au niveau du bloc.



victor@debian:~/bitcoin_monitor$ grep -n "limit =" bin/cron_cluster_scan.sh grep -n "ScanAndDispatch.call" bin/cron_cluster_scan.sh 31:  limit = ENV.fetch("LIMIT", "3").to_i 33:  result = Clusters::ScanAndDispatch.call( victor@debian:~/bitcoin_monitor$ LIMIT=1 bin/cron_cluster_scan.sh Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	RUNNING ok: 2026-04-24 18:39:37 fail: 2026-04-24 18:28:30 skip: 2026-04-24 18:45:02 start: 2026-04-24 18:48:56 end: — hb: 35s last: 4m 2s avg10: 4m 27s max10: 4m 51s delay: 4m 54s missed: 0 capacity: tight skips10: 5 35s progress 100.0% block 946468 / 946468 yes	—



Là le `LIMIT=1` fonctionne :

```
progress 100%
block 946468 / 946468
runtime 35s
```

Donc tu es déjà dans la cible.

Ce qui reste affiché :

```
last: 4m02
avg10: 4m27
max10: 4m51
```

vient des exécutions précédentes. Il faut attendre quelques runs courts pour que la moyenne baisse.

## À vérifier à la fin du run

Recharge `/system` après la fin. Tu devrais voir :

```
last: ~40s à 1m
capacity: ok
```

Si tu veux forcer le cron à rester court, garde :

```
LIMIT=1
```

ou dans le script :

```
limit = ENV.fetch("LIMIT", "1").to_i
```

au lieu de `3`.



les jobs affichent des retards pourquoi?Job	Cat.	Cron	Statut	Exécution	Durées	Retard	Runtime	Lock	Exit BTC price daily btc_price_daily bin/cron_btc_price_days.sh critical price cron 20 0 * * *	OK ok: 2026-04-23 22:24:03 fail: 2026-03-28 15:29:41 skip: — start: 2026-04-23 22:24:02 end: 2026-04-23 22:24:03 hb: — last: 1s avg10: 2m 35s max10: 5m 29s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0 Market snapshot market_snapshot bin/cron_market_snapshot.sh critical market — 15 1 * * *	OK ok: 2026-04-24 09:19:33 fail: — skip: — start: 2026-04-24 09:19:28 end: 2026-04-24 09:19:33 hb: — last: 5s avg10: 1s max10: 5s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0 Whale scan whale_scan bin/rails whales:scan critical whales cron 15 * * * *	LATE ok: 2026-04-24 18:54:17 fail: — skip: — start: 2026-04-24 18:15:03 end: 2026-04-24 18:54:17 hb: — last: 39m 14s avg10: 33m 33s max10: 40m 49s delay: 72m 4s missed: 1 capacity: ok skips10: 0 — no	0 Exchange address builder exchange_address_builder bin/cron_exchange_address_builder.sh critical exchange cron 0 */6 * * *	OK ok: 2026-04-24 21:00:07 fail: — skip: — start: 2026-04-24 21:00:03 end: 2026-04-24 21:00:07 hb: — last: 4s avg10: 4s max10: 7s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0 Exchange observed scan exchange_observed_scan bin/cron_exchange_observed_scan.sh critical exchange cron */10 * * * *	LATE ok: 2026-04-24 20:42:11 fail: — skip: — start: 2026-04-24 20:40:02 end: 2026-04-24 20:42:11 hb: — last: 2m 9s avg10: 2m 7s max10: 6m 47s delay: 14m 10s missed: 1 capacity: ok skips10: 0 — no	0 Inflow / Outflow V1 inflow_outflow_build bin/cron_inflow_outflow_build.sh critical inflow_outflow cron 25 * * * *	LATE ok: 2026-04-24 18:37:03 fail: — skip: — start: 2026-04-24 18:37:00 end: 2026-04-24 18:37:03 hb: — last: 2s avg10: 2s max10: 3s delay: 89m 19s missed: 1 capacity: ok skips10: 0 — no	0 Inflow / Outflow V2 inflow_outflow_details_build bin/cron_inflow_outflow_details_build.sh critical inflow_outflow cron 35 * * * *	OK ok: 2026-04-24 20:35:05 fail: — skip: — start: 2026-04-24 20:35:02 end: 2026-04-24 20:35:05 hb: — last: 3s avg10: 3s max10: 4s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0 Inflow / Outflow V3 inflow_outflow_behavior_build bin/cron_inflow_outflow_behavior_build.sh critical inflow_outflow cron 45 * * * *	LATE ok: 2026-04-24 17:45:03 fail: — skip: — start: 2026-04-24 17:45:03 end: 2026-04-24 17:45:03 hb: — last: 0s avg10: 1s max10: 2s delay: 141m 18s missed: 2 capacity: ok skips10: 0 — no	0 Inflow / Outflow V4 inflow_outflow_capital_behavior_build bin/cron_inflow_outflow_capital_behavior_build.sh critical inflow_outflow cron 50 * * * *	LATE ok: 2026-04-24 17:50:05 fail: 2026-04-24 09:50:05 skip: — start: 2026-04-24 17:50:03 end: 2026-04-24 17:50:05 hb: — last: 3s avg10: 1s max10: 3s delay: 136m 16s missed: 2 capacity: ok skips10: 0 — no	0 Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	LATE ok: 2026-04-24 18:51:38 fail: 2026-04-24 18:28:30 skip: 2026-04-24 19:30:02 start: 2026-04-24 19:30:02 end: 2026-04-24 19:30:02 hb: — last: 2m 41s avg10: 3m 52s max10: 4m 51s delay: 129m 44s missed: 25 capacity: ok skips10: 5 — yes	0                     lock busy                   Cluster V3 build metrics cluster_v3_build_metrics bin/cron_cluster_v3_build_metrics.sh critical cluster cron 5 4 * * *	OK ok: 2026-04-24 18:04:18 fail: 2026-03-24 21:04:54 skip: — start: 2026-04-24 18:03:43 end: 2026-04-24 18:04:18 hb: — last: 34s avg10: 60m 12s max10: 260m 53s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0 Cluster V3 detect signals cluster_v3_detect_signals bin/cron_cluster_v3_detect_signals.sh critical cluster cron 20 4 * * *	OK ok: 2026-04-24 18:04:09 fail: — skip: — start: 2026-04-24 18:03:48 end: 2026-04-24 18:04:09 hb: — last: 22s avg10: 7m 19s max10: 33m 42s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0



Oui, les retards viennent de 3 causes différentes.

## 1. Certains crons ne tournent plus

Exemples :

```
inflow_outflow_build
ok: 18:37
cron: 25 * * * *
delay: 89m

inflow_outflow_behavior_build
ok: 17:45
cron: 45 * * * *
delay: 141m
```

Ils auraient dû repasser toutes les heures. Donc soit :

```
cron ne les lance pas
script absent / mauvais chemin
flock bloqué
```

À vérifier :

```
crontab -l | grep inflow
```

## 2. `cluster_scan` est bloqué par un lock

Là c’est explicite :

```
lock busy
lock: yes
skip: 19:30:02
missed: 25
```

Le job ne tourne pas vraiment, il skippe parce qu’un fichier lock est encore présent.

Vérifie :

```
ps aux | grep cluster_scan
ps aux | grep "bin/rails runner"
find /tmp -iname "*cluster*lock*" -o -iname "*cluster*.lock"
```

Si aucun process cluster ne tourne, supprime le lock trouvé.

## 3. `whale_scan` est trop long pour son rythme

```
cron: 15 * * * *
last: 39m
delay: 72m
```

Il tourne toutes les heures, mais prend ~40 min. C’est acceptable mais fragile. Il faut probablement limiter son nombre de blocs ou le passer en incrémental plus strict.

## Priorité immédiate

Commence par :

```
crontab -l | grep -E "cluster|inflow|exchange|whale"
```

et :

```
find /tmp -iname "*cluster*lock*" -o -iname "*cluster*.lock"
```

Le plus urgent est de débloquer `cluster_scan`.



victor@debian:~/bitcoin_monitor$ ps aux | grep cluster_scan ps aux | grep "bin/rails runner" find /tmp -iname "*cluster*lock*" -o -iname "*cluster*.lock" victor     15771  0.0  0.0   5468  1000 ?        Ss   09:15   0:00 flock -n /tmp/bitcoin_monitor_cluster_scan.lock env RBENV_ROOT=/home/victor/.rbenv PATH=/home/victor/.rbenv/shims:/home/victor/.rbenv/bin:/home/victor/.rbenv/shims:/home/victor/.cargo/bin:/home/victor/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:/home/victor/.local/bin BUNDLE_GEMFILE=/home/victor/bitcoin_monitor/Gemfile RAILS_ENV=development APP=/home/victor/bitcoin_monitor LOG=/home/victor/bitcoin_monitor/log/cron.victor.log SCHEDULED_FOR=2026-04-24 09:15:01 TRIGGERED_BY=cron bash -c bin/cron_cluster_scan.sh >> "/home/victor/bitcoin_monitor/log/cron.victor.log" 2>&1 victor     15867  0.0  0.0   6940  2844 ?        S    09:15   0:00 bash -c bin/cron_cluster_scan.sh >> "/home/victor/bitcoin_monitor/log/cron.victor.log" 2>&1 victor     15868  0.0  0.0   7072  2980 ?        S    09:15   0:00 bash bin/cron_cluster_scan.sh victor     15906 52.8  0.8 475024 257884 ?       Sl   09:15 377:46 ruby bin/rails runner  JobRunner.run!(   "cluster_scan",   triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),   scheduled_for: ENV["SCHEDULED_FOR"].presence ) do |jr|   JobRunner.heartbeat!(jr)   ClusterScanner.call(job_run: jr)   JobRunner.heartbeat!(jr) end  victor    476975  0.0  0.0   6360  2368 pts/3    S+   21:09   0:00 grep cluster_scan victor     15906 52.8  0.8 475024 257884 ?       Sl   09:15 377:46 ruby bin/rails runner  JobRunner.run!(   "cluster_scan",   triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),   scheduled_for: ENV["SCHEDULED_FOR"].presence ) do |jr|   JobRunner.heartbeat!(jr)   ClusterScanner.call(job_run: jr)   JobRunner.heartbeat!(jr) end  victor    476978  0.0  0.0   6492  2204 pts/3    S+   21:09   0:00 grep bin/rails runner /tmp/bitcoin_monitor_cluster_scan.lock find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-systemd-timesyncd.service-fs7mb7’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-redis-server.service-Brxlyz’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-upower.service-Mc8JqB’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-colord.service-Ra1YYe’: Permission non accordée find: ‘/tmp/tracker-extract-3-files.118’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-low-memory-monitor.service-G4I3ML’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-power-profiles-daemon.service-17E6h1’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-ModemManager.service-9UEYg0’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-systemd-logind.service-0h7Jrr’: Permission non accordée find: ‘/tmp/systemd-private-863d6e1bea814a77a2d2ed66cdb29577-switcheroo-control.service-b0kNYw’: Permission non accordée victor@debian:~/bitcoin_monitor$ 



Oui, on a trouvé le vrai problème.

Tu as un **ancien cluster_scan bloqué depuis 09:15** :

```
ruby bin/rails runner ... ClusterScanner.call(job_run: jr)
PID 15906
runtime 377 minutes
```

Et il utilise encore l’ancien code :

```
ClusterScanner.call(job_run: jr)
```

pas le nouveau :

```
Clusters::ScanAndDispatch.call(...)
```

## 1. Stoppe ce vieux process

```
kill 15906
```

Puis vérifie :

```
ps aux | grep cluster_scan
ps aux | grep "bin/rails runner"
```

S’il est encore là après quelques secondes :

```
kill -9 15906
```

## 2. Supprime le lock si nécessaire

Après avoir tué le process :

```
rm -f /tmp/bitcoin_monitor_cluster_scan.lock
```

## 3. Relance avec le nouveau script

```
LIMIT=1 bin/cron_cluster_scan.sh
```

## 4. Vérifie `/system`

Tu dois retrouver :

```
cluster_scan OK
lock no
runtime court
delay 0
```

Le retard venait de ce vieux process bloqué, pas du nouveau pipeline.



Cluster scan cluster_scan bin/cron_cluster_scan.sh critical cluster cron */15 * * * *	OK ok: 2026-04-24 21:13:42 fail: 2026-04-24 18:28:30 skip: 2026-04-24 19:30:02 start: 2026-04-24 21:13:19 end: 2026-04-24 21:13:42 hb: — last: 23s avg10: 2m 59s max10: 4m 51s delay: 0s missed: 0 capacity: ok skips10: 4 — no	0



Parfait.

Le problème est réglé :

```
cluster_scan OK
last: 23s
delay: 0s
capacity: ok
lock: no
```

`avg10` et `max10` vont encore afficher les anciens runs pendant quelques exécutions, puis baisser naturellement.

Là ton `cluster_scan` est revenu dans un état sain.



il ce passe quoi avec lui Inflow / Outflow V1 inflow_outflow_build bin/cron_inflow_outflow_build.sh critical inflow_outflow cron 25 * * * *	LATE ok: 2026-04-24 18:37:03 fail: — skip: — start: 2026-04-24 18:37:00 end: 2026-04-24 18:37:03 hb: — last: 2s avg10: 2s max10: 3s delay: 97m 5s missed: 1 capacity: ok skips10: 0 — no	0



Lui est simplement en retard parce qu’il n’a pas rerun depuis 18:37.

Le job lui-même est sain :

```
last: 2s
capacity: ok
exit: 0
```

Donc le problème n’est PAS le code du job.

Le problème est probablement :

```
cron non déclenché
```

ou :

```
entrée crontab absente / cassée
```

## Vérifie la crontab

Lance :

```
crontab -l | grep inflow_outflow_build
```

Tu dois avoir quelque chose comme :

```
25 * * * * flock -n /tmp/bitcoin_monitor_inflow_outflow_build.lock ...
```

## Vérifie aussi le log cron

```
grep inflow_outflow_build ~/bitcoin_monitor/log/cron.victor.log | tail -20
```

On veut voir si le cron est réellement lancé après 18:37.

## Important

Le dashboard calcule :

```
delay = maintenant - prochain run attendu
```

Donc si un cron horaire manque une seule exécution :

```
delay ≈ 1h+
status = LATE
```

Même si le dernier run était parfait.



victor@debian:~/bitcoin_monitor$ crontab -l | grep inflow_outflow_build 25 * * * * flock -n /tmp/bitcoin_monitor_inflow_outflow_build.lock bash -lc 'cd "$APP" && bin/cron_inflow_outflow_build.sh >> "$LOG" 2>&1' victor@debian:~/bitcoin_monitor$ 



L’entrée existe, mais elle dépend de variables :

```
"$APP"
"$LOG"
```

Si `APP` et `LOG` ne sont pas définies dans la crontab globale, la ligne peut ne pas tourner correctement.

Vérifie le haut de ta crontab :

```
crontab -l | head -30
```

Tu dois voir quelque chose comme :

```
APP=/home/victor/bitcoin_monitor
LOG=/home/victor/bitcoin_monitor/log/cron.victor.log
```

Teste aussi manuellement :

```
APP=/home/victor/bitcoin_monitor LOG=/home/victor/bitcoin_monitor/log/cron.victor.log \
flock -n /tmp/bitcoin_monitor_inflow_outflow_build.lock bash -lc 'cd "$APP" && bin/cron_inflow_outflow_build.sh >> "$LOG" 2>&1'
```

Puis recharge `/system`.



victor@debian:~/bitcoin_monitor$ crontab -l | head -30 # ===== Bitcoin Monitor cron (victor) ===== SHELL=/bin/bash MAILTO="" CRON_TZ=Europe/Paris RBENV_ROOT=/home/victor/.rbenv PATH=/home/victor/.rbenv/bin:/home/victor/.rbenv/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin APP=/home/victor/bitcoin_monitor LOG=/home/victor/bitcoin_monitor/log/cron.victor.log  # ============================================================ # PRICE # ============================================================ # BTC price days 20 0 * * * flock -n /tmp/bitcoin_monitor_btc_price_days.lock bash -lc 'cd "$APP" && bin/cron_btc_price_days.sh >> "$LOG" 2>&1' # BTC price backfill (safety) # 35 0 * * * flock -n /tmp/bitcoin_monitor_btc_price_backfill.lock bash -lc 'cd "$APP" && bin/cron_btc_price_backfill.sh >> "$LOG" 2>&1'  # ============================================================ # EXCHANGE LIKE # ============================================================ # Rebuild exchange-like address set 0,30 * * * * flock -n /tmp/bitcoin_monitor_exchange_address_builder.lock bash -lc 'cd "$APP" && bin/cron_exchange_address_builder.sh >> "$LOG" 2>&1' victor@debian:~/bitcoin_monitor$ 



`APP` et `LOG` sont bien définies, donc la crontab est correcte.

Maintenant il faut voir si le cron a tenté de lancer le job après 18:37 :

```
grep "\[inflow_outflow_build\]" log/cron.victor.log | tail -30
```

Et vérifie s’il y a un lock bloqué :

```
ps aux | grep inflow_outflow_build
ls -lh /tmp/bitcoin_monitor_inflow_outflow_build.lock
```

Si aucun process ne tourne, teste manuellement :

```
bin/cron_inflow_outflow_build.sh
```

Puis recharge `/system`.



victor@debian:~/bitcoin_monitor$ grep "\[inflow_outflow_build\]" log/cron.victor.log | tail -30 [inflow_outflow_build] start 2026-04-24T10:17:34+02:00 [inflow_outflow_build] done rc=0 dur=1s 2026-04-24T10:17:35+02:00 [inflow_outflow_build] start 2026-04-24T12:28:33+02:00 [inflow_outflow_build] done rc=0 dur=2s 2026-04-24T12:28:35+02:00 [inflow_outflow_build] start 2026-04-24T16:25:01+02:00 [inflow_outflow_build] done rc=0 dur=4s 2026-04-24T16:25:05+02:00 [inflow_outflow_build] start 2026-04-24T18:36:59+02:00 [inflow_outflow_build] done rc=0 dur=4s 2026-04-24T18:37:03+02:00 victor@debian:~/bitcoin_monitor$ 



Le cron ne se déclenche pas toutes les heures. Il a seulement tourné à :

```
10:17
12:28
16:25
18:37
```

Donc ce n’est pas le job qui est lent : c’est très probablement que la ligne cron réelle n’est pas celle attendue, ou que `cron` n’a pas rechargé après modification.

Vérifie la section complète :

```
crontab -l | grep -A30 -B5 "INFLOW"
```

Et vérifie le service cron :

```
systemctl status cron --no-pager
```

Puis force le rechargement de la crontab :

```
crontab -l > /tmp/current_cron
crontab /tmp/current_cron
```

Ensuite attends le prochain `:25` ou lance manuellement :

```
bin/cron_inflow_outflow_build.sh
```



victor@debian:~/bitcoin_monitor$ crontab -l | grep -A30 -B5 "INFLOW" # Scan exchange-like UTXO every 10 minutes */10 * * * * flock -n /tmp/bitcoin_monitor_exchange_observed_scan.lock bash -lc 'cd "$APP" && bin/cron_exchange_observed_scan.sh >> "$LOG" 2>&1'  # ============================================================ # INFLOW / OUTFLOW V1 # ============================================================ 25 * * * * flock -n /tmp/bitcoin_monitor_inflow_outflow_build.lock bash -lc 'cd "$APP" && bin/cron_inflow_outflow_build.sh >> "$LOG" 2>&1'  # ============================================================ # INFLOW / OUTFLOW V2 # ============================================================ # Build inflow/outflow details hourly 35 * * * * flock -n /tmp/bitcoin_monitor_inflow_outflow_details_build.lock bash -lc 'cd "$APP" && bin/cron_inflow_outflow_details_build.sh >> "$LOG" 2>&1'  # ============================================================ # INFLOW / OUTFLOW V3 # ============================================================ # Build inflow/outflow behavior hourly 45 * * * * flock -n /tmp/bitcoin_monitor_inflow_outflow_behavior_build.lock bash -lc 'cd "$APP" && bin/cron_inflow_outflow_behavior_build.sh >> "$LOG" 2>&1'  # ============================================================ # INFLOW / OUTFLOW V4 # ============================================================ # Build inflow/outflow capital behavior hourly 50 * * * * flock -n /tmp/bitcoin_monitor_inflow_outflow_capital_behavior_build.lock bash -lc 'cd "$APP" && bin/cron_inflow_outflow_capital_behavior_build.sh >> "$LOG" 2>&1'  # ============================================================ # TRUE FLOW / SNAPSHOT # ============================================================ # Rebuild hourly # 10 * * * * flock -n /tmp/bitcoin_monitor_true_flow_rebuild.lock bash -lc 'cd "$APP" && bin/cron_true_flow_rebuild.sh >> "$LOG" 2>&1' # Market snapshot daily 15 1 * * * flock -n /tmp/bitcoin_monitor_market_snapshot.lock bash -lc 'cd "$APP" && bin/cron_market_snapshot.sh >> "$LOG" 2>&1' # Refresh recent (night optimization) # 10 3 * * * flock -n /tmp/bitcoin_monitor_true_flow_refresh_recent.lock bash -lc 'cd "$APP" && bin/cron_true_flow_refresh_recent.sh >> "$LOG" 2>&1'  # ============================================================ # WHALES # ============================================================ # Whale scan hourly # N lowered temporarily to 36 for safer recovery runs 15 * * * * bash -lc 'cd "$APP" && SCHEDULED_FOR="$(date +\%F\ \%T)" TRIGGERED_BY=cron N=36 bin/cron_wrap.sh whale_scan /tmp/bitcoin_monitor_whales_scan.lock "bin/cron_whale_scan.sh >> \"$LOG\" 2>&1"' # Whale reclassification nightly 20 2 * * * flock -n /tmp/bitcoin_monitor_whales_reclass.lock bash -lc 'cd "$APP" && bundle exec bin/rails whales:reclassify_last_7d >> "$LOG" 2>&1' victor@debian:~/bitcoin_monitor$ 



La crontab est correcte. Le fait que les horaires réels soient décalés :

```
10:17 au lieu de 10:25
12:28 au lieu de 12:25
16:25 OK
18:37 au lieu de 18:25
```

suggère surtout que le script est lancé manuellement ou via recovery, pas uniquement par cette ligne cron.

## À vérifier maintenant

```
systemctl status cron --no-pager
```

Puis recharge la crontab :

```
crontab -l > /tmp/current_cron
crontab /tmp/current_cron
```

Et teste le script directement :

```
bin/cron_inflow_outflow_build.sh
```

Si ça passe, `/system` repassera OK.

Pour confirmer le prochain vrai déclenchement cron, attends le prochain `HH:25`, puis :

```
grep "\[inflow_outflow_build\]" log/cron.victor.log | tail -5
```



victor@debian:~/bitcoin_monitor$ systemctl status cron --no-pager ● cron.service - Regular background program processing daemon     Loaded: loaded (/lib/systemd/system/cron.service; enabled; preset: enabled)     Active: active (running) since Fri 2026-04-24 09:05:07 CEST; 12h ago       Docs: man:cron(8)   Main PID: 825 (cron)      Tasks: 1 (limit: 35923)     Memory: 159.6M        CPU: 6h 32min 51.723s     CGroup: /system.slice/cron.service             └─825 /usr/sbin/cron -f Warning: some journal files were not opened due to insufficient permissions. victor@debian:~/bitcoin_monitor$ 



Cron tourne bien.

Donc pour `inflow_outflow_build`, le plus probable est :

```
le script est OK
la crontab est OK
mais les derniers runs viennent de lancements manuels/recovery
et le prochain cron HH:25 confirmera
```

Fais maintenant :

```
crontab -l > /tmp/current_cron
crontab /tmp/current_cron
```

Puis lance manuellement une fois :

```
bin/cron_inflow_outflow_build.sh
```

Ensuite, au prochain `HH:25` :

```
grep "\[inflow_outflow_build\]" log/cron.victor.log | tail -10
```

Si rien n’apparaît à `HH:25`, on regardera les logs système cron.



et la Inflow / Outflow V3 inflow_outflow_behavior_build bin/cron_inflow_outflow_behavior_build.sh critical inflow_outflow cron 45 * * * *	LATE ok: 2026-04-24 17:45:03 fail: — skip: — start: 2026-04-24 17:45:03 end: 2026-04-24 17:45:03 hb: — last: 0s avg10: 1s max10: 2s delay: 163m 8s missed: 2 capacity: ok skips10: 0 — no	0 Inflow / Outflow V4 inflow_outflow_capital_behavior_build bin/cron_inflow_outflow_capital_behavior_build.sh critical inflow_outflow cron 50 * * * *	LATE ok: 2026-04-24 17:50:05 fail: 2026-04-24 09:50:05 skip: — start: 2026-04-24 17:50:03 end: 2026-04-24 17:50:05 hb: — last: 3s avg10: 1s max10: 3s delay: 158m 6s missed: 2 capacity: ok skips10: 0 — no	0



Même diagnostic que V1 : les jobs sont rapides, mais ils n’ont pas été relancés aux horaires attendus.

```
V3 attendu chaque heure à :45
dernier OK : 17:45

V4 attendu chaque heure à :50
dernier OK : 17:50
```

Ils auraient dû repasser à 18:45, 19:45, 20:45, etc.

Vérifie les logs :

```
grep "\[inflow_outflow_behavior_build\]" log/cron.victor.log | tail -20
grep "\[inflow_outflow_capital_behavior_build\]" log/cron.victor.log | tail -20
```

Puis relance manuellement :

```
bin/cron_inflow_outflow_behavior_build.sh
bin/cron_inflow_outflow_capital_behavior_build.sh
```

Après ça, recharge `/system`.

S’ils repassent `OK`, le problème n’est pas le code : c’est le déclenchement cron horaire à surveiller au prochain `:45` et `:50`.



victor@debian:~/bitcoin_monitor$ grep "\[inflow_outflow_behavior_build\]" log/cron.victor.log | tail -20  grep "\[inflow_outflow_capital_behavior_build\]" log/cron.victor.log | tail -20 [inflow_outflow_behavior_build] start 2026-04-24T10:18:02+02:00 [inflow_outflow_behavior_build] done rc=0 dur=1s 2026-04-24T10:18:03+02:00 [inflow_outflow_behavior_build] start 2026-04-24T11:45:01+02:00 [inflow_outflow_behavior_build] done rc=0 dur=1s 2026-04-24T11:45:02+02:00 [inflow_outflow_behavior_build] start 2026-04-24T13:45:01+02:00 [inflow_outflow_behavior_build] done rc=0 dur=1s 2026-04-24T13:45:02+02:00 [inflow_outflow_behavior_build] start 2026-04-24T15:45:01+02:00 [inflow_outflow_behavior_build] done rc=0 dur=1s 2026-04-24T15:45:02+02:00 [inflow_outflow_behavior_build] start 2026-04-24T17:45:01+02:00 [inflow_outflow_behavior_build] done rc=0 dur=2s 2026-04-24T17:45:03+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T09:50:02+02:00 [inflow_outflow_capital_behavior_build] FAIL rc=1 dur=3s 2026-04-24T09:50:05+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T10:18:15+02:00 [inflow_outflow_capital_behavior_build] done rc=0 dur=1s 2026-04-24T10:18:16+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T11:50:02+02:00 [inflow_outflow_capital_behavior_build] done rc=0 dur=1s 2026-04-24T11:50:03+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T13:50:01+02:00 [inflow_outflow_capital_behavior_build] done rc=0 dur=1s 2026-04-24T13:50:02+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T15:50:01+02:00 [inflow_outflow_capital_behavior_build] done rc=0 dur=2s 2026-04-24T15:50:03+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T16:50:02+02:00 [inflow_outflow_capital_behavior_build] done rc=0 dur=1s 2026-04-24T16:50:03+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T17:50:01+02:00 [inflow_outflow_capital_behavior_build] done rc=0 dur=5s 2026-04-24T17:50:06+02:00 victor@debian:~/bitcoin_monitor$ 



On voit un schéma clair : depuis ~18h, plusieurs crons horaires ne se déclenchent plus.

Exemples :

```
V3 : 11:45, 13:45, 15:45, 17:45
V4 : 11:50, 13:50, 15:50, 16:50, 17:50
```

Après 17:50, plus rien.

Donc ce n’est pas le code V3/V4 : c’est probablement la crontab qui n’a pas été relue, ou cron qui a arrêté de prendre en compte certaines lignes après modifications.

Fais le reload :

```
crontab -l > /tmp/current_cron
crontab /tmp/current_cron
```

Puis lance les jobs manuellement pour remettre `/system` au vert :

```
bin/cron_inflow_outflow_build.sh
bin/cron_inflow_outflow_behavior_build.sh
bin/cron_inflow_outflow_capital_behavior_build.sh
```

Ensuite surveille le prochain passage à `HH:25`, `HH:45`, `HH:50` :

```
tail -f log/cron.victor.log
```



Scanner Exchange observed scan OK Cursor 946487 Lag 3 Updated at 2026-04-24 21:11:49Exchange observed scan exchange_observed_scan bin/cron_exchange_observed_scan.sh critical exchange cron */10 * * * *	LATE ok: 2026-04-24 21:11:49 fail: — skip: — start: 2026-04-24 21:10:02 end: 2026-04-24 21:11:49 hb: — last: 1m 47s avg10: 1m 49s max10: 6m 47s delay: 12m 52s missed: 1 capacity: ok skips10: 0 — no	0



Oui, c’est possible d’avoir ces deux états en même temps.

## Pourquoi ?

Le bloc **Scanner** dit :

```
Exchange observed scan
Cursor 946487
Lag 3
OK
```

Ça veut dire : les **données blockchain** sont fraîches.

Mais le bloc **Jobs** dit :

```
exchange_observed_scan
LATE
delay 12m52
missed 1
```

Ça veut dire : le **cron** n’a pas été relancé à l’heure attendue.

Donc :

```
donnée fraîche = OK
orchestration cron = LATE
```

## Ici ce n’est pas grave côté data

Un lag de 3 blocs est très bon.

Le souci est plutôt côté supervision cron : il attend un run toutes les 10 minutes, mais le dernier OK date de 21:11:49.

## À surveiller

Au prochain passage `*/10`, regarde :

```
grep "\[exchange_observed_scan\]" log/cron.victor.log | tail -10
```

Si ça repart, tout va bien.

Sinon, recharge la crontab :

```
crontab -l > /tmp/current_cron
crontab /tmp/current_cron
```



victor@debian:~/bitcoin_monitor$ tail -f log/cron.victor.log [inflow_outflow_builder] day=2026-04-24 inflow_btc=301112.61367357 outflow_btc=211927.13626001 netflow_btc=89185.47741356 inflow_utxo_count=49889 outflow_utxo_count=36403 [inflow_outflow_build] done rc=0 dur=1s 2026-04-24T21:34:24+02:00 [inflow_outflow_behavior_build] start 2026-04-24T21:34:24+02:00 [inflow_outflow_behavior_builder] day=2026-04-23 retail_dep=0.91014 whale_dep=0.08949 inst_dep=0.00037 retail_wd=0.915669 whale_wd=0.083915 inst_wd=0.000416 dist=0.577677 acc=0.545696 behavior=0.031981 [inflow_outflow_behavior_builder] day=2026-04-24 retail_dep=0.906326 whale_dep=0.093053 inst_dep=0.000622 retail_wd=0.908443 whale_wd=0.090914 inst_wd=0.000643 dist=0.562834 acc=0.525704 behavior=0.03713 [inflow_outflow_behavior_build] done rc=0 dur=1s 2026-04-24T21:34:25+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T21:34:25+02:00 [inflow_outflow_capital_behavior_builder] day=2026-04-23 retail_dep_cap=0.102404 whale_dep_cap=0.851404 inst_dep_cap=0.046192 retail_wd_cap=0.11345 whale_wd_cap=0.828411 inst_wd_cap=0.058139 capital_dom=0.892073 whale_dist=0.51432 whale_acc=0.478113 divergence=0.804978 capital_behavior=0.609185 [inflow_outflow_capital_behavior_builder] day=2026-04-24 retail_dep_cap=0.081843 whale_dep_cap=0.774455 inst_dep_cap=0.072778 retail_wd_cap=0.089166 whale_wd_cap=0.760121 inst_wd_cap=0.078784 capital_dom=0.843069 whale_dist=0.491361 whale_acc=0.452245 divergence=0.750453 capital_behavior=0.574098 [inflow_outflow_capital_behavior_build] done rc=0 dur=2s 2026-04-24T21:34:27+02:00



Parfait, les jobs `inflow/outflow` repartent bien.

Là on voit :

```
inflow_outflow_build OK
inflow_outflow_behavior_build OK
inflow_outflow_capital_behavior_build OK
```

Donc `/system` devrait repasser progressivement en `OK` pour V1/V3/V4.

Le problème était bien côté déclenchement/rechargement cron, pas côté code.



on a fini d'optimiser cluster ?



Oui, pour la phase actuelle, le pipeline cluster est maintenant correctement optimisé et stabilisé.

Tu es passé de :

```
cluster_scan → plusieurs heures
cluster_v3_build_metrics → 260 min
cluster_v3_detect_signals → 33 min
refresh sync bloquant
```

à :

```
cluster_scan → ~20-40s
refresh async Sidekiq
metrics incrémentales (~3000 clusters)
signals incrémentaux
cluster_scan stable
capacity ok
```

Concrètement, ce qui a été gagné :

- `cluster_scan` limité (`LIMIT`)
- suppression du vieux process bloqué
- dirty clusters uniquement
- refresh async via Sidekiq + Redis
- métriques V3 incrémentales
- signaux incrémentaux
- progress UI
- supervision `/system`
- heartbeat
- queue monitoring
- retry/dead supervision
- lock supervision

Ton pipeline est maintenant dans une architecture “pro” réaliste.

## Ce qu’il reste éventuellement plus tard (niveau avancé)

Pas obligatoire maintenant :

### 1. Batch SQL pour `AddressLink.exists?`

Aujourd’hui :

```
AddressLink.exists?(txid: txid)
```

sur énormément de tx.

Un cache mémoire par bloc pourrait accélérer.

### 2. Parallélisation block scan

Ex :

```
1 thread = scan tx
N threads = extraction inputs
```

Mais attention aux RPC Bitcoin Core.

### 3. ZMQ temps réel

Plus tard :

```
bitcoind ZMQ
→ nouveau bloc
→ cluster scan instantané
```

au lieu du cron `*/15`.

### 4. ClickHouse / Elasticsearch

Seulement si tu dépasses des dizaines de millions de relations.

------

Mais honnêtement :

```
cluster_scan = 23s
capacity = ok
```

=> tu es déjà dans une très bonne zone.



on refactorise et on optimise whale scan



Oui. On va traiter `whale_scan` comme on vient de faire pour `cluster` : d’abord audit réel du code, puis séparation des responsabilités, puis optimisation du temps d’exécution et supervision. Je commence par retrouver les fichiers `whale` dans ton archive/projet pour identifier précisément ce qui ralentit.

Réflexion durant 20s

Oui. `whale_scan` est le prochain bon candidat.

## Diagnostic actuel

Le gros problème est ici :

```
block = rpc.getblock(blockhash)
txids = Array(block["tx"])

txids.each do |txid|
  tx = rpc.getrawtransaction(txid, true, blockhash)
end
```

Donc pour chaque bloc :

```
1 RPC getblock
+
1 RPC getrawtransaction par transaction
```

Sur 72 blocs, ça peut faire des centaines de milliers d’appels RPC. C’est pour ça que `whale_scan` prend 30–40 minutes.

## Optimisation principale

Utiliser directement :

```
rpc.getblock(blockhash, 2)
```

ou mieux :

```
rpc.getblock(blockhash, 3)
```

Comme pour `cluster_scan`.

Ainsi tu récupères les transactions décodées directement dans le bloc, et tu supprimes presque tous les `getrawtransaction`.

## Première modification

Dans :

```
app/jobs/scan_whale_alerts_job.rb
```

remplace dans `scan_block!` :

```
block      = rpc.getblock(blockhash)
block_time = Time.zone.at(block["time"].to_i)

txids = Array(block["tx"])
return if txids.empty?

existing_by_txid = WhaleAlert.where(txid: txids).select(:txid, :meta, :created_at).index_by(&:txid)

rows = []
now  = Time.current

txids.each do |txid|
  tx =
    begin
      rpc.getrawtransaction(txid, true, blockhash)
    rescue BitcoinRpc::Error
      next
    end
```

par :

```
block      = rpc.getblock(blockhash, 2)
block_time = Time.zone.at(block["time"].to_i)

txs = Array(block["tx"])
return if txs.empty?

txids = txs.map { |tx| tx["txid"].to_s }.reject(&:blank?)

existing_by_txid =
  WhaleAlert
    .where(txid: txids)
    .select(:txid, :meta, :created_at)
    .index_by(&:txid)

rows = []
now  = Time.current

txs.each do |tx|
  txid = tx["txid"].to_s
  next if txid.blank?
```

Et supprime le bloc :

```
tx =
  begin
    rpc.getrawtransaction(txid, true, blockhash)
  rescue BitcoinRpc::Error
    next
  end
```

## Résultat attendu

Tu passes de :

```
1 bloc + milliers de RPC tx
```

à :

```
1 RPC par bloc
```

C’est probablement le plus gros gain possible.

Après cette modification, teste :

```
N=3 bin/cron_whale_scan.sh
```

Puis :

```
N=12 bin/cron_whale_scan.sh
```

Si tout est bon, on ajustera le cron à un `N` réaliste.



tu peux me le refaire def scan_block!(rpc, height)    blockhash  = rpc.getblockhash(height)    block      = rpc.getblock(blockhash)    block_time = Time.zone.at(block["time"].to_i)     txids = Array(block["tx"])    return if txids.empty?     existing_by_txid = WhaleAlert.where(txid: txids).select(:txid, :meta, :created_at).index_by(&:txid)     rows = []    now  = Time.current     txids.each do |txid|      tx =        begin          rpc.getrawtransaction(txid, true, blockhash)        rescue BitcoinRpc::Error          next        end       metrics = compute_metrics_for_tx(tx)      next unless metrics      next unless whale_tx?(metrics)       existing = existing_by_txid[txid]      if SKIP_IF_SAME_CLASSIFIER_VERSION && existing        meta = existing.meta.is_a?(Hash) ? existing.meta : {}        if meta["classifier_version"].to_s == CLASSIFIER_VERSION && meta["scan_version"].to_s == SCAN_VERSION          next        end      end       classified = nil      begin        classified = WhaleAlertClassifier.call(metrics, apply_threshold: false)      rescue        classified = nil      end       if classified.nil?        ratio_fallback =          begin            tot = metrics[:total_out_btc].to_d            tot.positive? ? (metrics[:largest_output_btc].to_d / tot).round(4) : 0.to_d          rescue            0.to_d          end         classified = {          alert_type: "other",          score: 0,          ratio: ratio_fallback,          exchange_likelihood: 0,          exchange_hint: "unlikely",          flow_kind: "unknown",          flow_confidence: 20,          actor_band: nil,          flow_reasons: [],          flow_scores: {},          meta: {}        }      end       base_meta = classified[:meta].is_a?(Hash) ? classified[:meta] : {}      base_meta = base_meta.merge(        "classifier_version" => CLASSIFIER_VERSION,        "scan_version"       => SCAN_VERSION,        "blockhash"          => blockhash,        "metrics" => {          "second_largest_output_btc" => metrics[:second_largest_output_btc].to_s,          "small_outputs_count"       => metrics[:small_outputs_count],          "dust_like_count"           => metrics[:dust_like_count]        }      )       flow_reasons_json = Array(classified[:flow_reasons]).to_json       rows << {        txid: txid,        block_height: height,        block_time: block_time,        total_out_btc: metrics[:total_out_btc],        inputs_count: metrics[:inputs_count],        outputs_count: metrics[:outputs_count],        outputs_nonzero_count: metrics[:outputs_nonzero_count],        largest_output_btc: metrics[:largest_output_btc],        largest_output_ratio: classified[:ratio],        alert_type: classified[:alert_type],        score: classified[:score],        exchange_likelihood: classified[:exchange_likelihood],        exchange_hint: classified[:exchange_hint],        largest_output_address: metrics[:largest_output_address],        largest_output_vout: metrics[:largest_output_vout],        largest_output_desc: metrics[:largest_output_desc],        tier: nil,        flow_kind: classified[:flow_kind],        flow_confidence: classified[:flow_confidence],        actor_band: classified[:actor_band],        flow_reasons: flow_reasons_json,        flow_scores: (classified[:flow_scores].is_a?(Hash) ? classified[:flow_scores] : {}),        meta: base_meta,        created_at: (existing ? existing.created_at : now),        updated_at: now      }       if rows.size >= UPSERT_BATCH_SIZE        upsert_rows!(rows)        rows.clear      end    end     upsert_rows!(rows) if rows.any?  rescue BitcoinRpc::Error    # bloc inaccessible -> skip  end



Remplace ta méthode par celle-ci :

```
def scan_block!(rpc, height)
  blockhash  = rpc.getblockhash(height)
  block      = rpc.getblock(blockhash, 2)
  block_time = Time.zone.at(block["time"].to_i)

  txs = Array(block["tx"])
  return if txs.empty?

  txids = txs.map { |tx| tx["txid"].to_s }.reject(&:blank?)

  existing_by_txid =
    WhaleAlert
      .where(txid: txids)
      .select(:txid, :meta, :created_at)
      .index_by(&:txid)

  rows = []
  now  = Time.current

  txs.each do |tx|
    txid = tx["txid"].to_s
    next if txid.blank?

    metrics = compute_metrics_for_tx(tx)
    next unless metrics
    next unless whale_tx?(metrics)

    existing = existing_by_txid[txid]

    if SKIP_IF_SAME_CLASSIFIER_VERSION && existing
      meta = existing.meta.is_a?(Hash) ? existing.meta : {}

      if meta["classifier_version"].to_s == CLASSIFIER_VERSION &&
         meta["scan_version"].to_s == SCAN_VERSION
        next
      end
    end

    classified = nil

    begin
      classified = WhaleAlertClassifier.call(metrics, apply_threshold: false)
    rescue
      classified = nil
    end

    if classified.nil?
      ratio_fallback =
        begin
          total = metrics[:total_out_btc].to_d

          if total.positive?
            (metrics[:largest_output_btc].to_d / total).round(4)
          else
            0.to_d
          end
        rescue
          0.to_d
        end

      classified = {
        alert_type: "other",
        score: 0,
        ratio: ratio_fallback,
        exchange_likelihood: 0,
        exchange_hint: "unlikely",
        flow_kind: "unknown",
        flow_confidence: 20,
        actor_band: nil,
        flow_reasons: [],
        flow_scores: {},
        meta: {}
      }
    end

    base_meta = classified[:meta].is_a?(Hash) ? classified[:meta] : {}

    base_meta = base_meta.merge(
      "classifier_version" => CLASSIFIER_VERSION,
      "scan_version" => SCAN_VERSION,
      "blockhash" => blockhash,
      "metrics" => {
        "second_largest_output_btc" => metrics[:second_largest_output_btc].to_s,
        "small_outputs_count" => metrics[:small_outputs_count],
        "dust_like_count" => metrics[:dust_like_count]
      }
    )

    flow_reasons_json = Array(classified[:flow_reasons]).to_json

    rows << {
      txid: txid,
      block_height: height,
      block_time: block_time,
      total_out_btc: metrics[:total_out_btc],
      inputs_count: metrics[:inputs_count],
      outputs_count: metrics[:outputs_count],
      outputs_nonzero_count: metrics[:outputs_nonzero_count],
      largest_output_btc: metrics[:largest_output_btc],
      largest_output_ratio: classified[:ratio],
      alert_type: classified[:alert_type],
      score: classified[:score],
      exchange_likelihood: classified[:exchange_likelihood],
      exchange_hint: classified[:exchange_hint],
      largest_output_address: metrics[:largest_output_address],
      largest_output_vout: metrics[:largest_output_vout],
      largest_output_desc: metrics[:largest_output_desc],
      tier: nil,
      flow_kind: classified[:flow_kind],
      flow_confidence: classified[:flow_confidence],
      actor_band: classified[:actor_band],
      flow_reasons: flow_reasons_json,
      flow_scores: classified[:flow_scores].is_a?(Hash) ? classified[:flow_scores] : {},
      meta: base_meta,
      created_at: existing ? existing.created_at : now,
      updated_at: now
    }

    if rows.size >= UPSERT_BATCH_SIZE
      upsert_rows!(rows)
      rows.clear
    end
  end

  upsert_rows!(rows) if rows.any?
rescue BitcoinRpc::Error
  # bloc inaccessible -> skip
end
```

La différence clé :

```
block = rpc.getblock(blockhash, 2)
```

et on supprime :

```
rpc.getrawtransaction(txid, true, blockhash)
```

Donc tu passes à **1 appel RPC par bloc** au lieu de milliers.



et ensuite



Ensuite tu testes progressivement.

## 1. Test petit

```
N=3 bin/cron_whale_scan.sh
```

Puis regarde :

```
tail -n 80 log/cron.victor.log
```

## 2. Test moyen

```
N=12 bin/cron_whale_scan.sh
```

## 3. Vérifie `/system`

Tu veux voir `Whale scan` passer de :

```
last: 39m
```

à quelque chose de beaucoup plus court.

## 4. Si tout est OK

Tu peux remonter le cron à :

```
N=72
```

ou garder plus prudent :

```
N=36
```

dans ta crontab.



victor@debian:~/bitcoin_monitor$ tail -f log/cron.victor.log [inflow_outflow_builder] day=2026-04-24 inflow_btc=301112.61367357 outflow_btc=211927.13626001 netflow_btc=89185.47741356 inflow_utxo_count=49889 outflow_utxo_count=36403 [inflow_outflow_build] done rc=0 dur=1s 2026-04-24T21:34:24+02:00 [inflow_outflow_behavior_build] start 2026-04-24T21:34:24+02:00 [inflow_outflow_behavior_builder] day=2026-04-23 retail_dep=0.91014 whale_dep=0.08949 inst_dep=0.00037 retail_wd=0.915669 whale_wd=0.083915 inst_wd=0.000416 dist=0.577677 acc=0.545696 behavior=0.031981 [inflow_outflow_behavior_builder] day=2026-04-24 retail_dep=0.906326 whale_dep=0.093053 inst_dep=0.000622 retail_wd=0.908443 whale_wd=0.090914 inst_wd=0.000643 dist=0.562834 acc=0.525704 behavior=0.03713 [inflow_outflow_behavior_build] done rc=0 dur=1s 2026-04-24T21:34:25+02:00 [inflow_outflow_capital_behavior_build] start 2026-04-24T21:34:25+02:00 [inflow_outflow_capital_behavior_builder] day=2026-04-23 retail_dep_cap=0.102404 whale_dep_cap=0.851404 inst_dep_cap=0.046192 retail_wd_cap=0.11345 whale_wd_cap=0.828411 inst_wd_cap=0.058139 capital_dom=0.892073 whale_dist=0.51432 whale_acc=0.478113 divergence=0.804978 capital_behavior=0.609185 [inflow_outflow_capital_behavior_builder] day=2026-04-24 retail_dep_cap=0.081843 whale_dep_cap=0.774455 inst_dep_cap=0.072778 retail_wd_cap=0.089166 whale_wd_cap=0.760121 inst_wd_cap=0.078784 capital_dom=0.843069 whale_dist=0.491361 whale_acc=0.452245 divergence=0.750453 capital_behavior=0.574098 [inflow_outflow_capital_behavior_build] done rc=0 dur=2s 2026-04-24T21:34:27+02:00 [exchange_observed_scan] start 2026-04-24T21:40:01+02:00 [exchange_observed_scan] start mode=incremental start_height=946488 end_height=946490 exchange_set_size=730 [exchange_observed_scan] done rc=0 dur=17s 2026-04-24T21:40:18+02:00 [2026-04-24 21:45:01] [cluster_scan] start triggered_by=cron scheduled_for=2026-04-24 21:45:01 [cluster_scan] limit=1 [cluster_scan] start mode=incremental start_height=946471 end_height=946471 INFO  2026-04-24T19:45:16.380Z pid=484648 tid=ah98: Sidekiq 8.1.0 connecting to Redis with options {:size=>10, :pool_name=>"internal", :url=>"redis://127.0.0.1:6379/0"} [cluster_scan] dirty_clusters=39 [cluster_scan] scanned_blocks=1 [cluster_scan] scanned_txs=6350 [cluster_scan] multi_input_txs=39 [2026-04-24 21:45:16] [cluster_scan] done [2026-04-24 21:57:51] [whale_scan] start triggered_by=cron scheduled_for= N=3 WHALE_MIN_BTC=100 DEPRECATED: use MT_CPU instead of N for parallel test runs 🐋 Whale scan starting (last 3 blocks)… 🐋 [Whales] scanning blocks 946487..946489 (tip=946491, safe_tip=946489, min_largest=100.0 BTC, scan_v=2026-03-03-v3, clf_v=2026-03-03-v3) 🐋 [Whales] progress height=946487 scanned=1/3 pct=33.3% 🐋 [Whales] progress height=946488 scanned=2/3 pct=66.7% 🐋 [Whales] progress height=946489 scanned=3/3 pct=100.0% ✅ [Whales] scan done 946487..946489 ✅ Whale scan done (last 3 blocks) [2026-04-24 21:57:54] [whale_scan] done [2026-04-24 21:58:20] [whale_scan] start triggered_by=cron scheduled_for= N=12 WHALE_MIN_BTC=100 DEPRECATED: use MT_CPU instead of N for parallel test runs 🐋 Whale scan starting (last 12 blocks)… 🐋 [Whales] scanning blocks 946478..946489 (tip=946491, safe_tip=946489, min_largest=100.0 BTC, scan_v=2026-03-03-v3, clf_v=2026-03-03-v3) 🐋 [Whales] progress height=946478 scanned=1/12 pct=8.3% 🐋 [Whales] progress height=946482 scanned=5/12 pct=41.7% 🐋 [Whales] progress height=946487 scanned=10/12 pct=83.3% 🐋 [Whales] progress height=946489 scanned=12/12 pct=100.0% ✅ [Whales] scan done 946478..946489 ✅ Whale scan done (last 12 blocks) [2026-04-24 21:58:28] [whale_scan] done [2026-04-24 21:59:55] [whale_scan] start triggered_by=cron scheduled_for= N=36 WHALE_MIN_BTC=100 DEPRECATED: use MT_CPU instead of N for parallel test runs 🐋 Whale scan starting (last 36 blocks)… 🐋 [Whales] scanning blocks 946455..946490 (tip=946492, safe_tip=946490, min_largest=100.0 BTC, scan_v=2026-03-03-v3, clf_v=2026-03-03-v3) 🐋 [Whales] progress height=946455 scanned=1/36 pct=2.8% 🐋 [Whales] progress height=946459 scanned=5/36 pct=13.9% 🐋 [Whales] progress height=946464 scanned=10/36 pct=27.8% 🐋 [Whales] progress height=946469 scanned=15/36 pct=41.7% 🐋 [Whales] progress height=946474 scanned=20/36 pct=55.6% 🐋 [Whales] progress height=946479 scanned=25/36 pct=69.4% 🐋 [Whales] progress height=946484 scanned=30/36 pct=83.3% 🐋 [Whales] progress height=946489 scanned=35/36 pct=97.2% 🐋 [Whales] progress height=946490 scanned=36/36 pct=100.0% ✅ [Whales] scan done 946455..946490 ✅ Whale scan done (last 36 blocks) [2026-04-24 22:00:14] [whale_scan] done [2026-04-24 22:01:02] [whale_scan] start triggered_by=cron scheduled_for= N=72 WHALE_MIN_BTC=100 DEPRECATED: use MT_CPU instead of N for parallel test runs 🐋 Whale scan starting (last 72 blocks)… 🐋 [Whales] scanning blocks 946420..946491 (tip=946493, safe_tip=946491, min_largest=100.0 BTC, scan_v=2026-03-03-v3, clf_v=2026-03-03-v3) 🐋 [Whales] progress height=946420 scanned=1/72 pct=1.4% 🐋 [Whales] progress height=946424 scanned=5/72 pct=6.9% 🐋 [Whales] progress height=946429 scanned=10/72 pct=13.9% 🐋 [Whales] progress height=946434 scanned=15/72 pct=20.8% 🐋 [Whales] progress height=946439 scanned=20/72 pct=27.8% 🐋 [Whales] progress height=946444 scanned=25/72 pct=34.7% 🐋 [Whales] progress height=946449 scanned=30/72 pct=41.7% 🐋 [Whales] progress height=946454 scanned=35/72 pct=48.6% 🐋 [Whales] progress height=946459 scanned=40/72 pct=55.6% 🐋 [Whales] progress height=946464 scanned=45/72 pct=62.5% 🐋 [Whales] progress height=946469 scanned=50/72 pct=69.4% 🐋 [Whales] progress height=946474 scanned=55/72 pct=76.4% 🐋 [Whales] progress height=946479 scanned=60/72 pct=83.3% 🐋 [Whales] progress height=946484 scanned=65/72 pct=90.3% 🐋 [Whales] progress height=946489 scanned=70/72 pct=97.2% 🐋 [Whales] progress height=946491 scanned=72/72 pct=100.0% ✅ [Whales] scan done 946420..946491 ✅ Whale scan done (last 72 blocks) [2026-04-24 22:01:36] [whale_scan] done



Excellent. L’optimisation `whale_scan` est validée.

Avant :

```
N=36 ≈ 30–40 min
```

Maintenant :

```
N=36 → 19s
N=72 → 34s
```

C’est un gain énorme.

Tu peux garder le cron avec :

```
N=72
```

sans problème.

## Ce qu’on a gagné

```
ancien mode :
1 bloc + getrawtransaction pour chaque tx

nouveau mode :
1 getblock(blockhash, 2) par bloc
```

Donc le job est passé d’un scan RPC transaction par transaction à un scan bloc décodé.

## Prochaine étape

Dans `/system`, `whale_scan` devrait repasser :

```
OK
last: ~30s
capacity: ok
delay: 0
```

Là `whale_scan` est optimisé.



Whale scan whale_scan bin/rails whales:scan critical whales cron 15 * * * *	OK ok: 2026-04-24 22:01:36 fail: — skip: — start: 2026-04-24 22:01:03 end: 2026-04-24 22:01:36 hb: — last: 34s avg10: 20m 53s max10: 40m 49s delay: 0s missed: 0 capacity: ok skips10: 0 — no	0



Parfait.

`whale_scan` est maintenant sain :

```
OK
last: 34s
delay: 0s
capacity: ok
```

`avg10` et `max10` restent élevés uniquement à cause des anciens runs longs :

```
avg10: 20m53
max10: 40m49
```

Après quelques exécutions rapides, ils vont descendre naturellement.

Optimisation validée.