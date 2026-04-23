# app/controllers/system_controller.rb
class SystemController < ApplicationController
  before_action :ensure_local_or_development!, only: [:run_tests]
  before_action :catch_up_btc_price_days_in_development, only: [:index]

  def index
    @jobs = JobRun.recent.limit(200)
    @scanner_status = build_scanner_status
    @exchange_like_status = build_exchange_like_status
    @btc_status = build_btc_status

    @snapshot  = System::HealthSnapshotBuilder.call
    @summary   = @snapshot[:summary]
    @anomalies = @snapshot[:anomalies]
    @job_health = @snapshot[:jobs]
    @recovery  = @snapshot[:recovery]

    @checks = {
      bitcoind: bitcoind_check,
      disks: disks_check,
      bitcoind_activity: bitcoind_activity_check
    }

    @tables = build_tables_health
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

  def tests
    @qa_groups  = SystemTestStatus.groups
    @qa_summary = SystemTestStatus.summary
    @qa_stats   = SystemTestStatus.new.global_stats

    log_path = Rails.root.join("tmp/qa/cluster_v3_last_run.log")
    @last_test_output = File.exist?(log_path) ? File.read(log_path).truncate(5000) : nil
  end

  def run_tests
    result = SystemTestRunner.call

    if result.ok?
      redirect_to system_tests_path, notice: "Tests Cluster V3 exécutés avec succès."
    else
      redirect_to system_tests_path, alert: "Échec de l’exécution des tests (code #{result.status}). Consulte tmp/qa/cluster_v3_last_run.log."
    end
  end

  private

  def ensure_local_or_development!
    return if Rails.env.development?
    return if request.local?

    head :forbidden
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

    exchange_cursor = ScannerCursor.find_by(name: "exchange_observed_scan")
    exchange_last_height = exchange_cursor&.last_blockheight
    exchange_lag = exchange_last_height ? (best_height - exchange_last_height) : nil

    cluster_cursor = ScannerCursor.find_by(name: "cluster_scan")
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
        label: "Cluster scan",
        last_blockheight: cluster_last_height,
        best_height: best_height,
        lag: cluster_lag,
        last_blockhash: cluster_cursor&.last_blockhash,
        updated_at: cluster_cursor&.updated_at,
        status: if cluster_last_height.nil?
                  :warn
                elsif cluster_lag <= 3
                  :ok
                elsif cluster_lag <= 12
                  :warn
                else
                  :fail
                end
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
        addresses_total: ExchangeAddress.count,
        addresses_operational: ExchangeAddress.operational.count,
        addresses_scannable: ExchangeAddress.scannable.count,
        observed_total: ExchangeObservedUtxo.count,
        new_addresses_24h: ExchangeAddress.where("first_seen_at >= ?", 24.hours.ago).count,
        seen_24h: ExchangeObservedUtxo.where("seen_day >= ?", Date.current - 1).count,
        spent_24h: ExchangeObservedUtxo.where.not(spent_day: nil).where("spent_day >= ?", Date.current - 1).count
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
        count: ExchangeAddress.count,
        last_at: exchange_addresses_last,
        sla_h: 26,
        hint: "Set principal des adresses exchange-like. Dernier JobRun builder: #{fmt_time(exchange_builder_last)}",
        now: now
      ),

      "exchange_observed_utxos" => build_table_row(
        count: ExchangeObservedUtxo.count,
        last_at: exchange_observed_utxos_last,
        sla_h: 1,
        hint: "UTXO observés sur le set exchange-like. Dernier JobRun scanner: #{fmt_time(exchange_observed_last)}",
        now: now
      ),

      "clusters" => build_table_row(
        count: Cluster.count,
        last_at: cluster_last,
        sla_h: 1,
        hint: "Clusters multi-input construits par le scanner cluster.",
        now: now
      ),

      "whale_alerts" => build_table_row(
        count: WhaleAlert.count,
        last_at: whale_job_last,
        sla_h: 2,
        hint: "Fraîcheur basée sur JobRun whale_scan. Dernier insert WhaleAlert: #{fmt_time(whale_data_last)}",
        now: now
      ),

      "market_snapshots" => build_table_row(
        count: MarketSnapshot.count,
        last_at: snap_last,
        sla_h: 26,
        hint: "Snapshot attendu 1 fois / jour.",
        now: now
      ),

      "exchange_flow_days" => build_table_row(
        count: ExchangeFlowDay.count,
        last_at: inflow_outflow_last,
        sla_h: 36,
        hint: "V1 : agrégats inflow/outflow journaliers calculés depuis exchange_observed_utxos.",
        now: now,
        min_day: Date.yesterday
      ),

      "exchange_flow_day_details" => build_table_row(
        count: ExchangeFlowDayDetail.count,
        last_at: inflow_outflow_details_last,
        sla_h: 36,
        hint: "V2 : structure des dépôts et retraits observés par buckets.",
        now: now,
        min_day: Date.yesterday
      ),

      "exchange_flow_day_behaviors" => build_table_row(
        count: ExchangeFlowDayBehavior.count,
        last_at: inflow_outflow_behavior_last,
        sla_h: 36,
        hint: "V3 : ratios comportementaux retail / whale / institution et scores de comportement.",
        now: now,
        min_day: Date.yesterday
      ),

      "exchange_flow_day_capital_behaviors" => build_table_row(
        count: ExchangeFlowDayCapitalBehavior.count,
        last_at: inflow_outflow_capital_behavior_last,
        sla_h: 36,
        hint: "V4 : capital behavior, whale dominance et divergence activité / capital.",
        now: now,
        min_day: Date.yesterday
      ),

      "btc_price_days" => build_table_row(
        count: BtcPriceDay.count,
        last_at: btc_last,
        sla_h: 36,
        hint: Rails.env.development? ?
          "En développement : mise à jour quotidienne attendue (J-1), avec rattrapage automatique après redémarrage." :
          "Mise à jour quotidienne attendue (J-1).",
        now: now,
        min_day: Date.current - 1
      ),

      "cluster_metrics" => build_table_row(
        count: ClusterMetric.count,
        last_at: cluster_metrics_last,
        sla_h: 36,
        hint: "V3.1 : métriques agrégées cluster par snapshot_date.",
        now: now,
        min_day: Date.yesterday
      ),

      "cluster_signals" => build_table_row(
        count: ClusterSignal.count,
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
    return unless Rails.env.development?

    last_day = BtcPriceDay.maximum(:day)
    target_day = Date.yesterday

    return if last_day.present? && last_day >= target_day

    BtcPriceDaysCatchup.call(target_day: target_day)
  rescue => e
    Rails.logger.warn("[btc_price_days:catchup] #{e.class}: #{e.message}")
  end

end






