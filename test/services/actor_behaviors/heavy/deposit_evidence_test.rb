# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    class DepositEvidenceTest <
      ActiveSupport::TestCase

      test "builds deterministic evidence from profile" do
        profile =
          Struct.new(
            :id,
            :cluster_id,
            :traits,
            :last_computed_height,
            :cluster_composition_version,
            :tx_count,
            :inflow_count,
            :outflow_count,
            :balance_btc,
            :total_received_btc,
            :total_sent_btc,
            :net_btc,
            keyword_init: true
          ).new(
            id: 12,
            cluster_id: 34,

            traits: {
              "address_count" => 1_484,
              "profile_version" =>
                "strict_v4_core_facts"
            },

            last_computed_height: 956_887,
            cluster_composition_version: 12,
            tx_count: 1_505,
            inflow_count: 1_505,
            outflow_count: 15,
            balance_btc: "0.00131007",
            total_received_btc: "0.61803407",
            total_sent_btc: "0.616724",
            net_btc: "0.00131007"
          )

        result =
          DepositEvidence.call(
            actor_profile:
              profile
          )

        assert_equal(
          "certified",
          result[:status]
        )

        assert_equal(
          1_484,
          result.dig(
            :evidence,
            :address_count
          )
        )

        assert_equal(
          "0.61803407",
          result.dig(
            :evidence,
            :total_received_btc
          )
        )
      end
    end
  end
end
