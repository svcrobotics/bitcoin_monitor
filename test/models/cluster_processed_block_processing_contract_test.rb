# frozen_string_literal: true

require "test_helper"

class ClusterProcessedBlockProcessingContractTest < ActiveSupport::TestCase
  test "processed_at is nullable" do
    column =
      ClusterProcessedBlock.columns_hash.fetch("processed_at")

    assert column.null
  end

  test "processing checkpoint may omit processed_at" do
    checkpoint =
      ClusterProcessedBlock.create!(
        height: 990_001,
        block_hash: "processing-block-hash",
        status: "processing",
        processed_at: nil
      )

    assert_nil checkpoint.reload.processed_at
    assert_equal "processing", checkpoint.status
  end

  test "processed checkpoint preserves its timestamp" do
    processed_at = Time.current.change(usec: 0)
    checkpoint =
      ClusterProcessedBlock.create!(
        height: 990_002,
        block_hash: "processed-block-hash",
        status: "processed",
        processed_at: processed_at
      )

    assert_equal processed_at, checkpoint.reload.processed_at
  end

  test "existing model validations remain enforced" do
    checkpoint =
      ClusterProcessedBlock.new(
        height: nil,
        block_hash: nil,
        status: nil,
        processed_at: nil
      )

    assert_not checkpoint.valid?
    assert checkpoint.errors.added?(:height, :blank)
    assert checkpoint.errors.added?(:block_hash, :blank)
    assert checkpoint.errors.added?(:status, :blank)
    assert_not checkpoint.errors.key?(:processed_at)
  end

  test "migration is limited to the Cluster checkpoint table" do
    source = File.read(
      Rails.root.join(
        "db/migrate/20260712095352_allow_null_processed_at_on_cluster_processed_blocks.rb"
      )
    )

    assert_equal 2, source.scan("change_column_null").size
    assert_equal 2, source.scan(":cluster_processed_blocks").size
    assert_no_match(/block_buffers|cluster_inputs|utxo_outputs|tx_outputs/, source)
    assert_no_match(/Redis|Sidekiq/, source)
  end
end
