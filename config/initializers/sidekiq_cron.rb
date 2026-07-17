# frozen_string_literal: true

if !(defined?(Sidekiq) && Sidekiq.respond_to?(:server?) && Sidekiq.server?)
  Rails.logger.info("[sidekiq_cron] skipped outside Sidekiq server") if defined?(Rails)
elsif ENV["LAYER1_STRICT_ONLY"] == "1"
  Rails.logger.info("[sidekiq_cron] disabled because LAYER1_STRICT_ONLY=1") if defined?(Rails)
elsif ENV["SIDEKIQ_LEGACY_CRON"] != "1"
  Rails.logger.info("[sidekiq_cron] disabled because SIDEKIQ_LEGACY_CRON!=1") if defined?(Rails)
else
  require "sidekiq/cron/job"

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

    
    "search_refresh" => {
      "class" => "SearchRefreshJob",
      "cron" => "*/10 * * * *",
      "queue" => "low"
    },

    "tx_outputs_retention" => {
      "class" => "TxOutputsRetentionJob",
      "cron" => "0 3 * * *",
      "queue" => "low"
    },


    "layer1_balance" => {
      "class" => "Layer1BalanceJob",
      "cron" => "*/1 * * * *",
      "queue" => "low"
    },

    # "layer1_orchestrator" désactivé : pipeline strict uniquement

    # "cluster_input_orchestrator" désactivé : pipeline strict uniquement

    "economic_indicators_dollar" => {
      "cron" => "0 18 * * 1-5",
      "class" => "EconomicIndicators::FetchDollarIndexJob",
      "queue" => "low",
      "description" => "Fetch daily dollar index from FRED"
    },

    "economic_indicators_us10y" => {
      "class" => "EconomicIndicators::FetchUs10yJob",
      "cron" => "5 18 * * 1-5",
      "queue" => "low"
    },

    "economic_indicators_fed_funds_rate" => {
      "class" => "EconomicIndicators::FetchFedFundsRateJob",
      "cron" => "10 18 * * *",
      "queue" => "low"
    },

    "economic_indicators_sp500" => {
      "class" => "EconomicIndicators::FetchSp500Job",
      "cron" => "20 18 * * 1-5",
      "queue" => "low"
    },

    "economic_indicators_nasdaq" => {
      "class" => "EconomicIndicators::FetchNasdaqJob",
      "cron" => "25 18 * * 1-5",
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
