# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ActorBehaviors
  module Heavy
    class BatchLabelSyncTest <
      ActiveSupport::TestCase

      Snapshot =
        Struct.new(
          :id,
          :cluster_id,
          keyword_init: true
        )

      setup do
        @previous_labels_enabled =
          ENV[
            "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED"
          ]

        @snapshot =
          Snapshot.new(
            id: 17,
            cluster_id: 21_885
          )
      end

      teardown do
        if @previous_labels_enabled.nil?
          ENV.delete(
            "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED"
          )
        else
          ENV[
            "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED"
          ] =
            @previous_labels_enabled
        end
      end

      test "does not write a label when heavy build is deferred" do
        ENV[
          "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED"
        ] =
          "true"

        result = nil

        Build.stub(
          :call,
          {
            ok: true,
            status: "deferred",
            reason: :no_sweep_activity
          }
        ) do
          ActorLabels::HeavyWriter.stub(
            :call,
            lambda do |**|
              flunk(
                "HeavyWriter must not run " \
                "for a deferred build"
              )
            end
          ) do
            result =
              batch.send(
                :process_candidate,

                snapshot:
                  @snapshot,

                to_height:
                  956_900
              )
          end
        end

        assert_equal(
          "deferred",
          result[:status]
        )

        assert_equal(
          "skipped",
          result.dig(
            :label_sync,
            :status
          )
        )

        assert_equal(
          :heavy_not_certified,
          result.dig(
            :label_sync,
            :reason
          )
        )
      end

      test "writes a label after a certified heavy build" do
        ENV[
          "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED"
        ] =
          "true"

        heavy_snapshot =
          Object.new

        result = nil

        Build.stub(
          :call,
          {
            ok: true,
            status: "certified",
            snapshot_id: 3,
            created: false,
            updated: false,
            unchanged: true
          }
        ) do
          ActorBehaviorHeavySnapshot.stub(
            :find_by,
            heavy_snapshot
          ) do
            ActorLabels::HeavyWriter.stub(
              :call,
              {
                ok: true,

                written_labels: [
                  {
                    id: 68,

                    label:
                      "exchange_infrastructure_candidate",

                    created:
                      false
                  }
                ],

                deleted_labels: []
              }
            ) do
              result =
                batch.send(
                  :process_candidate,

                  snapshot:
                    @snapshot,

                  to_height:
                    956_900
                )
            end
          end
        end

        assert_equal(
          true,
          result[:ok]
        )

        assert_equal(
          "certified",
          result[:status]
        )

        assert_equal(
          "synchronized",
          result.dig(
            :label_sync,
            :status
          )
        )
      end

      test "keeps labels disabled unless explicitly enabled" do
        ENV.delete(
          "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED"
        )

        result = nil

        Build.stub(
          :call,
          {
            ok: true,
            status: "certified",
            snapshot_id: 3
          }
        ) do
          ActorLabels::HeavyWriter.stub(
            :call,
            lambda do |**|
              flunk(
                "HeavyWriter must not run " \
                "when labels are disabled"
              )
            end
          ) do
            result =
              batch.send(
                :process_candidate,

                snapshot:
                  @snapshot,

                to_height:
                  956_900
              )
          end
        end

        assert_equal(
          "skipped",
          result.dig(
            :label_sync,
            :status
          )
        )

        assert_equal(
          :labels_disabled,
          result.dig(
            :label_sync,
            :reason
          )
        )
      end

      private

      def batch
        @batch ||=
          Batch.new(
            limit: 1,
            trigger: "test",

            sweep_window_blocks:
              3_000,

            distribution_window_blocks:
              500,

            minimum_height_delta:
              500,

            to_height:
              956_900
          )
      end
    end
  end
end
