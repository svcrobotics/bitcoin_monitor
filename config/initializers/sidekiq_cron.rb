# frozen_string_literal: true

require "sidekiq/cron/job"

if Sidekiq.server?
  schedule = {
    "exchange_observed_scan" => {
      "cron" => "*/10 * * * *",
      "class" => "ExchangeObservedScanJob",
      "queue" => "p1_exchange",
      "active_job" => true,
      "description" => "Scan exchange observed UTXOs every 10 minutes"
    },

    "cluster_scan" => {
      "cron" => "*/15 * * * *",
      "class" => "ClusterScanJob",
      "queue" => "p3_clusters",
      "active_job" => true,
      "description" => "Scan Bitcoin blocks for cluster analysis"
    },

    "inflow_outflow_build" => {
      "cron" => "25 * * * *",
      "class" => "InflowOutflowBuildJob",
      "queue" => "p2_flows",
      "active_job" => true,
      "description" => "Build inflow/outflow V1"
    },

    "inflow_outflow_details_build" => {
      "cron" => "35 * * * *",
      "class" => "InflowOutflowDetailsBuildJob",
      "queue" => "p2_flows",
      "active_job" => true,
      "description" => "Build inflow/outflow V2 details"
    },

    "inflow_outflow_behavior_build" => {
      "cron" => "45 * * * *",
      "class" => "InflowOutflowBehaviorBuildJob",
      "queue" => "p2_flows",
      "active_job" => true,
      "description" => "Build inflow/outflow V3 behavior"
    },

    "inflow_outflow_capital_behavior_build" => {
      "cron" => "50 * * * *",
      "class" => "InflowOutflowCapitalBehaviorBuildJob",
      "queue" => "p2_flows",
      "active_job" => true,
      "description" => "Build inflow/outflow V4 capital behavior"
    },

    "whale_scan" => {
      "cron" => "15 * * * *",
      "class" => "WhaleScanJob",
      "queue" => "p2_flows",
      "active_job" => true,
      "description" => "Scan recent whale transactions"
    },

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

    "exchange_address_builder" => {
      "cron" => "0,30 * * * *",
      "class" => "ExchangeAddressBuilderJob",
      "queue" => "p1_exchange",
      "active_job" => true,
      "description" => "Rebuild exchange-like address set"
    },

    "whales_reclassify_last_7d" => {
      "cron" => "20 2 * * *",
      "class" => "WhalesReclassifyJob",
      "queue" => "p2_flows",
      "active_job" => true,
      "description" => "Reclassify whale alerts over the last 7 days"
    },

    "true_flow_rebuild" => {
      "cron" => "10 * * * *",
      "class" => "TrueFlowRebuildJob",
      "queue" => "p2_flows",
      "active_job" => true,
      "description" => "Rebuild true exchange flow"
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
    }
  }

  Sidekiq::Cron::Job.load_from_hash!(schedule)
end