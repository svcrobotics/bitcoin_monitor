# app/controllers/system_controller.rb
# frozen_string_literal: true

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

    @actor_profiles_runtime = measure("actor_profiles_runtime") do
      System::ActorProfilesRuntimeSnapshotBuilder.call
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
      BlockBufferModel.order(height: :desc).limit(12).to_a
    end

    @actor_intelligence = measure("actor_intelligence") do
      System::ActorIntelligenceSnapshotBuilder.call
    end

    @actor_labels_status = measure("actor_labels_status") do
      actor_profile_labels = ActorLabel.where(source: "actor_profile")

      {
        total: actor_profile_labels.count,
        exchange_like: actor_profile_labels.where(label: "exchange_like").count,
        whale_like: actor_profile_labels.where(label: "whale_like").count,
        etf_like: actor_profile_labels.where(label: "etf_like").count,
        service_like: actor_profile_labels.where(label: "service_like").count,
        retail_like: actor_profile_labels.where(label: "retail_like").count,
        unknown: actor_profile_labels.where(label: "unknown").count,
        last_updated_at: actor_profile_labels.maximum(:updated_at),
        source: "actor_profile"
      }
    end
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

  def summary
    render partial: "system/blocks/summary"
  end

  def layer1
    snapshot = System::RecoverySnapshotBuilder.call rescue {}
    layer1 = snapshot[:layer1] || {}

    render partial: "system/blocks/layer1",
           locals: { layer1: layer1 }
  end

  def sidekiq_runtime
    render partial: "system/blocks/sidekiq_runtime"
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

    minutes.positive? ? "#{minutes}m #{seconds}s" : "#{seconds}s"
  end

  def fmt_seconds(value)
    return "—" if value.blank?

    total_seconds = value.to_i
    minutes = total_seconds / 60
    seconds = total_seconds % 60

    minutes.positive? ? "#{minutes}m #{seconds}s" : "#{seconds}s"
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
    source = "actor_profile_exchange_like"

    best_height =
      if defined?(BlockBufferModel)
        BlockBufferModel.maximum(:height).to_i
      else
        BitcoinRpc.new.getblockcount.to_i
      end

    labels = ActorLabel.where(source: "actor_profile", label: "exchange_like")
    cluster_ids = labels.pluck(:cluster_id)

    events = ExchangeCoreFlowEvent.where(source: source)

    today_range = Time.current.beginning_of_day..Time.current
    today_events = events.where(event_time: today_range)

    inflow = today_events.where(direction: "inflow").sum(:amount_btc)
    outflow = today_events.where(direction: "outflow").sum(:amount_btc)
    netflow = inflow.to_d - outflow.to_d

    last_height = events.maximum(:block_height)
    lag = last_height.present? ? best_height - last_height.to_i : nil

    addresses_total =
      cluster_ids.empty? ? 0 : Address.where(cluster_id: cluster_ids).count

    {
      source: source,
      label_source: "actor_profile",
      best_height: best_height,

      actors: labels.count,
      clusters: cluster_ids.size,
      addresses_total: addresses_total,

      events_today: today_events.count,
      inflow_btc: inflow,
      outflow_btc: outflow,
      netflow_btc: netflow,

      last_height: last_height,
      lag: lag,
      status: exchange_profile_flow_status(labels.count, today_events.count, lag),

      builder: {
        label: "ActorProfile exchange_like",
        status: labels.exists? ? "ok" : "waiting",
        last_blockheight: last_height,
        lag: lag,
        updated_at: labels.maximum(:updated_at)
      },

      scanner: {
        label: "ExchangeCoreFlow actor_profile events",
        status: today_events.exists? ? "running" : "waiting",
        last_blockheight: last_height,
        lag: lag,
        updated_at: events.maximum(:updated_at)
      },

      metrics: {
        addresses_total: addresses_total,
        addresses_operational: "actor_profile",
        addresses_scannable: "actor_profile",
        observed_total: events.count,
        new_addresses_24h: "—",
        seen_24h: today_events.where(direction: "inflow").count,
        spent_24h: today_events.where(direction: "outflow").count
      }
    }
  rescue => e
    {
      error: "#{e.class}: #{e.message}"
    }
  end

  def exchange_profile_flow_status(actor_count, events_today, lag)
    return "waiting" if actor_count.to_i.zero?
    return "warning" if lag.present? && lag.to_i > 12
    return "running" if events_today.to_i.positive?

    "ok"
  end

  def build_btc_status
    daily_last = BtcPriceDay.where.not(close_usd: nil).order(day: :desc).first
    snapshot = MarketSnapshot.latest_ok

    five_m_relation = BtcCandle.for_market("btcusd").for_timeframe("5m")
    one_h_relation = BtcCandle.for_market("btcusd").for_timeframe("1h")

    five_m_last = five_m_relation.recent_first.first
    one_h_last = one_h_relation.recent_first.first

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
      data: disk_usage(path: "/mnt/data", warn_pct: 85, fail_pct: 95, label: "Disque data"),
      system: disk_usage(path: "/", warn_pct: 80, fail_pct: 90, label: "Disque système")
    }
  end

  def disk_usage(path:, warn_pct:, fail_pct:, label:)
    df = `df -h #{path} 2>/dev/null`.to_s

    stat = `df -P #{path} 2>/dev/null | tail -1`.to_s.split
    used_pct = stat[4].to_s.delete("%").to_i rescue nil
    avail = stat[3]
    mount = stat[5]

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

  def build_tables_health
    now = Time.current

    btc_last = BtcPriceDay.order(day: :desc).limit(1).pick(:day)&.in_time_zone
    snap_last = MarketSnapshot.order(computed_at: :desc).limit(1).pick(:computed_at)&.in_time_zone

    cluster_signals_job_last =
      JobRun.where(name: "cluster_v3_detect_signals", status: "ok", exit_code: 0).maximum(:started_at) ||
      JobRun.where(name: "cluster_v3_detect_signals", status: "ok", exit_code: 0).maximum(:created_at)

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

    exchange_core_flow_last =
      ExchangeCoreFlowEvent.maximum(:event_time)&.in_time_zone

    cluster_last =
      AddressLink.order(block_height: :desc).limit(1).pick(:created_at)&.in_time_zone ||
      Cluster.maximum(:updated_at)&.in_time_zone

    {
      "exchange_core_flow_events" => build_table_row(
        count: estimated_count(ExchangeCoreFlowEvent),
        last_at: exchange_core_flow_last,
        sla_h: 1,
        hint: "Nouvelle architecture : flux exchange-like calculés depuis Actor Labels / Actor Profiles via ExchangeCoreFlowEvent.",
        now: now
      ),

      "exchange_addresses" => build_table_row(
        count: estimated_count(ExchangeAddress),
        last_at: exchange_addresses_last,
        sla_h: 26,
        hint: "Ancien set d'adresses exchange-like. Dernier JobRun builder: #{fmt_time(exchange_builder_last)}",
        now: now
      ),

      "exchange_observed_utxos" => build_table_row(
        count: estimated_count(ExchangeObservedUtxo),
        last_at: exchange_observed_utxos_last,
        sla_h: 1,
        hint: "Ancienne source UTXO observés exchange-like. Dernier JobRun scanner: #{fmt_time(exchange_observed_last)}",
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

      "btc_price_days" => build_table_row(
        count: estimated_count(BtcPriceDay),
        last_at: btc_last,
        sla_h: 36,
        hint: Rails.env.development? ?
          "En développement : mise à jour quotidienne attendue (J-1), avec rattrapage automatique après redémarrage." :
          "Mise à jour quotidienne attendue (J-1).",
        now: now,
        min_day: Date.current - 1
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