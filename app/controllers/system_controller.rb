# app/controllers/system_controller.rb
class SystemController < ApplicationController
  before_action :catch_up_btc_price_days_in_development, only: [:index]

  def index
    @blockchain_pipeline = measure("blockchain_pipeline") { System::BlockchainPipelineStatus.call }
    @layer1_ingestion = measure("layer1_ingestion") { Blockchain::State::IngestionState.new.call }
    @layer1_processing = measure("layer1_processing") { Blockchain::State::ProcessingState.new.call }

    @layer1_tables = measure("layer1_tables") do
      {
        block_buffers: estimated_count(BlockBufferModel),
        tx_outputs: estimated_count(TxOutput),
        events: estimated_count(Event),
        edges: estimated_count(Edge)
      }
    end

    @realtime = measure("realtime_snapshot") { System::RealtimeSnapshotBuilder.call }
    @cluster_pipeline_status = measure("cluster_pipeline_status_snapshot") do
      payload = SystemSnapshot.latest("cluster_pipeline_status")&.payload || {}
      payload.deep_symbolize_keys
    end
    @jobs = measure("jobs_recent") { JobRun.order(created_at: :desc).limit(20).to_a }
    @sidekiq_status = measure("sidekiq_status") { System::SidekiqStatus.call }
    @scanner_status = measure("scanner_status") { build_scanner_status }
    @exchange_like_status = measure("exchange_like_status") { build_exchange_like_status }
    @btc_status = measure("btc_status") { build_btc_status }

    @snapshot = measure("health_snapshot_snapshot") do
      payload = SystemSnapshot.latest("health_snapshot")&.payload || {}
      payload.deep_symbolize_keys
    end

    @summary = @snapshot["summary"] || {}
    @anomalies = @snapshot["anomalies"] || []
    @job_health = @snapshot["jobs"] || {}
    @recovery = @snapshot["recovery"] || {}

    @recovery_snapshot = measure("recovery_snapshot") { System::RecoverySnapshotBuilder.call }

    @checks = measure("checks") do
      {
        bitcoind: measure("check_bitcoind") { bitcoind_check },
        disks: measure("check_disks") { disks_check },
        bitcoind_activity: measure("check_bitcoind_activity") { bitcoind_activity_check }
      }
    end

    @tables = measure("tables_health_snapshot") do
      payload = SystemSnapshot.latest("tables_health")&.payload || {}
      payload.deep_symbolize_keys
    end
    @cluster_realtime = measure("cluster_realtime_pipeline") { System::ClusterRealtimePipelineStatus.call }

    @recent_blocks = measure("recent_blocks") do
      BlockBufferModel
        .order(height: :desc)
        .limit(12)
        .to_a
    end

    @actor_intelligence = measure("actor_intelligence") do
      System::ActorIntelligenceSnapshotBuilder.call
    end
    @actor_labels_status = System::ActorLabelsStatus.call

  end

  def normalize_system_status(value)
    case value.to_s
    when "fresh"
      "ok"
    when "delayed"
      "warning"
    when "stale"
      "stale"
    when "offline"
      "fail"
    else
      "warning"
    end
  end

  def recovery
    @actor_labels_status = System::ActorLabelsStatus.call
    
    @blockchain_pipeline = measure("recovery.blockchain_pipeline") { System::BlockchainPipelineStatus.call }
    @recovery_state = measure("recovery.state") { System::RecoveryStateBuilder.call }
    @recovery_snapshot = measure("recovery.snapshot") { System::RecoverySnapshotBuilder.call }

    @recovery_snapshot[:layer1_ingestion] =
      measure("recovery.layer1_ingestion") { Blockchain::State::IngestionState.new.call }

    @recovery_snapshot[:layer1_processing] =
      measure("recovery.layer1_processing") { Blockchain::State::ProcessingState.new.call }

    @recovery_snapshot[:layer1_tables] =
      measure("recovery.layer1_tables") do
        {
          block_buffers: estimated_count(BlockBufferModel),
          tx_outputs: estimated_count(TxOutput),
          events: estimated_count(Event),
          edges: estimated_count(Edge)
        }
      end
    @queue_contents = System::SidekiqQueueContentsSnapshot.call

    @actor_labels_last_run =
      JobRun.where(name: "actor_labels_refresh").order(started_at: :desc).first
  end

  def sidekiq
    snapshot = System::RecoverySnapshotBuilder.call

    @queues = snapshot[:queues] || []
    @workers = snapshot[:workers] || []
    @recent_jobs = snapshot[:recent_job_runs] || []
    @locks = snapshot[:locks] || []
    @queue_contents = System::SidekiqQueueContentsSnapshot.call
  end

  private

  def estimated_count(model)
    table_name = model.table_name

    sql = ActiveRecord::Base.sanitize_sql_array([
      "SELECT reltuples::bigint FROM pg_class WHERE oid = ?::regclass",
      table_name
    ])

    ActiveRecord::Base.connection.select_value(sql).to_i
  rescue => e
    Rails.logger.warn(
      "[system_perf] estimated_count #{table_name} failed: #{e.class}: #{e.message}"
    )

    nil
  end

  def measure(label)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = yield

    duration_ms =
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

    Rails.logger.warn("[system_perf] #{label}=#{duration_ms}ms")

    result
  rescue => e
    duration_ms =
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

    Rails.logger.error(
      "[system_perf] #{label}=#{duration_ms}ms ERROR #{e.class}: #{e.message}"
    )

    raise
  end

  def fmt_duration_ms(value)
    return "—" if value.blank?

    total_seconds = (value / 1000.0).round
    minutes = total_seconds / 60
    seconds = total_seconds % 60

    if minutes.positive?
      "#{minutes}m #{seconds}s"
    else
      "#{seconds}s"
    end
  end

  def fmt_seconds(value)
    return "—" if value.blank?

    total_seconds = value.to_i
    minutes = total_seconds / 60
    seconds = total_seconds % 60

    if minutes.positive?
      "#{minutes}m #{seconds}s"
    else
      "#{seconds}s"
    end
  end

  def status_badge_class(status)
    case status.to_s
    when "ok"
      "text-emerald-300 bg-emerald-500/10 border border-emerald-500/20"
    when "running"
      "text-sky-300 bg-sky-500/10 border border-sky-500/20"
    when "warning", "late"
      "text-amber-300 bg-amber-500/10 border border-amber-500/20"
    when "failing", "long_running", "never_ran"
      "text-rose-300 bg-rose-500/10 border border-rose-500/20"
    when "disabled"
      "text-gray-300 bg-gray-500/10 border border-gray-500/20"
    else
      "text-gray-300 bg-gray-500/10 border border-gray-500/20"
    end
  end

  def build_scanner_status
    best_height = BitcoinRpc.new.getblockcount.to_i
    cluster_status = System::ClusterScanStatus.call
    exchange_cursor = ScannerCursor.find_by(name: "exchange_observed_scan")
    exchange_last_height = exchange_cursor&.last_blockheight
    exchange_lag = exchange_last_height ? (best_height - exchange_last_height) : nil

    cluster_cursor = ScannerCursor.find_by(name: "realtime_block_stream")
    cluster_last_height = cluster_cursor&.last_blockheight
    cluster_lag = cluster_last_height ? (best_height - cluster_last_height) : nil

    {
      exchange_observed_scan: {
        label: "Exchange observed scan",
        last_blockheight: exchange_last_height,
        best_height: best_height,
        lag: exchange_lag,
        last_blockhash: exchange_cursor&.last_blockhash,
        updated_at: exchange_cursor&.updated_at,
        status: if exchange_last_height.nil?
                  :warn
                elsif exchange_lag <= 3
                  :ok
                elsif exchange_lag <= 12
                  :warn
                else
                  :fail
                end
      },

      cluster_scan: {
        label: "Cluster realtime",
        last_blockheight: cluster_last_height,
        best_height: best_height,
        lag: cluster_lag,
        last_blockhash: cluster_cursor&.last_blockhash,
        updated_at: cluster_cursor&.updated_at,
        status: cluster_status[:status]
      }
    }
  rescue => e
    {
      exchange_observed_scan: {
        label: "Exchange observed scan",
        error: "#{e.class}: #{e.message}",
        status: :fail
      },
      cluster_scan: {
        label: "Cluster scan",
        error: "#{e.class}: #{e.message}",
        status: :fail
      }
    }
  end

  def build_exchange_like_status
    best_height = BitcoinRpc.new.getblockcount.to_i

    builder_cursor = ScannerCursor.find_by(name: "exchange_address_builder")
    scanner_cursor = ScannerCursor.find_by(name: "exchange_observed_scan")

    builder_last_height = builder_cursor&.last_blockheight
    scanner_last_height = scanner_cursor&.last_blockheight

    builder_lag = builder_last_height ? (best_height - builder_last_height) : nil
    scanner_lag = scanner_last_height ? (best_height - scanner_last_height) : nil

    {
      best_height: best_height,

      builder: {
        label: "Exchange address builder",
        last_blockheight: builder_last_height,
        last_blockhash: builder_cursor&.last_blockhash,
        updated_at: builder_cursor&.updated_at,
        lag: builder_lag,
        status: cursor_health(builder_last_height, builder_lag, builder_cursor&.updated_at)
      },

      scanner: {
        label: "Exchange observed scan",
        last_blockheight: scanner_last_height,
        last_blockhash: scanner_cursor&.last_blockhash,
        updated_at: scanner_cursor&.updated_at,
        lag: scanner_lag,
        status: cursor_health(scanner_last_height, scanner_lag, scanner_cursor&.updated_at)
      },

      metrics: {
        addresses_total: estimated_count(ExchangeAddress),
        addresses_operational: "—",
        addresses_scannable: "—",
        observed_total: estimated_count(ExchangeObservedUtxo),
        new_addresses_24h: "—",
        seen_24h: "—",
        spent_24h: "—"
      }
    }
  rescue => e
    {
      error: "#{e.class}: #{e.message}"
    }
  end

  def build_btc_status
    daily_last = BtcPriceDay.where.not(close_usd: nil).order(day: :desc).first
    snapshot   = MarketSnapshot.latest_ok

    five_m_relation = BtcCandle.for_market("btcusd").for_timeframe("5m")
    one_h_relation  = BtcCandle.for_market("btcusd").for_timeframe("1h")

    five_m_last = five_m_relation.recent_first.first
    one_h_last  = one_h_relation.recent_first.first

    five_m_freshness = Btc::Health::CandlesFreshnessChecker.call(
      last_close_time: five_m_last&.close_time,
      timeframe: "5m"
    )

    one_h_freshness = Btc::Health::CandlesFreshnessChecker.call(
      last_close_time: one_h_last&.close_time,
      timeframe: "1h"
    )

    daily_freshness = Btc::Health::FreshnessChecker.call(
      snapshot&.computed_at || daily_last&.day
    )

    {
      daily: {
        status: normalize_system_status(daily_freshness),
        last_day: daily_last&.day,
        source: daily_last&.source,
        close_usd: daily_last&.close_usd,
        snapshot_at: snapshot&.computed_at,
        ma200_usd: snapshot&.ma200_usd,
        ath_usd: snapshot&.ath_usd
      },

      intraday_5m: {
        status: normalize_system_status(five_m_freshness),
        market: "btcusd",
        timeframe: "5m",
        source: five_m_last&.source,
        candles_count: five_m_relation.count,
        last_open_time: five_m_last&.open_time,
        last_close_time: five_m_last&.close_time,
        last_close: five_m_last&.close
      },

      intraday_1h: {
        status: normalize_system_status(one_h_freshness),
        market: "btcusd",
        timeframe: "1h",
        source: one_h_last&.source,
        candles_count: one_h_relation.count,
        last_open_time: one_h_last&.open_time,
        last_close_time: one_h_last&.close_time,
        last_close: one_h_last&.close
      }
    }
  rescue => e
    {
      error: "#{e.class}: #{e.message}"
    }
  end

  def cursor_health(last_height, lag, updated_at)
    return :warn if last_height.nil?
    return :fail if updated_at.present? && updated_at < 12.hours.ago
    return :ok if lag.to_i <= 3
    return :warn if lag.to_i <= 24

    :fail
  end
  
  # =========================
  # Services checks
  # =========================
  def bitcoind_check
    rpc = BitcoinRpc.new
    info = rpc.get_blockchain_info

    {
      ok: true,
      blocks: info["blocks"],
      headers: info["headers"],
      progress_pct: (info["verificationprogress"].to_f * 100).round(3)
    }
  rescue => e
    { ok: false, error: "#{e.class}: #{e.message}" }
  end

  def bitcoind_activity_check
    rpc = BitcoinRpc.new
    info = rpc.get_blockchain_info

    {
      ok: true,
      blocks: info["blocks"],
      headers: info["headers"],
      lag: info["headers"].to_i - info["blocks"].to_i,
      progress_pct: (info["verificationprogress"].to_f * 100).round(3)
    }
  rescue => e
    { ok: false, error: e.message }
  end

  def disks_check
    {
      bitcoind: disk_usage(path: "/var/lib/bitcoind", warn_pct: 85, fail_pct: 95, label: "Disque blockchain"),
      data:     disk_usage(path: "/mnt/data",         warn_pct: 85, fail_pct: 95, label: "Disque data"),
      system:   disk_usage(path: "/",                 warn_pct: 80, fail_pct: 90, label: "Disque système")
    }
  end

  def disk_usage(path:, warn_pct:, fail_pct:, label:)
    df = `df -h #{path} 2>/dev/null`.to_s

    stat = `df -P #{path} 2>/dev/null | tail -1`.to_s.split
    used_pct = stat[4].to_s.delete("%").to_i rescue nil
    avail    = stat[3]
    mount    = stat[5]

    status =
      if used_pct.nil?
        :warn
      elsif used_pct >= fail_pct
        :fail
      elsif used_pct >= warn_pct
        :warn
      else
        :ok
      end

    {
      label: label,
      path: path,
      mount: mount,
      status: status,
      used_pct: used_pct,
      avail: avail,
      raw: df
    }
  end

  # =========================
  # Tables freshness
  # =========================
  def build_tables_health
    now = Time.current

    btc_last   = BtcPriceDay.order(day: :desc).limit(1).pick(:day)&.in_time_zone
    snap_last  = MarketSnapshot.order(computed_at: :desc).limit(1).pick(:computed_at)&.in_time_zone

    cluster_signals_job_last =
      JobRun.where(name: "cluster_v3_detect_signals", status: "ok", exit_code: 0).maximum(:started_at) ||
      JobRun.where(name: "cluster_v3_detect_signals", status: "ok", exit_code: 0).maximum(:created_at)

    inflow_outflow_last =
      ExchangeFlowDay.order(day: :desc).limit(1).pick(:day)&.in_time_zone

    inflow_outflow_details_last =
      ExchangeFlowDayDetail.order(day: :desc).limit(1).pick(:day)&.in_time_zone

    inflow_outflow_behavior_last =
      ExchangeFlowDayBehavior.order(day: :desc).limit(1).pick(:day)&.in_time_zone

    whale_job_last =
      JobRun.where(name: "whale_scan", status: "ok", exit_code: 0).maximum(:started_at) ||
      JobRun.where(name: "whale_scan", status: "ok", exit_code: 0).maximum(:created_at)

    whale_data_last = WhaleAlert.maximum(:created_at)

    exchange_builder_last =
      JobRun.where(name: "exchange_address_builder", status: "ok", exit_code: 0).maximum(:started_at) ||
      JobRun.where(name: "exchange_address_builder", status: "ok", exit_code: 0).maximum(:created_at)

    exchange_observed_last =
      JobRun.where(name: "exchange_observed_scan", status: "ok", exit_code: 0).maximum(:started_at) ||
      JobRun.where(name: "exchange_observed_scan", status: "ok", exit_code: 0).maximum(:created_at)

    exchange_addresses_last = ExchangeAddress.maximum(:updated_at)
    exchange_observed_utxos_last = ExchangeObservedUtxo.maximum(:updated_at)

    inflow_outflow_capital_behavior_last =
      ExchangeFlowDayCapitalBehavior.order(day: :desc).limit(1).pick(:day)&.in_time_zone

    cluster_last =
      AddressLink.order(block_height: :desc).limit(1).pick(:created_at)&.in_time_zone ||
      Cluster.maximum(:updated_at)&.in_time_zone

    cluster_metrics_last =
      ClusterMetric.order(snapshot_date: :desc).limit(1).pick(:snapshot_date)&.in_time_zone

    cluster_signals_last =
      ClusterSignal.order(snapshot_date: :desc).limit(1).pick(:snapshot_date)&.in_time_zone

    {
      "exchange_addresses" => build_table_row(
        count: estimated_count(ExchangeAddress),
        last_at: exchange_addresses_last,
        sla_h: 26,
        hint: "Set principal des adresses exchange-like. Dernier JobRun builder: #{fmt_time(exchange_builder_last)}",
        now: now
      ),

      "exchange_observed_utxos" => build_table_row(
        count: estimated_count(ExchangeObservedUtxo),
        last_at: exchange_observed_utxos_last,
        sla_h: 1,
        hint: "UTXO observés sur le set exchange-like. Dernier JobRun scanner: #{fmt_time(exchange_observed_last)}",
        now: now
      ),

      "clusters" => build_table_row(
        count: estimated_count(Cluster),
        last_at: cluster_last,
        sla_h: 1,
        hint: "Clusters multi-input construits par le scanner cluster.",
        now: now
      ),

      "whale_alerts" => build_table_row(
        count: estimated_count(WhaleAlert),
        last_at: whale_job_last,
        sla_h: 2,
        hint: "Fraîcheur basée sur JobRun whale_scan. Dernier insert WhaleAlert: #{fmt_time(whale_data_last)}",
        now: now
      ),

      "market_snapshots" => build_table_row(
        count: estimated_count(MarketSnapshot),
        last_at: snap_last,
        sla_h: 26,
        hint: "Snapshot attendu 1 fois / jour.",
        now: now
      ),

      "exchange_flow_days" => build_table_row(
        count: estimated_count(ExchangeFlowDay),
        last_at: inflow_outflow_last,
        sla_h: 36,
        hint: "V1 : agrégats inflow/outflow journaliers calculés depuis exchange_observed_utxos.",
        now: now,
        min_day: Date.yesterday
      ),

      "exchange_flow_day_details" => build_table_row(
        count: estimated_count(ExchangeFlowDayDetail),
        last_at: inflow_outflow_details_last,
        sla_h: 36,
        hint: "V2 : structure des dépôts et retraits observés par buckets.",
        now: now,
        min_day: Date.yesterday
      ),

      "exchange_flow_day_behaviors" => build_table_row(
        count: estimated_count(ExchangeFlowDayBehavior),
        last_at: inflow_outflow_behavior_last,
        sla_h: 36,
        hint: "V3 : ratios comportementaux retail / whale / institution et scores de comportement.",
        now: now,
        min_day: Date.yesterday
      ),

      "exchange_flow_day_capital_behaviors" => build_table_row(
        count: estimated_count(ExchangeFlowDayCapitalBehavior),
        last_at: inflow_outflow_capital_behavior_last,
        sla_h: 36,
        hint: "V4 : capital behavior, whale dominance et divergence activité / capital.",
        now: now,
        min_day: Date.yesterday
      ),

      "btc_price_days" => build_table_row(
        count: estimated_count(BtcPriceDay),
        last_at: btc_last,
        sla_h: 36,
        hint: Rails.env.development? ?
          "En développement : mise à jour quotidienne attendue (J-1), avec rattrapage automatique après redémarrage." :
          "Mise à jour quotidienne attendue (J-1).",
        now: now,
        min_day: Date.current - 1
      ),

      "cluster_metrics" => build_table_row(
        count: estimated_count(ClusterMetric),
        last_at: cluster_metrics_last,
        sla_h: 36,
        hint: "V3.1 : métriques agrégées cluster par snapshot_date.",
        now: now,
        min_day: Date.yesterday
      ),

      "cluster_signals" => build_table_row(
        count: estimated_count(ClusterSignal),
        last_at: cluster_signals_job_last,
        sla_h: 36,
        hint: "V3.1 : signaux cluster détectés à partir des métriques. Dernier snapshot_date présent: #{cluster_signals_last.present? ? cluster_signals_last.to_date.strftime("%Y-%m-%d") : "—"}",
        now: now
      )
    }
  end

  def build_table_row(count:, last_at:, sla_h:, hint:, now:, min_day: nil)
    age_h =
      if last_at.present?
        ((now - last_at) / 3600.0)
      else
        999_999.0
      end

    dev_mode = Rails.env.development?

    status =
      if last_at.blank?
        dev_mode ? :warn : :fail
      elsif min_day
        if last_at.to_date < min_day
          dev_mode ? :warn : :fail
        else
          :ok
        end
      else
        if age_h > sla_h
          dev_mode ? :warn : :fail
        else
          :ok
        end
      end

    {
      count: count,
      last_at: last_at,
      sla_h: sla_h,
      hint: hint,
      age_h: age_h.round(1),
      status: status,
      min_day: min_day
    }
  end

  def fmt_time(value)
    value.present? ? value.in_time_zone.strftime("%Y-%m-%d %H:%M:%S") : "—"
  end

  def catch_up_btc_price_days_in_development
    measure("btc_price_days_catchup_before_action") do
      return unless Rails.env.development?

      last_day = BtcPriceDay.maximum(:day)
      target_day = Date.yesterday

      return if last_day.present? && last_day >= target_day

      BtcPriceDaysCatchup.call(target_day: target_day)
    end
  rescue => e
    Rails.logger.warn("[btc_price_days:catchup] #{e.class}: #{e.message}")
  end

  def build_layer1_tables
    {
      block_buffers: BlockBufferModel.count,
      tx_outputs: TxOutput.count,
      events: Event.count,
      edges: Edge.count
    }
  end

end






