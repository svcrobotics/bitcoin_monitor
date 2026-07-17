# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class BuildFromEvidenceFingerprintTest <
        ActiveSupport::TestCase

        test "ignores stage durations in business fingerprint" do
          first =
            evidence_with(
              duration: 0.5,
              transactions: 108
            )

          second =
            evidence_with(
              duration: 127.3,
              transactions: 108
            )

          assert_equal(
            fingerprint(first),
            fingerprint(second)
          )

          assert_equal(
            {
              "source_spends" => 0.5
            },
            first.dig(
              :direct_distribution,
              :metrics,
              :stage_durations_seconds
            )
          )
        end

        test "still detects a real evidence change" do
          first =
            evidence_with(
              duration: 0.5,
              transactions: 108
            )

          second =
            evidence_with(
              duration: 0.5,
              transactions: 109
            )

          refute_equal(
            fingerprint(first),
            fingerprint(second)
          )
        end

        private

        def fingerprint(value)
          BuildFromEvidence
            .allocate
            .send(
              :evidence_fingerprint,
              value
            )
        end

        def evidence_with(
          duration:,
          transactions:
        )
          {
            analysis_kind:
              "service_infrastructure",

            direct_distribution: {
              metrics: {
                spending_transactions:
                  transactions,

                stage_durations_seconds: {
                  "source_spends" =>
                    duration
                }
              }
            }
          }
        end
      end
    end
  end
end
