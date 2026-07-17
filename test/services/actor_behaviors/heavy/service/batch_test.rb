# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class BatchTest <
        ActiveSupport::TestCase

        Snapshot =
          Struct.new(
            :id,
            :cluster_id,
            keyword_init: true
          )

        class FakeConnection
          attr_reader :queries

          def initialize(acquire:)
            @acquire =
              acquire

            @queries = []
          end

          def select_value(sql)
            queries <<
              sql

            return @acquire if
              sql.include?(
                "pg_try_advisory_lock"
              )

            return true if
              sql.include?(
                "pg_advisory_unlock"
              )

            nil
          end
        end

        test "processes a bounded service batch in shadow mode" do
          candidates = [
            Snapshot.new(
              id: 10,
              cluster_id: 100
            ),

            Snapshot.new(
              id: 11,
              cluster_id: 101
            )
          ]

          scope_arguments = nil
          build_arguments = []

          candidate_scope =
            lambda do |**arguments|
              scope_arguments =
                arguments

              candidates
            end

          builder =
            lambda do |**arguments|
              build_arguments <<
                arguments

              {
                ok: true,
                status: "certified",
                decision: "confirmed",
                snapshot_id:
                  arguments.fetch(
                    :source_cluster_id
                  ),

                created: true,
                updated: false,
                unchanged: false,

                # Le batch doit écraser toute tentative
                # de synchronisation par shadow_mode.
                label_sync: {
                  status: "synchronized"
                }
              }
            end

          connection =
            FakeConnection.new(
              acquire: true
            )

          result =
            Batch.call(
              limit:
                2,

              trigger:
                "test",

              distribution_window_blocks:
                500,

              distribution_chunk_size:
                50,

              minimum_height_delta:
                600,

              to_height:
                1_000,

              candidate_scope:
                candidate_scope,

              builder:
                builder,

              connection:
                connection
            )

          assert_equal(
            {
              limit: 2,
              to_height: 1_000,
              minimum_height_delta: 600
            },
            scope_arguments
          )

          assert_equal(
            [100, 101],
            build_arguments.map do |arguments|
              arguments[
                :source_cluster_id
              ]
            end
          )

          assert_equal(
            "completed",
            result[:status]
          )

          assert_equal(
            true,
            result[:ok]
          )

          assert_equal(
            "service_infrastructure",
            result[:analysis_kind]
          )

          assert_equal(
            true,
            result[:shadow_mode]
          )

          assert_equal(
            false,
            result[:labels_enabled]
          )

          assert_equal(
            2,
            result[:selected]
          )

          assert_equal(
            2,
            result[:certified]
          )

          assert_equal(
            2,
            result[:created]
          )

          assert_equal(
            0,
            result[:labels_synchronized]
          )

          assert_equal(
            0,
            result[:label_sync_failed]
          )

          assert_equal(
            2,
            result[:label_sync_skipped]
          )

          result[:results].each do |candidate|
            assert_equal(
              "skipped",
              candidate.dig(
                :label_sync,
                :status
              )
            )

            assert_equal(
              :shadow_mode,
              candidate.dig(
                :label_sync,
                :reason
              )
            )
          end

          assert(
            connection.queries.any? do |query|
              query.include?(
                "pg_try_advisory_lock(42023)"
              )
            end
          )

          assert(
            connection.queries.any? do |query|
              query.include?(
                "pg_advisory_unlock(42023)"
              )
            end
          )

          refute(
            connection.queries.any? do |query|
              query.include?(
                "42022"
              )
            end
          )
        end

        test "one candidate failure does not stop the next candidate" do
          candidates = [
            Snapshot.new(
              id: 20,
              cluster_id: 200
            ),

            Snapshot.new(
              id: 21,
              cluster_id: 201
            )
          ]

          processed = []

          candidate_scope =
            lambda do |**_arguments|
              candidates
            end

          builder =
            lambda do |source_cluster_id:, **_arguments|
              processed <<
                source_cluster_id

              if source_cluster_id == 200
                raise "candidate failure"
              end

              {
                ok: true,
                status: "certified",
                snapshot_id: 201,
                created: true,
                updated: false,
                unchanged: false
              }
            end

          result =
            Batch.call(
              limit:
                2,

              to_height:
                1_000,

              candidate_scope:
                candidate_scope,

              builder:
                builder,

              connection:
                FakeConnection.new(
                  acquire: true
                )
            )

          assert_equal(
            [200, 201],
            processed
          )

          assert_equal(
            "failed",
            result[:status]
          )

          assert_equal(
            false,
            result[:ok]
          )

          assert_equal(
            2,
            result[:selected]
          )

          assert_equal(
            1,
            result[:failed]
          )

          assert_equal(
            1,
            result[:certified]
          )

          assert_equal(
            :candidate_processing_failed,
            result[:results]
              .first[
                :reason
              ]
          )

          assert_equal(
            "certified",
            result[:results]
              .last[
                :status
              ]
          )
        end

        test "does not select candidates when the service lock is busy" do
          scope_called = false
          builder_called = false

          candidate_scope =
            lambda do |**_arguments|
              scope_called =
                true

              []
            end

          builder =
            lambda do |**_arguments|
              builder_called =
                true

              {}
            end

          result =
            Batch.call(
              to_height:
                1_000,

              candidate_scope:
                candidate_scope,

              builder:
                builder,

              connection:
                FakeConnection.new(
                  acquire: false
                )
            )

          assert_equal(
            "deferred",
            result[:status]
          )

          assert_equal(
            :heavy_service_batch_locked,
            result[:reason]
          )

          assert_equal(
            false,
            scope_called
          )

          assert_equal(
            false,
            builder_called
          )

          assert_equal(
            0,
            result[:selected]
          )

          assert_equal(
            false,
            result[:labels_enabled]
          )
        end

        test "clamps the requested batch limit" do
          received_limit = nil

          candidate_scope =
            lambda do |limit:, **_arguments|
              received_limit =
                limit

              []
            end

          result =
            Batch.call(
              limit:
                500,

              to_height:
                1_000,

              candidate_scope:
                candidate_scope,

              builder:
                lambda { |**| flunk },

              connection:
                FakeConnection.new(
                  acquire: true
                )
            )

          assert_equal(
            Batch::MAX_LIMIT,
            received_limit
          )

          assert_equal(
            Batch::MAX_LIMIT,
            result[:requested_limit]
          )

          assert_equal(
            "idle",
            result[:status]
          )
        end
      end
    end
  end
end
