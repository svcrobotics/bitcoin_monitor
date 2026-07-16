# frozen_string_literal: true

module System
  module Anomalies
    module Layer1Rules
      module_function

      CRITICAL_LAG_BLOCKS = 30

      def call(context:)
        pipeline =
          context[:pipeline] || {}
        health =
          context[:layer1_health] || {}

        layer1 =
          pipeline[:layer1] || {}

        anomalies = []

        if health[:status].to_s == "critical"
          anomalies << Base.anomaly(
            code: "layer1_health_critical",
            module_name: "layer1",
            severity: "critical",
            title: "Layer1 signale un état critique",
            facts: {
              status: health[:status],
              lag_blocks: health[:lag] || layer1[:lag],
              processing_stale_seconds:
                health.dig(:strict, :processing_stale_seconds)
            }.compact,
            fingerprint: "layer1:health_critical"
          )
        elsif health[:status].to_s == "warning"
          anomalies << Base.anomaly(
            code: "layer1_health_warning",
            module_name: "layer1",
            severity: "warning",
            title: "Layer1 signale un avertissement",
            facts: {
              status: health[:status],
              lag_blocks: health[:lag] || layer1[:lag]
            }.compact,
            fingerprint: "layer1:health_warning",
            confirmation_observations: 2
          )
        end

        lag =
          layer1[:lag].to_i

        if lag >= CRITICAL_LAG_BLOCKS
          anomalies << Base.anomaly(
            code: "layer1_lag_critical",
            module_name: "layer1",
            severity: "critical",
            title: "Layer1 a un retard critique",
            facts: {
              lag_blocks: lag,
              processed_height: layer1[:processed_height],
              bitcoin_core_height:
                pipeline.dig(:bitcoin_core, :best_height)
            }.compact,
            fingerprint: "layer1:lag_critical"
          )
        end

        stale_seconds =
          health.dig(:strict, :processing_stale_seconds).to_i

        if health.dig(:strict, :stalled) == true
          anomalies << Base.anomaly(
            code: "layer1_stalled",
            module_name: "layer1",
            severity: "critical",
            title: "Layer1 est en rattrapage sans travail strict",
            facts: {
              lag_blocks: lag,
              stalled_seconds:
                health.dig(:strict, :stalled_seconds),
              catch_up_active:
                health.dig(:strict, :catch_up_active),
              layer1_work_active:
                health.dig(:strict, :layer1_work_active),
              layer1_work_queued:
                health.dig(:strict, :layer1_work_queued),
              last_scheduler_tick_at:
                health.dig(:strict, :last_scheduler_tick_at),
              last_enqueue_at:
                health.dig(:strict, :last_enqueue_at),
              stalled_reason:
                health.dig(:strict, :stalled_reason)
            }.compact,
            fingerprint: "layer1:stalled"
          )
        end

        if stale_seconds.positive? &&
           stale_seconds >
             Layer1::Realtime::HealthSnapshot::PROCESSING_STALE_SECONDS
          anomalies << Base.anomaly(
            code: "layer1_processing_stale",
            module_name: "layer1",
            severity: "critical",
            title: "Layer1 traite un bloc depuis trop longtemps",
            facts: {
              stale_for_seconds: stale_seconds,
              processing_height:
                health.dig(:strict, :processing_block, :height) ||
                layer1[:processing_height]
            }.compact,
            fingerprint: "layer1:processing_stale"
          )
        end

        anomalies
      end
    end
  end
end
