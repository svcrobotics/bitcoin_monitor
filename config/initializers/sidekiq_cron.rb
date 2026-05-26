# frozen_string_literal: true

require "sidekiq/cron/job"

if Sidekiq.server?
  schedule = {
    # ------------------------------------------------------------
    # BTC / MARKET - jobs légers, OK via Sidekiq cron
    # ------------------------------------------------------------

    "btc_price_daily" => {
      "cron" => "20 0 * * *",
      "class" => "BtcPriceDailyJob",
      "queue" => "default",
      "active_job" => true,
      "description" => "Fetch daily BTC price data"
    },

    "market_snapshot" => {
      "cron" => "15 1 * * *",
      "class" => "MarketSnapshotJob",
      "queue" => "default",
      "active_job" => true,
      "description" => "Build daily market snapshot"
    },

    "btc_intraday_5m" => {
      "cron" => "*/5 * * * *",
      "class" => "BtcIntraday5mJob",
      "queue" => "default",
      "active_job" => true,
      "description" => "Build BTC intraday 5m candles"
    },

    "btc_intraday_1h" => {
      "cron" => "5 * * * *",
      "class" => "BtcIntraday1hJob",
      "queue" => "default",
      "active_job" => true,
      "description" => "Build BTC intraday 1h candles"
    },

    # ------------------------------------------------------------
    # CLUSTER - uniquement refresh léger
    # Les scans cluster lourds sont pilotés par bin/cron_cluster_scan.sh
    # ------------------------------------------------------------

    # "cluster_refresh_dirty_clusters" => {
    #  "cron" => "*/5 * * * *",
    #  "class" => "Clusters::RefreshDirtyClustersJob",
    #  "queue" => "p3_clusters_refresh",
    #  "active_job" => true,
    #  "description" => "Refresh dirty clusters in small batches"
    # },

    # ------------------------------------------------------------
    # CLUSTER ANALYTICS - batch quotidien
    # ------------------------------------------------------------

    "cluster_v3_build_metrics" => {
      "cron" => "5 4 * * *",
      "class" => "ClusterV3BuildMetricsJob",
      "queue" => "p4_analytics",
      "active_job" => true,
      "description" => "Build Cluster V3 metrics"
    },

    "cluster_v3_detect_signals" => {
      "cron" => "20 4 * * *",
      "class" => "ClusterV3DetectSignalsJob",
      "queue" => "p4_analytics",
      "active_job" => true,
      "description" => "Detect Cluster V3 signals"
    },

    "actor_profiles_dispatcher" => {
      "cron" => "*/1 * * * *",
      "class" => "ActorProfilesDispatcherJob",
      "queue" => "p3_actor_profile_light",
      "active_job" => true,
      "description" => "Dispatch dirty actor profile clusters every minute"
    },
    
    "system_snapshots_refresh" => {
      "class" => "SystemSnapshotsRefreshJob",
      "cron" => "*/5 * * * *",
      "queue" => "low"
    },

    "search_refresh" => {
      "class" => "SearchRefreshJob",
      "cron" => "*/10 * * * *",
      "queue" => "low"
    }

    # ------------------------------------------------------------
    # DÉSACTIVÉS ICI VOLONTAIREMENT
    # ------------------------------------------------------------
    #
    # exchange_observed_scan
    # exchange_address_builder
    # inflow_outflow_build
    # whale_scan
    # cluster_scan
    # true_flow_rebuild
    # whales_reclassify_last_7d
    #
    # Ces jobs sont trop lourds ou déjà pilotés par cron shell.
    # Les laisser ici provoque des backlogs Sidekiq massifs.
  }

  Sidekiq::Cron::Job.load_from_hash!(schedule)
end