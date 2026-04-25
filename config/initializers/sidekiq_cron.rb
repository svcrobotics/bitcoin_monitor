# frozen_string_literal: true

require "sidekiq/cron/job"

if Sidekiq.server?
  schedule = {
    "exchange_observed_scan" => {
      "cron" => "*/10 * * * *",
      "class" => "ExchangeObservedScanJob",
      "queue" => "default",
      "description" => "Scan exchange observed UTXOs every 10 minutes"
    },
    "cluster_scan" => {
      "cron" => "*/15 * * * *",
      "class" => "ClusterScanJob",
      "queue" => "default",
      "description" => "Scan Bitcoin blocks for cluster analysis"
    },
    "inflow_outflow_build" => {
      "cron" => "25 * * * *",
      "class" => "InflowOutflowBuildJob",
      "queue" => "default",
      "description" => "Build inflow/outflow V1"
    },
    "inflow_outflow_details_build" => {
      "cron" => "35 * * * *",
      "class" => "InflowOutflowDetailsBuildJob",
      "queue" => "default",
      "description" => "Build inflow/outflow V2 details"
    },
    "inflow_outflow_behavior_build" => {
      "cron" => "45 * * * *",
      "class" => "InflowOutflowBehaviorBuildJob",
      "queue" => "default",
      "description" => "Build inflow/outflow V3 behavior"
    },
    "inflow_outflow_capital_behavior_build" => {
      "cron" => "50 * * * *",
      "class" => "InflowOutflowCapitalBehaviorBuildJob",
      "queue" => "default",
      "description" => "Build inflow/outflow V4 capital behavior"
    },
    "whale_scan" => {
      "cron" => "15 * * * *",
      "class" => "WhaleScanJob",
      "queue" => "default",
      "description" => "Scan recent whale transactions"
    },
    "cluster_v3_build_metrics" => {
      "cron" => "5 4 * * *",
      "class" => "ClusterV3BuildMetricsJob",
      "queue" => "default",
      "description" => "Build Cluster V3 metrics"
    },
    "cluster_v3_detect_signals" => {
      "cron" => "20 4 * * *",
      "class" => "ClusterV3DetectSignalsJob",
      "queue" => "default",
      "description" => "Detect Cluster V3 signals"
    },
    "btc_price_daily" => {
      "cron" => "20 0 * * *",
      "class" => "BtcPriceDailyJob",
      "queue" => "default",
      "description" => "Fetch daily BTC price data"
    },
    "market_snapshot" => {
      "cron" => "15 1 * * *",
      "class" => "MarketSnapshotJob",
      "queue" => "default",
      "description" => "Build daily market snapshot"
    },
    "exchange_address_builder" => {
      "cron" => "0,30 * * * *",
      "class" => "ExchangeAddressBuilderJob",
      "queue" => "default",
      "description" => "Rebuild exchange-like address set"
    },
    "whales_reclassify_last_7d" => {
      "cron" => "20 2 * * *",
      "class" => "WhalesReclassifyJob",
      "queue" => "default",
      "description" => "Reclassify whale alerts over the last 7 days"
    },
    "true_flow_rebuild" => {
      "cron" => "10 * * * *",
      "class" => "TrueFlowRebuildJob",
      "queue" => "default",
      "description" => "Rebuild true exchange flow"
    },
    "btc_intraday_5m" => {
      "cron" => "*/5 * * * *",
      "class" => "BtcIntraday5mJob",
      "queue" => "default",
      "description" => "Build BTC intraday 5m candles"
    },

    "btc_intraday_1h" => {
      "cron" => "5 * * * *",
      "class" => "BtcIntraday1hJob",
      "queue" => "default",
      "description" => "Build BTC intraday 1h candles"
    }
  }

  Sidekiq::Cron::Job.load_from_hash!(schedule)
end
