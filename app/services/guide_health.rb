# frozen_string_literal: true

class GuideHealth
  MODULES = {
    "inflow-outflow" => {
      label: "Inflow / Outflow",
      jobs: %w[
        inflow_outflow_build
        inflow_outflow_details_build
        inflow_outflow_behavior_build
        inflow_outflow_capital_behavior_build
      ],
      tables: %w[
        exchange_flow_days
        exchange_flow_day_details
        exchange_flow_day_behaviors
        exchange_flow_day_capital_behaviors
        exchange_observed_utxos
      ],
      scanners: %w[
        exchange_observed_scan
      ]
    },

    "whales" => {
      label: "Whale Alerts",
      jobs: %w[
        whale_scan
        whales_reclassify_last_7d
      ],
      tables: %w[
        whale_alerts
      ],
      scanners: []
    },

    "cluster" => {
      label: "Cluster",
      jobs: %w[
        cluster_v3_build_metrics
        cluster_v3_detect_signals
      ],
      tables: %w[
        clusters
        addresses
        address_links
        cluster_profiles
        cluster_metrics
        cluster_signals
      ],
      scanners: %w[
        cluster_scan
      ]
    },

    "system" => {
      label: "System",
      jobs: %w[
        whale_scan
        exchange_observed_scan
        cluster_v3_build_metrics
        cluster_v3_detect_signals
        inflow_outflow_build
        inflow_outflow_details_build
        inflow_outflow_behavior_build
        inflow_outflow_capital_behavior_build
        market_snapshot
      ],
      tables: %w[
        btc_price_days
        exchange_true_flows
        exchange_flow_days
        exchange_flow_day_details
        exchange_flow_day_behaviors
        exchange_flow_day_capital_behaviors
        whale_alerts
        cluster_metrics
        cluster_signals
      ],
      scanners: %w[
        exchange_observed_scan
        cluster_scan
      ]
    }
  }.freeze

  def self.for(guide)
    return nil if guide.nil?

    key = guide.slug.to_s
    config = MODULES[key]
    return nil unless config

    new(config).call
  end

  def initialize(config)
    @config = config
  end

  def call
    jobs = build_jobs
    tables = build_tables
    scanners = build_scanners

    {
      label: @config[:label],
      jobs: jobs,
      tables: tables,
      scanners: scanners,
      overall_status: compute_overall_status(jobs, tables, scanners)
    }
  end

  private

  def build_jobs
    @config[:jobs].map do |job_name|
      jr = JobRun.for_job(job_name).recent.first

      {
        name: job_name,
        status: jr&.status || "missing",
        started_at: jr&.started_at,
        duration_ms: jr&.duration_ms,
        error: jr&.error
      }
    end
  end

  def build_tables
    @config[:tables].map do |table_name|
      {
        name: table_name,
        count: safe_count(table_name),
        freshness: table_freshness(table_name)
      }
    end
  end

  def build_scanners
    @config[:scanners].map do |scanner_name|
      cursor = ScannerCursor.find_by(name: scanner_name)

      {
        name: scanner_name,
        last_blockheight: cursor&.last_blockheight,
        last_blockhash: cursor&.last_blockhash,
        updated_at: cursor&.updated_at,
        status: scanner_status(cursor)
      }
    end
  end

  def compute_overall_status(jobs, tables, scanners)
    states = []

    states += jobs.map { |j| normalize_job_status(j[:status]) }
    states += tables.map { |t| t.dig(:freshness, :status) || :unknown }
    states += scanners.map { |s| s[:status] || :unknown }

    return :unknown if states.empty?
    return :fail if states.include?(:fail)
    return :warn if states.include?(:warn) || states.include?(:missing)

    :ok
  end

  def normalize_job_status(status)
    case status.to_s
    when "ok" then :ok
    when "fail" then :fail
    when "running" then :warn
    else :missing
    end
  end

  def scanner_status(cursor)
    return :warn unless cursor&.updated_at

    age = Time.current - cursor.updated_at

    if age <= 2.hours
      :ok
    elsif age <= 8.hours
      :warn
    else
      :fail
    end
  end

  def safe_count(table_name)
    ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM #{table_name}").to_i
  rescue
    nil
  end

  def table_freshness(table_name)
    timestamp =
      case table_name
      when "btc_price_days"
        BtcPriceDay.order(day: :desc).pick(:day)
      when "exchange_true_flows"
        ExchangeTrueFlow.order(day: :desc).pick(:day)
      when "exchange_flow_days"
        ExchangeFlowDay.order(day: :desc).pick(:day)
      when "exchange_flow_day_details"
        ExchangeFlowDayDetail.order(day: :desc).pick(:day)
      when "exchange_flow_day_behaviors"
        ExchangeFlowDayBehavior.order(day: :desc).pick(:day)
      when "exchange_flow_day_capital_behaviors"
        ExchangeFlowDayCapitalBehavior.order(day: :desc).pick(:day)
      when "whale_alerts"
        WhaleAlert.maximum(:created_at)
      when "cluster_metrics"
        ClusterMetric.maximum(:snapshot_date)
      when "cluster_signals"
        ClusterSignal.maximum(:snapshot_date)
      when "clusters"
        Cluster.maximum(:updated_at)
      when "addresses"
        Address.maximum(:updated_at)
      when "address_links"
        AddressLink.maximum(:updated_at)
      when "cluster_profiles"
        ClusterProfile.maximum(:updated_at)
      when "exchange_observed_utxos"
        ExchangeObservedUtxo.maximum(:updated_at)
      else
        nil
      end

    status =
      if timestamp.nil?
        :warn
      else
        age_days =
          if timestamp.respond_to?(:to_date)
            (Date.current - timestamp.to_date).to_i
          else
            999
          end

        if age_days <= 1
          :ok
        elsif age_days <= 3
          :warn
        else
          :fail
        end
      end

    {
      last_value: timestamp,
      status: status
    }
  rescue
    {
      last_value: nil,
      status: :warn
    }
  end
end