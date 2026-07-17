# frozen_string_literal: true

require "bigdecimal"

module ActorBehaviors
  module Heavy
    class DepositEvidence
      VERSION =
        "deposit_evidence_v1"

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

        traits =
          actor_profile
            .traits
            .to_h

        {
          ok: true,
          status: "certified",

          evidence: {
            analysis_version:
              VERSION,

            cluster_id:
              actor_profile.cluster_id.to_i,

            actor_profile_id:
              actor_profile.id.to_i,

            profile_version:
              traits[
                "profile_version"
              ],

            profile_height:
              actor_profile
                .last_computed_height
                .to_i,

            cluster_composition_version:
              actor_profile
                .cluster_composition_version
                .to_i,

            address_count:
              traits[
                "address_count"
              ].to_i,

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

            balance_btc:
              decimal_string(
                actor_profile.balance_btc
              ),

            total_received_btc:
              decimal_string(
                actor_profile
                  .total_received_btc
              ),

            total_sent_btc:
              decimal_string(
                actor_profile
                  .total_sent_btc
              ),

            net_btc:
              decimal_string(
                actor_profile.net_btc
              )
          }
        }
      end

      private

      attr_reader :actor_profile

      def decimal_string(value)
        BigDecimal(
          value.to_s.presence || "0"
        ).to_s("F")
      rescue ArgumentError
        "0"
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
