# config/initializers/system_jobs.rb
SYSTEM_JOBS = {
  "btc_price_daily" => {
    label: "BTC price daily",
    cron: "20 0 * * *",
    expected_every: 24.hours,
    late_after: 48.hours,
    max_runtime: 10.minutes,
    critical: true,
    category: "price",
    lock_file: "/tmp/bitcoin_monitor_btc_price_days.lock",
    command: "bin/cron_btc_price_days.sh",
    active: true,
    order: 10
  },

  "market_snapshot" => {
    label: "Market snapshot",
    cron: "15 1 * * *",
    expected_every: 24.hours,
    max_runtime: 10.minutes,
    critical: true,
    category: "market",
    lock_file: "/tmp/bitcoin_monitor_market_snapshot.lock",
    command: "bin/cron_market_snapshot.sh",
    active: true,
    order: 20
  },

  "whale_scan" => {
    label: "Whale scan",
    cron: "15 * * * *",
    expected_every: 1.hour,
    max_runtime: 20.minutes,
    critical: true,
    category: "whales",
    lock_file: "/tmp/bitcoin_monitor_whales_scan.lock",
    command: "bin/rails whales:scan",
    active: true,
    order: 30
  },

  "exchange_address_builder" => {
    label: "Exchange address builder",
    cron: "0 */6 * * *",
    expected_every: 6.hours,
    max_runtime: 15.minutes,
    critical: true,
    category: "exchange",
    lock_file: "/tmp/bitcoin_monitor_exchange_address_builder.lock",
    command: "bin/cron_exchange_address_builder.sh",
    active: true,
    order: 50
  },

  "exchange_observed_scan" => {
    label: "Exchange observed scan",
    cron: "*/10 * * * *",
    expected_every: 10.minutes,
    late_after: 20.minutes,
    max_runtime: 8.minutes,
    critical: true,
    category: "exchange",
    lock_file: "/tmp/bitcoin_monitor_exchange_observed_scan.lock",
    command: "bin/cron_exchange_observed_scan.sh",
    active: true,
    order: 60
  },

  "inflow_outflow_build" => {
    label: "Inflow / Outflow V1",
    cron: "25 * * * *",
    expected_every: 1.hour,
    max_runtime: 20.minutes,
    critical: true,
    category: "inflow_outflow",
    lock_file: "/tmp/bitcoin_monitor_inflow_outflow_build.lock",
    command: "bin/cron_inflow_outflow_build.sh",
    active: true,
    order: 70
  },

  "inflow_outflow_details_build" => {
    label: "Inflow / Outflow V2",
    cron: "35 * * * *",
    expected_every: 1.hour,
    max_runtime: 20.minutes,
    critical: true,
    category: "inflow_outflow",
    lock_file: "/tmp/bitcoin_monitor_inflow_outflow_details_build.lock",
    command: "bin/cron_inflow_outflow_details_build.sh",
    active: true,
    order: 80
  },

  "inflow_outflow_behavior_build" => {
    label: "Inflow / Outflow V3",
    cron: "45 * * * *",
    expected_every: 1.hour,
    max_runtime: 20.minutes,
    critical: true,
    category: "inflow_outflow",
    lock_file: "/tmp/bitcoin_monitor_inflow_outflow_behavior_build.lock",
    command: "bin/cron_inflow_outflow_behavior_build.sh",
    active: true,
    order: 90
  },

  "inflow_outflow_capital_behavior_build" => {
    label: "Inflow / Outflow V4",
    cron: "50 * * * *",
    expected_every: 1.hour,
    max_runtime: 20.minutes,
    critical: true,
    category: "inflow_outflow",
    lock_file: "/tmp/bitcoin_monitor_inflow_outflow_capital_behavior_build.lock",
    command: "bin/cron_inflow_outflow_capital_behavior_build.sh",
    active: true,
    order: 100
  },

  "clusters_realtime_pipeline" => {
    label: "Clusters realtime pipeline",
    cron: "* * * * *",
    expected_every: 1.minute,
    late_after: 3.minutes,
    max_runtime: 2.minutes,
    critical: true,
    category: "cluster",
    lock_file: "/tmp/clusters_realtime_pipeline.lock",
    command: "bin/cron_clusters_realtime_pipeline.sh",
    active: true,
    order: 111
  },

  "cluster_scan" => {
    label: "Cluster scan",
    cron: "*/15 * * * *",
    expected_every: 5.minutes,
    late_after: 30.minutes,
    max_runtime: 12.minutes,
    critical: true,
    category: "cluster",
    lock_file: "/tmp/bitcoin_monitor_cluster_scan.lock",
    command: "bin/cron_cluster_scan.sh",
    active: true,
    order: 110
  },

  "cluster_v3_build_metrics" => {
    label: "Cluster V3 build metrics",
    cron: "5 4 * * *",
    expected_every: 24.hours,
    max_runtime: 30.minutes,
    critical: true,
    category: "cluster",
    lock_file: "/tmp/bitcoin_monitor_cluster_v3_build_metrics.lock",
    command: "bin/cron_cluster_v3_build_metrics.sh",
    active: true,
    order: 120
  },

  "cluster_v3_detect_signals" => {
    label: "Cluster V3 detect signals",
    cron: "20 4 * * *",
    expected_every: 24.hours,
    max_runtime: 20.minutes,
    critical: true,
    category: "cluster",
    lock_file: "/tmp/bitcoin_monitor_cluster_v3_detect_signals.lock",
    command: "bin/cron_cluster_v3_detect_signals.sh",
    active: true,
    order: 130
  }
}.freeze