# frozen_string_literal: true

require "set"

module ActorLabels
  class FinalResolutionSnapshot
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

    DISPLAY_LIMIT = 100

    def self.call(
      strict_rows: nil,
      heavy_exchange_cluster_ids: nil
    )
      new(
        strict_rows: strict_rows,
        heavy_exchange_cluster_ids:
          heavy_exchange_cluster_ids
      ).call
    end

    def initialize(
      strict_rows:,
      heavy_exchange_cluster_ids:
    )
      @provided_strict_rows =
        strict_rows

      @provided_heavy_exchange_cluster_ids =
        heavy_exchange_cluster_ids
    end

    def call
      exchange_signal_ids =
        ids_for(
          EXCHANGE_SIGNAL
        )

      service_signal_ids =
        ids_for(
          SERVICE_SIGNAL
        )

      preliminary_ids =
        exchange_signal_ids |
        service_signal_ids

      dual_signal_ids =
        exchange_signal_ids &
        service_signal_ids

      final_exchange_ids =
        heavy_exchange_ids

      # Aucun moteur Heavy Service n’existe encore.
      final_service_ids =
        Set.new

      resolved_ids =
        final_exchange_ids |
        final_service_ids

      unresolved_ids =
        preliminary_ids -
        resolved_ids

      {
        status: "active",

        preliminary: {
          actors:
            preliminary_ids.size,

          exchange_signals:
            exchange_signal_ids.size,

          service_signals:
            service_signal_ids.size,

          dual_signals:
            dual_signal_ids.size,

          exchange_only:
            (
              exchange_signal_ids -
              service_signal_ids
            ).size,

          service_only:
            (
              service_signal_ids -
              exchange_signal_ids
            ).size
        },

        final: {
          exchange_infrastructure:
            final_exchange_ids.size,

          service_infrastructure:
            final_service_ids.size,

          unresolved:
            unresolved_ids.size,

          identity_verified:
            0
        },

        exchange_clusters:
          final_exchange_ids
            .to_a
            .sort
            .first(
              DISPLAY_LIMIT
            ),

        service_clusters:
          final_service_ids
            .to_a
            .sort
            .first(
              DISPLAY_LIMIT
            ),

        unresolved_clusters:
          unresolved_ids
            .to_a
            .sort
            .first(
              DISPLAY_LIMIT
            ),

        anomalies: {
          heavy_without_preliminary_signal:
            (
              final_exchange_ids -
              preliminary_ids
            ).to_a.sort
        },

        contracts: {
          strict_source:
            STRICT_SOURCE,

          heavy_source:
            HEAVY_SOURCE,

          heavy_exchange_label:
            HEAVY_EXCHANGE_LABEL,

          service_heavy_available:
            false
        },

        generated_at:
          Time.current
      }
    rescue StandardError => error
      {
        status: "unavailable",

        preliminary: {
          actors: 0,
          exchange_signals: 0,
          service_signals: 0,
          dual_signals: 0
        },

        final: {
          exchange_infrastructure: 0,
          service_infrastructure: 0,
          unresolved: 0,
          identity_verified: 0
        },

        exchange_clusters: [],
        service_clusters: [],
        unresolved_clusters: [],

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
      :provided_heavy_exchange_cluster_ids
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

    def ids_for(label)
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

    def heavy_exchange_ids
      @heavy_exchange_ids ||=
        begin
          values =
            if provided_heavy_exchange_cluster_ids.nil?
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
              provided_heavy_exchange_cluster_ids
            end

          values
            .map(&:to_i)
            .to_set
        end
    end
  end
end
