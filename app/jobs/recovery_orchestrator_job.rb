# frozen_string_literal: true

class RecoveryOrchestratorJob < ApplicationJob
  queue_as :default

  LOCK_NAME = "recovery_orchestrator_lock"
  LOCK_TTL  = 10.minutes

  def perform
    lock = ScannerCursor.find_or_create_by!(name: LOCK_NAME)

    locked = lock.with_lock do
      if lock.updated_at.present? && lock.updated_at > LOCK_TTL.ago
        false
      else
        lock.touch
        true
      end
    end

    unless locked
      Rails.logger.info("[recovery] skip lock_active")
      return { ok: true, skipped: true, reason: "lock_active" }
    end

    run_recovery!
  ensure
    lock&.update!(updated_at: LOCK_TTL.ago - 1.second)
  end

  private

  def run_recovery!
    best_height = BitcoinRpc.new(wallet: nil).getblockcount.to_i
    state = System::RecoveryStateBuilder.call

    Rails.logger.info(
      "[recovery] state=#{state[:state]} " \
      "realtime_lag=#{state[:realtime_lag]} " \
      "exchange_lag=#{state[:exchange_lag]} " \
      "cluster_lag=#{state[:cluster_lag]}"
    )

    Rails.logger.info("[recovery] start best_height=#{best_height}")

    recover_p0_realtime!(best_height)
    recover_p1_exchange!(best_height)
    recover_p2_flows!
    recover_p3_clusters!(best_height)
    recover_p4_analytics!

    Rails.logger.info("[recovery] done best_height=#{best_height}")

    { ok: true, best_height: best_height }
  end

  def recover_p0_realtime!(best_height)
    lag = cursor_lag("realtime_block_stream", best_height)
    return if lag <= 0

    Rails.logger.info("[recovery][P0] enqueue realtime lag=#{lag}")
    Realtime::ProcessLatestBlockJob.perform_later
  end

  def recover_p1_exchange!(best_height)
    lag = cursor_lag("exchange_observed_scan", best_height)
    return if lag <= 1

    Rails.logger.info("[recovery][P1] enqueue exchange_observed_scan lag=#{lag}")
    ExchangeObservedScanJob.perform_later
  end

  def recover_p2_flows!
    latest_flow_day = ExchangeFlowDay.maximum(:day)
    return if latest_flow_day.present? && latest_flow_day >= Date.current

    Rails.logger.info("[recovery][P2] enqueue inflow/outflow rebuild")

    InflowOutflowBuildJob.perform_later
  end

  def recover_p3_clusters!(best_height)
    lag = cursor_lag("cluster_scan", best_height)
    return if lag <= 1

    Rails.logger.info("[recovery][P3] enqueue cluster_scan lag=#{lag}")
    ClusterScanJob.perform_later
  end

  def recover_p4_analytics!
    today = Date.current

    if ClusterMetric.maximum(:snapshot_date).blank? || ClusterMetric.maximum(:snapshot_date) < today
      Rails.logger.info("[recovery][P4] enqueue cluster_v3_build_metrics")
      ClusterV3BuildMetricsJob.perform_later
    end

    if ClusterSignal.maximum(:snapshot_date).blank? || ClusterSignal.maximum(:snapshot_date) < today
      Rails.logger.info("[recovery][P4] enqueue cluster_v3_detect_signals")
      ClusterV3DetectSignalsJob.perform_later
    end
  end

  def cursor_lag(cursor_name, best_height)
    cursor = ScannerCursor.find_by(name: cursor_name)
    height = cursor&.last_blockheight.to_i

    height.positive? ? best_height - height : best_height
  end
end