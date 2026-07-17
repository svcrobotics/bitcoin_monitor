# frozen_string_literal: true

module System
  class AnomalySnapshot
    RULES = [
      System::Anomalies::InfrastructureRules,
      System::Anomalies::Layer1Rules,
      System::Anomalies::ClusterRules,
      System::Anomalies::ActorProfileRules,
      System::Anomalies::ActorBehaviorRules,
      System::Anomalies::ActorLabelsRules,
      System::Anomalies::SidekiqRules
    ].freeze

    SEVERITY_RANK = {
      "critical" => 0,
      "warning" => 1
    }.freeze

    def self.call
      new.call
    end

    def call
      context =
        build_context

      anomalies =
        RULES.flat_map do |rule|
          safe_rule_call(rule, context)
        end

      sorted =
        anomalies
          .map { |anomaly| normalize_anomaly(anomaly) }
          .compact
          .sort_by do |anomaly|
            [
              SEVERITY_RANK.fetch(anomaly[:severity], 9),
              anomaly[:module],
              anomaly[:code],
              anomaly[:fingerprint]
            ]
          end

      {
        generated_at: Time.current,
        overall_severity: overall_severity(sorted),
        anomalies: sorted
      }
    end

    private

    def build_context
      pipeline =
        safe_snapshot("pipeline") do
          System::PipelineController.snapshot
        end

      {
        pipeline: pipeline,
        decisions: decisions(pipeline),
        # Les HealthSnapshot complets peuvent lancer des audits ou des
        # agrégations coûteuses. Le watchdog fréquent reste donc sur le
        # snapshot léger du PipelineController et sur les ControlSnapshot.
        layer1_health: {},
        cluster_health: {},
        actor_behavior_control:
          safe_snapshot("actor_behavior_control") do
            ActorBehaviors::ControlSnapshot.call
          end,
        actor_labels_control:
          safe_snapshot("actor_labels_control") do
            ActorLabels::ControlSnapshot.call
          end,
        sidekiq:
          safe_snapshot("sidekiq") do
            System::Anomalies::SidekiqSnapshot.call
          end
      }
    end

    def decisions(pipeline)
      return {} if pipeline[:error].present?

      System::PipelineController::PIPELINE_REGISTRY.keys.index_with do |role|
        System::PipelineController.decision(
          role,
          current_snapshot: pipeline
        )
      end
    rescue StandardError => error
      {
        error: "#{error.class}: #{error.message}"
      }
    end

    def safe_snapshot(name)
      yield
    rescue StandardError => error
      {
        unavailable: true,
        error: "#{error.class}: #{error.message}",
        source: name
      }
    end

    def safe_rule_call(rule, context)
      Array(rule.call(context: context))
    rescue StandardError => error
      Rails.logger.warn(
        "[system_anomaly_snapshot] rule_failed " \
        "rule=#{rule.name} #{error.class}: #{error.message}"
      )

      [
        anomaly(
          code: "anomaly_rule_failed",
          module_name: "system",
          severity: "warning",
          title: "Une règle d'anomalie a échoué",
          facts: {
            rule: rule.name,
            error: "#{error.class}: #{error.message}".byteslice(0, 180)
          },
          fingerprint: "system:anomaly_rule_failed:#{rule.name}"
        )
      ]
    end

    def normalize_anomaly(anomaly)
      payload =
        anomaly.respond_to?(:to_h) ? anomaly.to_h : anomaly.to_h

      severity =
        payload[:severity].to_s

      return nil unless SEVERITY_RANK.key?(severity)

      {
        code: payload[:code].to_s,
        module: payload[:module].to_s,
        severity: severity,
        title: payload[:title].to_s,
        facts: (payload[:facts] || {}).to_h,
        fingerprint: payload[:fingerprint].to_s,
        confirmation_observations:
          payload[:confirmation_observations].to_i.positive? ?
            payload[:confirmation_observations].to_i :
            1
      }
    end

    def overall_severity(anomalies)
      return nil if anomalies.empty?
      return "critical" if anomalies.any? { |a| a[:severity] == "critical" }

      "warning"
    end

    def anomaly(...)
      System::Anomalies::Base.anomaly(...)
    end
  end
end
