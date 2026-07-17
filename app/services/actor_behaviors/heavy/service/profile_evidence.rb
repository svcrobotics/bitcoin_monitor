# frozen_string_literal: true

require "bigdecimal"

module ActorBehaviors
  module Heavy
    module Service
      class ProfileEvidence
        VERSION =
          "service_profile_evidence_v1"

        def self.call(actor_profile:)
          new(
            actor_profile:
              actor_profile
          ).call
        end

        def initialize(actor_profile:)
          @actor_profile =
            actor_profile
        end

        def call
          unless actor_profile
            return deferred(
              :actor_profile_missing
            )
          end

          first_seen_height =
            integer_trait(
              :first_seen_height
            )

          last_seen_height =
            integer_trait(
              :last_seen_height
            )

          activity_span_blocks =
            resolved_activity_span(
              first_seen_height:
                first_seen_height,

              last_seen_height:
                last_seen_height
            )

          received_tx_count =
            integer_trait(
              :received_tx_count
            )

          spending_tx_count =
            integer_trait(
              :spending_tx_count
            )

          total_received =
            decimal(
              actor_profile
                .total_received_btc
            )

          total_sent =
            decimal(
              actor_profile
                .total_sent_btc
            )

          balance =
            decimal(
              actor_profile
                .balance_btc
            )

          {
            ok: true,
            status: "certified",

            evidence: {
              analysis_version:
                VERSION,

              cluster_id:
                actor_profile
                  .cluster_id
                  .to_i,

              actor_profile_id:
                actor_profile
                  .id
                  .to_i,

              profile_version:
                trait(
                  :profile_version
                ),

              profile_height:
                actor_profile
                  .last_computed_height
                  .to_i,

              cluster_composition_version:
                actor_profile
                  .cluster_composition_version
                  .to_i,

              address_count:
                integer_trait(
                  :address_count
                ),

              tx_count:
                actor_profile
                  .tx_count
                  .to_i,

              inflow_count:
                actor_profile
                  .inflow_count
                  .to_i,

              outflow_count:
                actor_profile
                  .outflow_count
                  .to_i,

              received_tx_count:
                received_tx_count,

              spending_tx_count:
                spending_tx_count,

              spent_tx_count:
                integer_trait(
                  :spent_tx_count
                ),

              spent_inputs_count:
                integer_trait(
                  :spent_inputs_count
                ),

              received_outputs_count:
                integer_trait(
                  :received_outputs_count
                ),

              live_utxo_count:
                integer_trait(
                  :live_utxo_count
                ),

              first_seen_height:
                first_seen_height,

              last_seen_height:
                last_seen_height,

              activity_span_blocks:
                activity_span_blocks,

              tx_density:
                decimal_string(
                  trait(
                    :tx_density
                  )
                ),

              balance_btc:
                decimal_string(
                  balance
                ),

              total_received_btc:
                decimal_string(
                  total_received
                ),

              total_sent_btc:
                decimal_string(
                  total_sent
                ),

              net_btc:
                decimal_string(
                  actor_profile.net_btc
                ),

              sent_received_ratio:
                ratio_string(
                  numerator:
                    total_sent,

                  denominator:
                    total_received
                ),

              balance_received_ratio:
                ratio_string(
                  numerator:
                    balance.abs,

                  denominator:
                    total_received.abs
                ),

              bidirectional_activity_observed:
                received_tx_count.positive? &&
                spending_tx_count.positive?
            }
          }
        end

        private

        attr_reader :actor_profile

        def traits
          @traits ||=
            actor_profile
              .traits
              .to_h
        end

        def trait(name)
          traits[name.to_s] ||
            traits[name.to_sym]
        end

        def integer_trait(name)
          trait(name).to_i
        end

        def resolved_activity_span(
          first_seen_height:,
          last_seen_height:
        )
          stored =
            integer_trait(
              :activity_span_blocks
            )

          return stored if stored.positive?

          return 0 if first_seen_height <= 0
          return 0 if last_seen_height <= 0
          return 0 if last_seen_height <
                      first_seen_height

          last_seen_height -
            first_seen_height +
            1
        end

        def decimal(value)
          BigDecimal(
            value.to_s.presence || "0"
          )
        rescue ArgumentError, TypeError
          BigDecimal("0")
        end

        def decimal_string(value)
          decimal(value).to_s("F")
        end

        def ratio_string(
          numerator:,
          denominator:
        )
          return nil unless denominator.positive?

          (
            numerator /
            denominator
          ).to_s("F")
        end

        def deferred(reason)
          {
            ok: true,
            status: "deferred",
            reason: reason,
            evidence: {}
          }
        end
      end
    end
  end
end
