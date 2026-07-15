# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Layer1
  class PaceSnapshotTest < ActiveSupport::TestCase
    setup do
      BlockBufferModel.delete_all
      @base_time = Time.zone.parse("2026-07-03 10:00:00")
    end

    test "calculates network median and average from consecutive block times" do
      create_processed_block(1, block_time: @base_time)
      create_processed_block(2, block_time: @base_time + 600.seconds)
      create_processed_block(3, block_time: @base_time + 720.seconds)
      create_processed_block(4, block_time: @base_time + 1_620.seconds)

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 600.0, snapshot.dig(:network, :median_interval_seconds)
      assert_equal 540.0, snapshot.dig(:network, :average_interval_seconds)
    end

    test "excludes non consecutive heights from network intervals" do
      create_processed_block(1, block_time: @base_time)
      create_processed_block(3, block_time: @base_time + 600.seconds)
      create_processed_block(4, block_time: @base_time + 900.seconds)

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 1, snapshot.dig(:sample, :network_intervals)
      assert_equal 300.0, snapshot.dig(:network, :median_interval_seconds)
    end

    test "excludes orphan blocks from network intervals" do
      create_processed_block(1, block_time: @base_time)
      create_processed_block(
        2,
        block_time: @base_time + 60.seconds,
        is_orphan: true
      )
      create_processed_block(3, block_time: @base_time + 660.seconds)

      snapshot = Layer1::PaceSnapshot.call

      assert_nil snapshot.dig(:network, :median_interval_seconds)
      assert_equal 0, snapshot.dig(:sample, :network_intervals)
    end

    test "calculates layer1 processing averages and medians" do
      create_processed_block(1, duration_ms: 100_000)
      create_processed_block(2, duration_ms: 200_000)
      create_processed_block(3, duration_ms: 300_000)

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 200.0, snapshot.dig(:processing, :median_10_seconds)
      assert_equal 200.0, snapshot.dig(:processing, :average_10_seconds)
      assert_equal 100.0, snapshot.dig(:processing, :minimum_30_seconds)
      assert_equal 300.0, snapshot.dig(:processing, :maximum_30_seconds)
      assert_equal 3, snapshot.dig(:processing, :slowest_height)
    end

    test "calculates effective certification cadence from processed timestamps" do
      create_processed_block(
        1,
        processed_at: @base_time + 300.seconds
      )
      create_processed_block(
        2,
        processed_at: @base_time + 900.seconds
      )
      create_processed_block(
        3,
        processed_at: @base_time + 1_200.seconds
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal(
        450.0,
        snapshot.dig(
          :certification,
          :median_10_seconds
        )
      )
      assert_equal(
        300.0,
        snapshot.dig(
          :certification,
          :last_interval_seconds
        )
      )
    end

    test "comparison uses effective certification cadence instead of internal duration" do
      create_processed_block(
        1,
        block_time: @base_time,
        duration_ms: 300_000,
        processed_at: @base_time + 300.seconds
      )
      create_processed_block(
        2,
        block_time: @base_time + 600.seconds,
        duration_ms: 300_000,
        processed_at: @base_time + 1_200.seconds
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal(
        900.0,
        snapshot.dig(
          :comparison,
          :effective_interval_seconds
        )
      )
      assert_equal(
        300.0,
        snapshot.dig(
          :comparison,
          :internal_processing_seconds
        )
      )
      assert_equal(
        600.0,
        snapshot.dig(
          :comparison,
          :scheduler_overhead_seconds
        )
      )
      assert_equal(
        "falling_behind",
        snapshot.dig(
          :comparison,
          :trend
        )
      )
    end

    test "does not substitute internal duration when certification cadence is unavailable" do
      block = create_processed_block(
        1,
        duration_ms: 120_000
      )
      block.update_column(:processed_at, nil)

      snapshot = Layer1::PaceSnapshot.call(current_lag: 4)

      assert_equal 120.0, snapshot.dig(:processing, :median_10_seconds)
      assert_nil snapshot.dig(:certification, :last_interval_seconds)
      assert_nil snapshot.dig(:comparison, :effective_interval_seconds)
      assert_nil snapshot.dig(:comparison, :layer1_blocks_per_hour)
      assert_nil snapshot.dig(:comparison, :pace_ratio)
      assert_nil snapshot.dig(:comparison, :backlog_change_per_hour)
      assert_nil snapshot.dig(:comparison, :estimated_catchup_hours)
      assert_equal "insufficient_data", snapshot.dig(:comparison, :trend)
    end

    test "keeps network ingestion certification and internal duration distinct" do
      create_processed_block(
        1,
        block_time: @base_time,
        created_at: @base_time + 100.seconds,
        processed_at: @base_time + 200.seconds,
        duration_ms: 100_000
      )
      create_processed_block(
        2,
        block_time: @base_time + 600.seconds,
        created_at: @base_time + 400.seconds,
        processed_at: @base_time + 1_100.seconds,
        duration_ms: 140_000
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 600.0, snapshot.dig(:network, :median_interval_seconds)
      assert_equal 300.0, snapshot.dig(:ingestion, :median_interval_seconds)
      assert_equal 900.0, snapshot.dig(:certification, :median_10_seconds)
      assert_equal 120.0, snapshot.dig(:processing, :median_10_seconds)
      assert_equal 900.0, snapshot.dig(:comparison, :effective_interval_seconds)
      assert_equal 4.0, snapshot.dig(:comparison, :layer1_blocks_per_hour)
    end

    test "calculates deterministic certification median and average" do
      [0, 300, 900, 1_800].each_with_index do |offset, index|
        create_processed_block(
          index + 1,
          processed_at: @base_time + offset.seconds,
          duration_ms: 10_000
        )
      end

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 600.0, snapshot.dig(:certification, :median_10_seconds)
      assert_equal 600.0, snapshot.dig(:certification, :average_10_seconds)
      assert_equal 900.0, snapshot.dig(:certification, :last_interval_seconds)
      assert_equal 6.0, snapshot.dig(:comparison, :layer1_blocks_per_hour)
    end

    test "calculates blocks per hour" do
      create_processed_block(
        1,
        block_time: @base_time,
        duration_ms: 300_000,
        processed_at: @base_time + 300.seconds
      )
      create_processed_block(
        2,
        block_time: @base_time + 600.seconds,
        duration_ms: 300_000,
        processed_at: @base_time + 900.seconds
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 6.0, snapshot.dig(:network, :blocks_per_hour)
      assert_equal 6.0, snapshot.dig(:comparison, :layer1_blocks_per_hour)
    end

    test "detects falling behind trend" do
      create_processed_block(
        1,
        block_time: @base_time,
        duration_ms: 600_000,
        processed_at: @base_time + 600.seconds
      )
      create_processed_block(
        2,
        block_time: @base_time + 300.seconds,
        duration_ms: 600_000,
        processed_at: @base_time + 1_200.seconds
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal "falling_behind", snapshot.dig(:comparison, :trend)
      assert_equal 6.0, snapshot.dig(:comparison, :backlog_change_per_hour)
      assert_nil snapshot.dig(:comparison, :estimated_catchup_hours)
    end

    test "detects catching up trend and estimates catchup time" do
      create_processed_block(
        1,
        block_time: @base_time,
        duration_ms: 300_000,
        processed_at: @base_time + 300.seconds
      )
      create_processed_block(
        2,
        block_time: @base_time + 600.seconds,
        duration_ms: 300_000,
        processed_at: @base_time + 600.seconds
      )
      create_pending_block(5)

      snapshot = Layer1::PaceSnapshot.call

      assert_equal "catching_up", snapshot.dig(:comparison, :trend)
      assert_equal(-6.0, snapshot.dig(:comparison, :backlog_change_per_hour))
      assert_equal 0.5, snapshot.dig(:comparison, :estimated_catchup_hours)
    end

    test "detects stable trend" do
      create_processed_block(
        1,
        block_time: @base_time,
        duration_ms: 600_000,
        processed_at: @base_time + 600.seconds
      )
      create_processed_block(
        2,
        block_time: @base_time + 600.seconds,
        duration_ms: 610_000,
        processed_at: @base_time + 1_210.seconds
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal "stable", snapshot.dig(:comparison, :trend)
    end

    test "detects flush as dominant component" do
      create_processed_block(
        1,
        duration_ms: 600_000,
        rpc_duration_ms: 10_000,
        parse_duration_ms: 5_000,
        db_duration_ms: 20_000,
        flush_duration_ms: 500_000
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal "flush", snapshot.dig(:components, :dominant_stage)
      assert_equal 500.0, snapshot.dig(:components, :flush_average_seconds)
      assert_equal 83.3, snapshot.dig(:components, :flush_percent)
      assert_equal 83.3, snapshot.dig(:components, :flush_total_percent)
      assert_equal 93.5, snapshot.dig(:components, :flush_instrumented_percent)
      assert_equal 65.0, snapshot.dig(:components, :unattributed_average_seconds)
      assert_equal 600.0, snapshot.dig(:components, :average_duration_seconds)
    end

    test "reconciles known components with average duration" do
      create_processed_block(
        1,
        duration_ms: 600_000,
        rpc_duration_ms: 10_000,
        parse_duration_ms: 5_000,
        db_duration_ms: nil,
        flush_duration_ms: 500_000
      )

      snapshot = Layer1::PaceSnapshot.call

      components = snapshot[:components]
      known_sum =
        [
          components[:rpc_average_seconds],
          components[:parse_average_seconds],
          components[:db_average_seconds],
          components[:flush_average_seconds]
        ].compact.sum

      assert_nil components[:db_average_seconds]
      assert_equal 85.0, components[:unattributed_average_seconds]
      assert_equal(
        components[:average_duration_seconds].round,
        (known_sum + components[:unattributed_average_seconds]).round
      )
      assert_equal 83.3, components[:flush_total_percent]
      assert_equal 97.1, components[:flush_instrumented_percent]
    end

    test "does not expose negative unattributed component time" do
      create_processed_block(
        1,
        duration_ms: 100_000,
        rpc_duration_ms: 60_000,
        parse_duration_ms: 30_000,
        flush_duration_ms: 40_000
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 0, snapshot.dig(:components, :unattributed_average_seconds)
    end

    test "keeps missing component values unavailable" do
      create_processed_block(1, duration_ms: 600_000)

      snapshot = Layer1::PaceSnapshot.call

      assert_nil snapshot.dig(:components, :rpc_average_seconds)
      assert_nil snapshot.dig(:components, :dominant_stage)
      assert_nil snapshot.dig(:components, :flush_percent)
    end

    test "returns insufficient data without processed samples" do
      snapshot = Layer1::PaceSnapshot.call

      assert_equal "insufficient_data", snapshot.dig(:comparison, :trend)
      assert_nil snapshot.dig(:network, :median_interval_seconds)
      assert_nil snapshot.dig(:processing, :median_30_seconds)
    end

    test "limits the main window query and detailed history" do
      100.times do |index|
        height = index + 1
        create_processed_block(
          height,
          block_time: @base_time + (height * 600).seconds,
          created_at: @base_time + (height * 300).seconds,
          processed_at: @base_time + (height * 450).seconds,
          duration_ms: (height * 1_000)
        )
      end

      snapshot = Layer1::PaceSnapshot.call(current_lag: 0)

      assert_equal 90, Layer1::PaceSnapshot::QUERY_LIMIT
      assert_equal 30, Layer1::PaceSnapshot::WINDOW_SIZE
      assert_equal 10, Layer1::PaceSnapshot::RECENT_HISTORY_SIZE
      assert_equal 30, snapshot.dig(:sample, :processing_blocks)
      assert_equal 29, snapshot.dig(:sample, :network_intervals)
      assert_equal 29, snapshot.dig(:sample, :certification_intervals)
      assert_equal 10, snapshot[:recent_blocks].size
      assert_equal((91..100).to_a.reverse, snapshot[:recent_blocks].pluck(:height))
    end

    test "keeps partial internal metrics unavailable instead of zero" do
      create_processed_block(
        1,
        duration_ms: 100_000,
        rpc_duration_ms: nil,
        parse_duration_ms: 20_000,
        db_duration_ms: nil,
        flush_duration_ms: nil
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_nil snapshot.dig(:components, :rpc_average_seconds)
      assert_equal 20.0, snapshot.dig(:components, :parse_average_seconds)
      assert_nil snapshot.dig(:components, :db_average_seconds)
      assert_nil snapshot.dig(:components, :flush_average_seconds)
      assert_equal 80.0, snapshot.dig(:components, :unattributed_average_seconds)
    end

    test "returns a JSON serializable snapshot" do
      create_processed_block(1)
      create_processed_block(2)

      parsed = JSON.parse(JSON.generate(Layer1::PaceSnapshot.call))

      assert_equal 2, parsed.dig("processing", "last_height")
      assert parsed.key?("network")
      assert parsed.key?("certification")
      assert parsed.key?("processing")
    end

    test "includes current processing elapsed time" do
      create_processing_block(
        10,
        processing_started_at: Time.current - 90.seconds
      )

      snapshot = Layer1::PaceSnapshot.call

      assert_equal 10, snapshot.dig(:processing, :current_height)
      assert_operator(
        snapshot.dig(:processing, :current_elapsed_seconds),
        :>=,
        89
      )
    end

    test "does not mutate database state" do
      create_processed_block(1, duration_ms: 100_000)
      before = BlockBufferModel.pluck(:id, :updated_at)
      sql = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        statement = payload[:sql].to_s
        sql << statement unless payload[:name].to_s == "SCHEMA"
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        assert_no_difference -> { BlockBufferModel.count } do
          Layer1::PaceSnapshot.call
        end
      end

      assert_equal before, BlockBufferModel.pluck(:id, :updated_at)
      assert sql.any? { |statement| statement.match?(/SELECT.*block_buffers/im) }
      refute sql.any? { |statement| statement.match?(/\A\s*(?:INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE)\b/i) }
    end

    test "has no runtime dependency on Redis Sidekiq Bitcoin Core or interface" do
      source = Rails.root.join("app/services/layer1/pace_snapshot.rb").read

      refute_match(/\bRedis\b|\bSidekiq\b|BitcoinRpc/, source)
      refute_match(/OverviewSnapshot|PacePresenter|Controller|render|perform_/, source)
      refute_match(/duration_ms|internal_processing/, certification_formula(source))
    end

    private

    def certification_formula(source)
      source[
        /effective_layer1\s*=.*?(?=\n\s*network_bph\s*=)/m
      ].to_s
    end

    def create_processed_block(
      height,
      block_time: @base_time + height.minutes,
      created_at: @base_time + height.minutes,
      processed_at: nil,
      duration_ms: 100_000,
      is_orphan: false,
      **component_durations
    )
      create_block(
        height,
        status: "processed",
        block_time: block_time,
        created_at: created_at,
        processed_at:
          processed_at ||
            created_at +
              (duration_ms.to_f / 1000.0).seconds,
        duration_ms: duration_ms,
        is_orphan: is_orphan,
        **component_durations
      )
    end

    def create_processing_block(height, processing_started_at:)
      create_block(
        height,
        status: "processing",
        block_time: @base_time + height.minutes,
        created_at: processing_started_at,
        processing_started_at: processing_started_at,
        duration_ms: nil
      )
    end

    def create_pending_block(height)
      create_block(
        height,
        status: "pending",
        block_time: @base_time + height.minutes,
        duration_ms: nil
      )
    end

    def create_block(height, **attributes)
      created_at =
        attributes.delete(:created_at) || @base_time + height.minutes

      BlockBufferModel.create!(
        {
          height: height,
          block_hash: "hash-#{height}-#{SecureRandom.hex(4)}",
          previous_hash: height > 0 ? "hash-#{height - 1}" : nil,
          tx_count: 1,
          size_bytes: 1,
          status: "processed",
          block_time: @base_time + height.minutes,
          created_at: created_at,
          updated_at: created_at
        }.merge(attributes)
      )
    end
  end
end
