# frozen_string_literal: true

module ActorLabels
  class StrictPreviewV2
    SOURCE = "actor_labels_strict_preview_v2_1"

    STRICT_WHALE_SCORE = 85
    STRICT_WHALE_MIN_BALANCE_BTC = BigDecimal("1000")

    WHALE_CANDIDATE_SCORE = 65
    WHALE_CANDIDATE_MIN_BALANCE_BTC = BigDecimal("100")

    DISTINCT_ACTIVITY_MAX = 49
    STRICT_SIGNALS = %i[
      whale_like
    ].freeze

    CANDIDATE_SIGNALS = %i[
      whale_candidate
    ].freeze

    def self.call(limit: nil)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit&.to_i
    end

    def call
      counters = Hash.new(0)

      samples =
        (
          STRICT_SIGNALS +
          CANDIDATE_SIGNALS
        ).index_with { [] }

      profiles_scope.find_each(
        batch_size: 1_000
      ) do |profile|
        counters[:profiles_scanned] += 1

        signals =
          signals_for(profile)

        if signals.empty?
          counters[:without_signal] += 1
          next
        end

        signals.each do |signal|
          counters[signal] += 1

          add_sample(
            samples: samples,
            signal: signal,
            profile: profile
          )
        end
      end

      {
        ok: true,
        mode: "preview_only",
        source: SOURCE,
        writes_performed: 0,

        rules: {
          whale_like: {
            whale_score_min:
              STRICT_WHALE_SCORE,

            balance_btc_min:
              STRICT_WHALE_MIN_BALANCE_BTC.to_s("F"),

            exchange_score_max:
              DISTINCT_ACTIVITY_MAX,

            service_score_max:
              DISTINCT_ACTIVITY_MAX
          },

          whale_candidate: {
            whale_score_min:
              WHALE_CANDIDATE_SCORE,

            balance_btc_min:
              WHALE_CANDIDATE_MIN_BALANCE_BTC.to_s("F")
          },

          accumulator_like: {
            status:
              "deferred_until_historical_enrichment"
          },

          distributor_like: {
            status:
              "deferred_until_historical_enrichment"
          },

          etf_candidate: {
            status:
              "deferred_until_historical_enrichment"
          }
        },

        actor_profiles: {
          certified:
            profiles_scope.count,

          scanned:
            counters[:profiles_scanned],

          without_signal:
            counters[:without_signal]
        },

        strict_labels_proposed:
          STRICT_SIGNALS.to_h do |signal|
            [
              signal,
              counters[signal]
            ]
          end,

        candidates:
          CANDIDATE_SIGNALS.to_h do |signal|
            [
              signal,
              counters[signal]
            ]
          end,

        unsupported_labels: {
          exchange_like:
            "exchange_and_service_scores_are_not_distinguishable",

          service_like:
            "exchange_and_service_scores_are_not_distinguishable",

          retail_like:
            "insufficient_evidence",

          etf_like:
            "requires_external_identity_proof"
        },

        heights: {
          cluster_tip:
            cluster_tip,

          profile_height_min:
            profiles_scope.minimum(
              :last_computed_height
            ),

          profile_height_max:
            profiles_scope.maximum(
              :last_computed_height
            )
        },

        samples:
          samples
      }
    end

    private

    def profiles_scope
      scope =
        ActorProfiles::CertifiedScope
          .call
          .includes(:cluster)

      @limit.to_i.positive? ?
        scope.limit(@limit) :
        scope
    end

    def signals_for(profile)
      signals = []

      whale_score =
        profile.whale_score.to_i

      exchange_score =
        profile.exchange_score.to_i

      service_score =
        profile.service_score.to_i

      balance_btc =
        profile.balance_btc.to_d.abs

      if strict_whale?(
        whale_score: whale_score,
        balance_btc: balance_btc,
        exchange_score: exchange_score,
        service_score: service_score
      )
        signals << :whale_like
      elsif whale_candidate?(
        whale_score: whale_score,
        balance_btc: balance_btc,
        exchange_score: exchange_score,
        service_score: service_score
      )
        signals << :whale_candidate
      end

      signals
    end

    def strict_whale?(
      whale_score:,
      balance_btc:,
      exchange_score:,
      service_score:
    )
      whale_score >= STRICT_WHALE_SCORE &&
        balance_btc >=
          STRICT_WHALE_MIN_BALANCE_BTC &&
        exchange_score <=
          DISTINCT_ACTIVITY_MAX &&
        service_score <=
          DISTINCT_ACTIVITY_MAX
    end

    def whale_candidate?(
      whale_score:,
      balance_btc:,
      exchange_score:,
      service_score:
    )
      whale_score >= WHALE_CANDIDATE_SCORE &&
        balance_btc >=
          WHALE_CANDIDATE_MIN_BALANCE_BTC &&
        exchange_score <=
          DISTINCT_ACTIVITY_MAX &&
        service_score <=
          DISTINCT_ACTIVITY_MAX
    end

    def add_sample(
      samples:,
      signal:,
      profile:
    )
      return if samples.fetch(signal).size >= 10

      samples.fetch(signal) << {
        actor_profile_id:
          profile.id,

        cluster_id:
          profile.cluster_id,

        signal:
          signal,

        scores: {
          whale:
            profile.whale_score.to_i,

          exchange:
            profile.exchange_score.to_i,

          service:
            profile.service_score.to_i,

          etf:
            nil,

          accumulation:
            nil,

          distribution:
            nil
        },

        metrics: {
          address_count:
            profile.traits.to_h["address_count"].to_i,

          balance_btc:
            profile.balance_btc.to_s,

          total_received_btc:
            nil,

          total_sent_btc:
            profile.total_sent_btc.to_s,

          tx_count:
            profile.tx_count.to_i,

          spent_tx_count:
            profile.tx_count.to_i,

          inflow_count:
            nil,

          outflow_count:
            profile.outflow_count.to_i
        },

        last_computed_height:
          profile.last_computed_height,

        cluster_composition_version:
          profile.cluster_composition_version
      }
    end

    def cluster_tip
      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
        .to_i
    end
  end
end
