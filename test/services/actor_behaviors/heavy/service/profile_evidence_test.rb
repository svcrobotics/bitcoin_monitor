# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class ProfileEvidenceTest <
        ActiveSupport::TestCase

        test "builds deterministic service evidence from profile" do
          profile =
            build_profile

          result =
            ProfileEvidence.call(
              actor_profile:
                profile
            )

          assert_equal(
            true,
            result[:ok]
          )

          assert_equal(
            "certified",
            result[:status]
          )

          evidence =
            result.fetch(
              :evidence
            )

          assert_equal(
            "service_profile_evidence_v1",
            evidence[:analysis_version]
          )

          assert_equal(
            34,
            evidence[:cluster_id]
          )

          assert_equal(
            1_484,
            evidence[:address_count]
          )

          assert_equal(
            12_500,
            evidence[:tx_count]
          )

          assert_equal(
            10_001,
            evidence[:activity_span_blocks]
          )

          assert_equal(
            "1.249875",
            evidence[:tx_density]
          )

          assert_equal(
            "0.98",
            evidence[:sent_received_ratio]
          )

          assert_equal(
            "0.02",
            evidence[:balance_received_ratio]
          )

          assert_equal(
            true,
            evidence[
              :bidirectional_activity_observed
            ]
          )
        end

        test "derives activity span when the stored value is missing" do
          profile =
            build_profile

          profile.traits.delete(
            "activity_span_blocks"
          )

          result =
            ProfileEvidence.call(
              actor_profile:
                profile
            )

          assert_equal(
            10_001,
            result.dig(
              :evidence,
              :activity_span_blocks
            )
          )
        end

        test "defers when the profile is missing" do
          result =
            ProfileEvidence.call(
              actor_profile:
                nil
            )

          assert_equal(
            true,
            result[:ok]
          )

          assert_equal(
            "deferred",
            result[:status]
          )

          assert_equal(
            :actor_profile_missing,
            result[:reason]
          )

          assert_empty(
            result[:evidence]
          )
        end

        private

        def build_profile
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
              "profile_version" =>
                "strict_v4_core_facts",

              "address_count" =>
                1_484,

              "received_tx_count" =>
                7_500,

              "spending_tx_count" =>
                5_000,

              "spent_tx_count" =>
                5_000,

              "spent_inputs_count" =>
                8_000,

              "received_outputs_count" =>
                9_000,

              "live_utxo_count" =>
                300,

              "first_seen_height" =>
                900_000,

              "last_seen_height" =>
                910_000,

              "activity_span_blocks" =>
                10_001,

              "tx_density" =>
                "1.249875"
            },

            last_computed_height:
              956_887,

            cluster_composition_version:
              12,

            tx_count:
              12_500,

            inflow_count:
              7_500,

            outflow_count:
              5_000,

            balance_btc:
              "20",

            total_received_btc:
              "1000",

            total_sent_btc:
              "980",

            net_btc:
              "20"
          )
        end
      end
    end
  end
end
