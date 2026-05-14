# config/initializers/system_jobs.rb

SYSTEM_JOBS = {
  # -------------------------------------------------------------------
  # BTC / MARKET
  # -------------------------------------------------------------------

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
    late_after: 48.hours,
    max_runtime: 10.minutes,
    critical: true,
    category: "market",
    lock_file: "/tmp/bitcoin_monitor_market_snapshot.lock",
    command: "bin/cron_market_snapshot.sh",
    active: true,
    order: 20
  },

  # -------------------------------------------------------------------
  # WHALES
  # -------------------------------------------------------------------

  "whale_scan" => {
    label: "Whale scan",
    cron: "15 * * * *",
    expected_every: 1.hour,
    late_after: 2.hours,
    max_runtime: 20.minutes,
    critical: true,
    category: "whales",
    lock_file: "/tmp/bitcoin_monitor_whales_scan.lock",
    command: "WhaleScanJob / WhaleLayer1Scanner",
    active: true,
    order: 30
  },

  # -------------------------------------------------------------------
  # EXCHANGE-LIKE
  # -------------------------------------------------------------------

  "exchange_address_builder" => {
    label: "Exchange address builder",
    cron: "0 */6 * * *",
    expected_every: 6.hours,
    late_after: 12.hours,
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
    expected_every: 30.minutes,
    late_after: 1.hour,
    max_runtime: 30.minutes,
    critical: true,
    category: "exchange",
    lock_file: "/tmp/bitcoin_monitor_exchange_observed_scan.lock",
    command: "bin/cron_exchange_observed_scan.sh",
    active: true,
    order: 60
  },

  # -------------------------------------------------------------------
  # INFLOW / OUTFLOW PIPELINE
  # -------------------------------------------------------------------

  "inflow_outflow_build" => {
    label: "Inflow / Outflow pipeline",
    cron: "25 * * * *",
    expected_every: 2.hour,
    late_after: 3.hours,
    max_runtime: 30.minutes,
    critical: true,
    category: "inflow_outflow",
    lock_file: "/tmp/bitcoin_monitor_inflow_outflow_build.lock",
    command: "InflowOutflowPipelineBuilder",
    active: true,
    order: 70
  },

  # -------------------------------------------------------------------
  # LEGACY PIPELINES (DISABLED)
  # -------------------------------------------------------------------

  "inflow_outflow_details_build" => {
    label: "Inflow / Outflow details legacy",
    active: false,
    category: "legacy",
    order: 80
  },

  "inflow_outflow_behavior_build" => {
    label: "Inflow / Outflow behavior legacy",
    active: false,
    category: "legacy",
    order: 90
  },

  "inflow_outflow_capital_behavior_build" => {
    label: "Inflow / Outflow capital behavior legacy",
    active: false,
    category: "legacy",
    order: 100
  },

  # "clusters_realtime_pipeline" => {
  #  label: "Clusters realtime pipeline legacy",
  #  active: false,
  #  category: "legacy",
  #  order: 105
  # },

  # -------------------------------------------------------------------
  # CLUSTERS
  # -------------------------------------------------------------------

  "cluster_scan" => {
    label: "Cluster scan",
    cron: "*/15 * * * *",
    expected_every: 15.minutes,
    late_after: 45.minutes,
    max_runtime: 10.minutes,
    critical: true,
    category: "cluster",
    lock_file: "/tmp/bitcoin_monitor_cluster_scan.lock",
    command: "ClusterScanner / DirtyClusterQueue",
    active: true,
    order: 110
  },

  "cluster_v3_build_metrics" => {
    label: "Cluster V3 build metrics",
    cron: "5 4 * * *",
    expected_every: 24.hours,
    late_after: 48.hours,
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
    late_after: 48.hours,
    max_runtime: 20.minutes,
    critical: true,
    category: "cluster",
    lock_file: "/tmp/bitcoin_monitor_cluster_v3_detect_signals.lock",
    command: "bin/cron_cluster_v3_detect_signals.sh",
    active: true,
    order: 130
  },

  "cluster_refresh_dirty_clusters" => {
    label: "Cluster refresh dirty clusters",
    cron: "*/5 * * * *",
    expected_every: 5.minutes,
    late_after: 20.minutes,
    max_runtime: 5.minutes,
    critical: true,
    category: "cluster",
    lock_file: nil,
    command: "Clusters::RefreshDirtyClustersJob",
    active: true,
    order: 115
  }
}.freeze

