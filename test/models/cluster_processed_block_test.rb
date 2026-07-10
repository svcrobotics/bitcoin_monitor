# frozen_string_literal: true

require "test_helper"

class ClusterProcessedBlockTest < ActiveSupport::TestCase
  test "valid checkpoint" do
    checkpoint =
      ClusterProcessedBlock.new(
        valid_attributes
      )

    assert checkpoint.valid?
  end

  test "height is required" do
    checkpoint =
      ClusterProcessedBlock.new(
        valid_attributes(
          height: nil
        )
      )

    assert_not checkpoint.valid?
    assert checkpoint.errors.added?(
      :height,
      :blank
    )
  end

  test "height is unique" do
    ClusterProcessedBlock.create!(
      valid_attributes(
        height: 880_002
      )
    )

    duplicate =
      ClusterProcessedBlock.new(
        valid_attributes(
          height: 880_002
        )
      )

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(
      :height,
      :taken
    )
  end

  test "block hash is required" do
    checkpoint =
      ClusterProcessedBlock.new(
        valid_attributes(
          block_hash: nil
        )
      )

    assert_not checkpoint.valid?
    assert checkpoint.errors.added?(
      :block_hash,
      :blank
    )
  end

  test "status is required" do
    checkpoint =
      ClusterProcessedBlock.new(
        valid_attributes(
          status: nil
        )
      )

    assert_not checkpoint.valid?
    assert checkpoint.errors.added?(
      :status,
      :blank
    )
  end

  test "json defaults are empty hashes" do
    checkpoint =
      ClusterProcessedBlock.create!(
        valid_attributes(
          height: 880_006,
          scan_result: nil,
          cleanup_result: nil,
          audit_result: nil,
          stage_timings: nil
        ).compact
      )

    checkpoint.reload

    assert_equal({}, checkpoint.scan_result)
    assert_equal({}, checkpoint.cleanup_result)
    assert_equal({}, checkpoint.audit_result)
    assert_equal({}, checkpoint.stage_timings)
  end

  test "status defaults to processed" do
    checkpoint =
      ClusterProcessedBlock.create!(
        valid_attributes(
          height: 880_007,
          status: nil
        ).compact
      )

    assert_equal "processed", checkpoint.status
  end

  test "performance fields are available" do
    column_names =
      ClusterProcessedBlock
        .columns
        .map(&:name)

    assert_includes column_names, "processing_started_at"
    assert_includes column_names, "duration_ms"
    assert_includes column_names, "stage_timings"

    assert_equal(
      :datetime,
      column_type(:processing_started_at)
    )
    assert_equal(
      :integer,
      column_type(:duration_ms)
    )
    assert_equal(
      :jsonb,
      column_type(:stage_timings)
    )
  end

  test "unique height index is present" do
    index =
      ActiveRecord::Base
        .connection
        .indexes(:cluster_processed_blocks)
        .find do |candidate|
          candidate.columns == ["height"] &&
            candidate.unique
        end

    assert index
  end

  private

  def valid_attributes(overrides = {})
    {
      height: 880_001,
      block_hash: "block-hash-880001",
      status: "processed",
      processed_at: Time.current
    }.merge(overrides)
  end

  def column_type(column_name)
    ClusterProcessedBlock
      .columns_hash
      .fetch(column_name.to_s)
      .type
  end
end
