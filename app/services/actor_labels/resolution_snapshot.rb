# frozen_string_literal: true

require "set"

module ActorLabels
  class ResolutionSnapshot
    STRICT_SOURCE =
      ActorLabels::StrictRuleSet::SOURCE

    HEAVY_SOURCE =
      ActorLabels::HeavyRuleSet::SOURCE

    EXCHANGE_SIGNAL =
      "exchange_like"

    SERVICE_SIGNAL =
      "service_like"

    HEAVY_EXCHANGE_LABEL =
      "exchange_infrastructure_candidate"

    DISPLAY_LIMIT =
      20

    def self.call(
      strict_rows: nil,
      heavy_cluster_ids: nil
    )
      new(
        strict_rows:
          strict_rows,

        heavy_cluster_ids:
          heavy_cluster_ids
      ).call
    end

    def initialize(
      strict_rows:,
      heavy_cluster_ids:
    )
      @provided_strict_rows =
        strict_rows

      @provided_heavy_cluster_ids =
        heavy_cluster_ids
    end

    def call
      exchange_ids =
        cluster_ids_for(
          EXCHANGE_SIGNAL
        )

      service_ids =
        cluster_ids_for(
          SERVICE_SIGNAL
        )

      heavy_ids =
        resolved_heavy_cluster_ids

      dual_ids =
        exchange_ids &
        service_ids

      strict_signal_ids =
        exchange_ids |
        service_ids

      confirmed_exchange_ids =
        heavy_ids

      ambiguous_dual_ids =
        dual_ids -
        heavy_ids

      unresolved_ids =
        strict_signal_ids -
        heavy_ids

      {
        status:
          "active",

        semantics: {
          strict:
            "preliminary_signals",

          heavy:
            "behavioral_resolution",

          identity:
            "not_verified"
        },

        strict_signals: {
          exchange:
            exchange_ids.size,

          service:
            service_ids.size,

          dual:
            dual_ids.size,

          exchange_only:
            (
              exchange_ids -
              service_ids
            ).size,

          service_only:
            (
              service_ids -
              exchange_ids
            ).size
        },

        resolution: {
          exchange_infrastructure_confirmed:
            confirmed_exchange_ids.size,

          ambiguous_exchange_service:
            ambiguous_dual_ids.size,

          unresolved_total:
            unresolved_ids.size,

          identity_verified:
            0
        },

        confirmed_exchange_clusters:
          confirmed_exchange_ids
            .to_a
            .sort
            .first(
              DISPLAY_LIMIT
            ),

        ambiguous_clusters:
          ambiguous_dual_ids
            .to_a
            .sort
            .first(
              DISPLAY_LIMIT
            ),

        anomalies: {
          heavy_without_strict_signal:
            (
              heavy_ids -
              strict_signal_ids
            ).to_a.sort
        },

        generated_at:
          Time.current
      }
    rescue StandardError => error
      {
        status:
          "unavailable",

        strict_signals: {
          exchange: 0,
          service: 0,
          dual: 0
        },

        resolution: {
          exchange_infrastructure_confirmed:
            0,

          ambiguous_exchange_service:
            0,

          unresolved_total:
            0,

          identity_verified:
            0
        },

        confirmed_exchange_clusters:
          [],

        ambiguous_clusters:
          [],

        error_class:
          error.class.name,

        error_message:
          error.message,

        generated_at:
          Time.current
      }
    end

    private

    attr_reader(
      :provided_strict_rows,
      :provided_heavy_cluster_ids
    )

    def strict_rows
      @strict_rows ||=
        if provided_strict_rows.nil?
          ActorLabel
            .where(
              source:
                STRICT_SOURCE,

              label: [
                EXCHANGE_SIGNAL,
                SERVICE_SIGNAL
              ]
            )
            .pluck(
              :cluster_id,
              :label
            )
        else
          provided_strict_rows
        end
    end

    def cluster_ids_for(label)
      strict_rows.each_with_object(
        Set.new
      ) do |row, result|
        cluster_id,
          row_label =
            row

        next unless
          row_label.to_s ==
          label

        result <<
          cluster_id.to_i
      end
    end

    def resolved_heavy_cluster_ids
      values =
        if provided_heavy_cluster_ids.nil?
          ActorLabel
            .where(
              source:
                HEAVY_SOURCE,

              label:
                HEAVY_EXCHANGE_LABEL
            )
            .pluck(
              :cluster_id
            )
        else
          provided_heavy_cluster_ids
        end

      values
        .map(&:to_i)
        .to_set
    end
  end
end
