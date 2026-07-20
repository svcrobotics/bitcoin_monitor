# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ActorLabels
  class FullAuditTest < ActiveSupport::TestCase
    def setup
      clear_redis
    end

    def teardown
      clear_redis
    end

    test "completes read only without changing incremental cursor" do
      Sidekiq.redis do |redis|
        redis.set(
          ActorLabels::StrictBatchJob::CURSOR_KEY,
          777
        )
      end

      calls = []

      ActorLabels::StrictBatch.stub(
        :call,
        ->(**arguments) {
          calls << arguments

          batch_result(
            next_cursor: 10,
            has_more: false,
            scanned: 10,
            expected_upserts: 2,
            expected_deletions: 1,
            global_deletions: 1
          )
        }
      ) do
        result =
          ActorLabels::FullAudit.call(
            limit: 500
          )

        assert_equal true, result[:ok]

        assert_equal(
          "completed",
          result.dig(:audit, :status)
        )

        assert_equal(
          4,
          result.dig(:audit, :drift_total)
        )
      end

      assert_equal(
        [
          {
            limit: 500,
            after_id: 0,
            dry_run: true
          }
        ],
        calls
      )

      Sidekiq.redis do |redis|
        assert_equal(
          "777",
          redis.get(
            ActorLabels::StrictBatchJob::
              CURSOR_KEY
          )
        )

        assert_nil(
          redis.get(
            ActorLabels::FullAudit::CURSOR_KEY
          )
        )

        assert_nil(
          redis.get(
            ActorLabels::FullAudit::STATE_KEY
          )
        )

        assert redis.get(
          ActorLabels::FullAudit::LAST_RUN_KEY
        ).present?
      end
    end

    test "persists and resumes its own cursor" do
      results = [
        batch_result(
          next_cursor: 10,
          has_more: true,
          scanned: 5,
          expected_upserts: 2
        ),

        batch_result(
          next_cursor: 20,
          has_more: false,
          scanned: 3,
          expected_upserts: 1
        )
      ]

      calls = []

      ActorLabels::StrictBatch.stub(
        :call,
        ->(**arguments) {
          calls << arguments
          results.shift
        }
      ) do
        first =
          ActorLabels::FullAudit.call(
            limit: 5
          )

        assert_equal(
          "running",
          first.dig(:audit, :status)
        )

        Sidekiq.redis do |redis|
          assert_equal(
            "10",
            redis.get(
              ActorLabels::FullAudit::CURSOR_KEY
            )
          )

          assert redis.get(
            ActorLabels::FullAudit::STATE_KEY
          ).present?
        end

        second =
          ActorLabels::FullAudit.call(
            limit: 5
          )

        assert_equal(
          "completed",
          second.dig(:audit, :status)
        )

        assert_equal(
          2,
          second.dig(:audit, :batches)
        )

        assert_equal(
          8,
          second.dig(:audit, :scanned)
        )

        assert_equal(
          3,
          second.dig(:audit, :expected_upserts)
        )
      end

      assert_equal(
        [0, 10],
        calls.map { |call| call[:after_id] }
      )
    end

    test "waits while incremental processing owns the lock" do
      Sidekiq.redis do |redis|
        redis.set(
          ActorLabels::StrictBatchJob::LOCK_KEY,
          "incremental-owner",
          ex: 60
        )
      end

      called = false

      ActorLabels::StrictBatch.stub(
        :call,
        ->(**) {
          called = true
          raise "StrictBatch must not run"
        }
      ) do
        result =
          ActorLabels::FullAudit.call

        assert_equal true, result[:skipped]
        assert_equal "locked", result[:reason]
      end

      assert_equal false, called

      Sidekiq.redis do |redis|
        assert_equal(
          "incremental-owner",
          redis.get(
            ActorLabels::StrictBatchJob::LOCK_KEY
          )
        )
      end
    end

    test "blocks inconsistent progress without state" do
      Sidekiq.redis do |redis|
        redis.set(
          ActorLabels::FullAudit::CURSOR_KEY,
          123
        )
      end

      called = false

      ActorLabels::StrictBatch.stub(
        :call,
        ->(**) {
          called = true
          raise "StrictBatch must not run"
        }
      ) do
        result =
          ActorLabels::FullAudit.call

        assert_equal false, result[:ok]

        assert_equal(
          "audit_state_missing",
          result[:reason]
        )

        assert_equal(
          123,
          result.dig(:audit, :cursor)
        )
      end

      assert_equal false, called
    end

    private

    def batch_result(
      next_cursor:,
      has_more:,
      scanned:,
      expected_upserts: 0,
      expected_deletions: 0,
      global_deletions: 0
    )
      {
        ok: true,
        dry_run: true,

        cursor: {
          next_after_id: next_cursor,
          has_more: has_more
        },

        batch: {
          scanned: scanned,
          eligible: scanned,
          ineligible: 0,
          failed: 0,
          expected_labels: 0,
          expected_upserts:
            expected_upserts,
          expected_deletions:
            expected_deletions,
          expected_by_label: {}
        },

        reconciliation: {
          expected_deletions:
            global_deletions
        },

        database: {
          strict_actor_labels: 11
        },

        runtime_ms: 25
      }
    end

    def clear_redis
      Sidekiq.redis do |redis|
        redis.del(
          ActorLabels::FullAudit::CURSOR_KEY,
          ActorLabels::FullAudit::STATE_KEY,
          ActorLabels::FullAudit::LAST_RUN_KEY,
          ActorLabels::StrictBatchJob::LOCK_KEY,
          ActorLabels::StrictBatchJob::CURSOR_KEY
        )
      end
    end
  end
end
