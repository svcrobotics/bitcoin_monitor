# frozen_string_literal: true

require "test_helper"

module AddressUtxoStats
  class SequentialRunnerTest < ActiveSupport::TestCase
    BASE_HEIGHT =
      1_800_000

    FakeClusterCheckpoint =
      Struct.new(
        :height,
        :block_hash,
        :status,
        keyword_init: true
      )

    test "projects one block with the default limit" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT)
          ]
        )

      projector =
        FakeProjectBlock.new

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert result[:ok]
      assert_equal :completed, result[:status]
      assert_equal :limit_reached, result[:stopped_reason]
      assert_equal 1, result[:requested_limit]
      assert_equal 1, result[:processed_count]
      assert_equal 1, result[:completed_count]
      assert_equal [BASE_HEIGHT], result[:attempted_heights]
      assert_equal [BASE_HEIGHT], projector.heights
    end

    test "projects several blocks in order" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT),
            checkpoint(BASE_HEIGHT + 1),
            checkpoint(BASE_HEIGHT + 2)
          ]
        )

      projector =
        FakeProjectBlock.new

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT,
          limit: 3,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert result[:ok]
      assert_equal :limit_reached, result[:stopped_reason]
      assert_equal 3, result[:processed_count]
      assert_equal 3, result[:completed_count]
      assert_equal(
        [
          BASE_HEIGHT,
          BASE_HEIGHT + 1,
          BASE_HEIGHT + 2
        ],
        result[:attempted_heights]
      )
    end

    test "starts after the last completed AddressUtxo checkpoint" do
      completed_height =
        BASE_HEIGHT + 10

      AddressUtxoProjectionBlock.create!(
        height: completed_height,
        block_hash: "completed-hash",
        status: "completed",
        completed_at: Time.current
      )

      source =
        FakeClusterSource.new(
          [
            checkpoint(completed_height + 1)
          ]
        )

      projector =
        FakeProjectBlock.new

      result =
        SequentialRunner.call(
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert result[:ok]
      assert_equal [completed_height + 1], projector.heights
      assert_equal completed_height + 2, result[:next_expected_height]
    end

    test "respects explicit from height" do
      AddressUtxoProjectionBlock.create!(
        height: BASE_HEIGHT + 20,
        block_hash: "completed-hash-explicit",
        status: "completed",
        completed_at: Time.current
      )

      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 5)
          ]
        )

      projector =
        FakeProjectBlock.new

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 5,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert result[:ok]
      assert_equal [BASE_HEIGHT + 5], projector.heights
    end

    test "accepts already completed blocks and continues" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 30),
            checkpoint(BASE_HEIGHT + 31)
          ]
        )

      projector =
        FakeProjectBlock.new(
          BASE_HEIGHT + 30 => "already_completed",
          BASE_HEIGHT + 31 => "completed"
        )

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 30,
          limit: 2,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert result[:ok]
      assert_equal 2, result[:processed_count]
      assert_equal 1, result[:already_completed_count]
      assert_equal 1, result[:completed_count]
      assert_equal(
        [
          BASE_HEIGHT + 30,
          BASE_HEIGHT + 31
        ],
        projector.heights
      )
    end

    test "stops on blocked ProjectBlock result" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 40),
            checkpoint(BASE_HEIGHT + 41)
          ]
        )

      projector =
        FakeProjectBlock.new(
          BASE_HEIGHT + 40 => "blocked",
          BASE_HEIGHT + 41 => "completed"
        )

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 40,
          limit: 2,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert_not result[:ok]
      assert_equal :blocked, result[:status]
      assert_equal :project_block_blocked, result[:stopped_reason]
      assert_equal [BASE_HEIGHT + 40], projector.heights
    end

    test "stops on failed ProjectBlock result" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 50),
            checkpoint(BASE_HEIGHT + 51)
          ]
        )

      projector =
        FakeProjectBlock.new(
          BASE_HEIGHT + 50 => "failed",
          BASE_HEIGHT + 51 => "completed"
        )

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 50,
          limit: 2,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert_not result[:ok]
      assert_equal :failed, result[:status]
      assert_equal :project_block_failed, result[:stopped_reason]
      assert_equal [BASE_HEIGHT + 50], projector.heights
    end

    test "does not project the next height after a failure" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 60),
            checkpoint(BASE_HEIGHT + 61)
          ]
        )

      projector =
        FakeProjectBlock.new(
          BASE_HEIGHT + 60 => "failed"
        )

      SequentialRunner.call(
        from_height: BASE_HEIGHT + 60,
        limit: 2,
        cluster_checkpoint_source: source,
        project_block: projector
      )

      assert_equal [BASE_HEIGHT + 60], projector.heights
    end

    test "detects a Cluster height gap" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 70),
            checkpoint(BASE_HEIGHT + 71),
            checkpoint(BASE_HEIGHT + 73)
          ]
        )

      projector =
        FakeProjectBlock.new

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 70,
          limit: 5,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert_not result[:ok]
      assert_equal :blocked, result[:status]
      assert_equal :cluster_height_gap, result[:stopped_reason]
      assert_equal BASE_HEIGHT + 72, result[:error][:expected_height]
      assert_equal BASE_HEIGHT + 73, result[:error][:actual_height]
      assert_equal(
        [
          BASE_HEIGHT + 70,
          BASE_HEIGHT + 71
        ],
        projector.heights
      )
    end

    test "rejects a Cluster checkpoint without hash" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(
              BASE_HEIGHT + 80,
              block_hash: nil
            )
          ]
        )

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 80,
          cluster_checkpoint_source: source,
          project_block: FakeProjectBlock.new
        )

      assert_not result[:ok]
      assert_equal :cluster_checkpoint_hash_missing,
                   result[:stopped_reason]
    end

    test "rejects a Cluster checkpoint not marked processed" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(
              BASE_HEIGHT + 90,
              status: "processing"
            )
          ]
        )

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 90,
          cluster_checkpoint_source: source,
          project_block: FakeProjectBlock.new
        )

      assert_not result[:ok]
      assert_equal :cluster_checkpoint_not_processed,
                   result[:stopped_reason]
    end

    test "returns source unavailable when the default Cluster model is absent" do
      source =
        SequentialRunner::DefaultClusterCheckpointSource.new(
          model_name: "DefinitelyMissingClusterProcessedBlock"
        )

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 100,
          cluster_checkpoint_source: source,
          project_block: FakeProjectBlock.new
        )

      assert_not result[:ok]
      assert_equal :blocked, result[:status]
      assert_equal :cluster_checkpoint_source_unavailable,
                   result[:stopped_reason]
      assert_equal 0, result[:processed_count]
    end

    test "stops when no Cluster checkpoint is available" do
      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 110,
          cluster_checkpoint_source: FakeClusterSource.new([]),
          project_block: FakeProjectBlock.new
        )

      assert result[:ok]
      assert_equal :completed, result[:status]
      assert_equal :no_cluster_checkpoint, result[:stopped_reason]
      assert_equal 0, result[:processed_count]
    end

    test "respects the requested limit" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 120),
            checkpoint(BASE_HEIGHT + 121),
            checkpoint(BASE_HEIGHT + 122)
          ]
        )

      projector =
        FakeProjectBlock.new

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 120,
          limit: 2,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert_equal :limit_reached, result[:stopped_reason]
      assert_equal 2, result[:processed_count]
      assert_equal(
        [
          BASE_HEIGHT + 120,
          BASE_HEIGHT + 121
        ],
        projector.heights
      )
    end

    test "respects runtime budget before starting the next block" do
      clock_values =
        [
          0.0,
          0.0,
          2.0,
          2.0
        ]

      clock =
        lambda do
          clock_values.shift || 2.0
        end

      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 130),
            checkpoint(BASE_HEIGHT + 131)
          ]
        )

      projector =
        FakeProjectBlock.new

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 130,
          limit: 2,
          max_runtime_seconds: 1,
          cluster_checkpoint_source: source,
          project_block: projector,
          clock: clock
        )

      assert result[:ok]
      assert_equal :runtime_budget_reached, result[:stopped_reason]
      assert_equal 1, result[:processed_count]
      assert_equal [BASE_HEIGHT + 130], projector.heights
    end

    test "returns deterministic results" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 140),
            checkpoint(BASE_HEIGHT + 141)
          ]
        )

      first =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 140,
          limit: 2,
          cluster_checkpoint_source: source,
          project_block: FakeProjectBlock.new,
          clock: -> { 0.0 }
        )

      second =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 140,
          limit: 2,
          cluster_checkpoint_source: source,
          project_block: FakeProjectBlock.new,
          clock: -> { 0.0 }
        )

      assert_equal(
        deterministic_fields(first),
        deterministic_fields(second)
      )
    end

    test "does not read utxo outputs or cluster inputs" do
      source =
        Rails.root.join(
          "app/services/address_utxo_stats/sequential_runner.rb"
        ).read

      assert_not_includes source, "utxo_outputs"
      assert_not_includes source, "cluster_inputs"
    end

    test "does not write projection tables directly" do
      source =
        Rails.root.join(
          "app/services/address_utxo_stats/sequential_runner.rb"
        ).read

      refute_match(
        /AddressUtxoProjectionBlock\.(create|update|delete|destroy|insert|upsert)/,
        source
      )
      refute_match(
        /\bAddressUtxoStat\b/,
        source
      )
    end

    test "converts unexpected ProjectBlock exceptions to failed results" do
      source =
        FakeClusterSource.new(
          [
            checkpoint(BASE_HEIGHT + 150)
          ]
        )

      projector =
        lambda do |height:, block_hash:|
          raise "boom #{height} #{block_hash}"
        end

      result =
        SequentialRunner.call(
          from_height: BASE_HEIGHT + 150,
          cluster_checkpoint_source: source,
          project_block: projector
        )

      assert_not result[:ok]
      assert_equal :failed, result[:status]
      assert_equal :project_block_failed, result[:stopped_reason]
      assert_equal "RuntimeError", result[:error][:class]
      assert_match "boom", result[:error][:message]
    end

    private

    class FakeClusterSource
      def initialize(checkpoints, available: true)
        @checkpoints =
          checkpoints
        @available =
          available
      end

      def available?
        @available
      end

      def processed_from(from_height:, limit:)
        return nil unless available?

        checkpoints
          .select do |checkpoint|
            from_height.nil? ||
              checkpoint.height.to_i >= from_height.to_i
          end
          .sort_by do |checkpoint|
            checkpoint.height.to_i
          end
          .first(limit)
      end

      private

      attr_reader :checkpoints
    end

    class FakeProjectBlock
      attr_reader :heights

      def initialize(status_by_height = {})
        @status_by_height =
          status_by_height
        @heights =
          []
      end

      def call(height:, block_hash:)
        heights << height

        status =
          status_by_height.fetch(
            height,
            "completed"
          )

        {
          ok: %w[
            completed
            already_completed
          ].include?(status),
          status: status,
          height: height,
          block_hash: block_hash
        }
      end

      private

      attr_reader :status_by_height
    end

    def checkpoint(
      height,
      block_hash: "block-hash-#{height}",
      status: "processed"
    )
      FakeClusterCheckpoint.new(
        height: height,
        block_hash: block_hash,
        status: status
      )
    end

    def deterministic_fields(result)
      result.slice(
        :ok,
        :status,
        :from_height,
        :next_expected_height,
        :requested_limit,
        :processed_count,
        :completed_count,
        :already_completed_count,
        :attempted_heights,
        :stopped_reason
      )
    end
  end
end
