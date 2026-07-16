# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class CertifiedBlockActivityTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      @height = 2_000_000 + SecureRandom.random_number(100_000)
      @hash = txid("block-#{SecureRandom.hex(8)}")
      @cluster = Cluster.create!(composition_version: 3)
      @address = "ctp-activity-#{SecureRandom.hex(12)}"
      Address.create!(address: @address, cluster: @cluster)
      certify_layer1
      certify_cluster
    end

    def teardown
      ClusterInput.where(address: @address).delete_all
      UtxoOutput.where(address: @address).delete_all
      Address.where(address: @address).delete_all
      ClusterProcessedBlock.where(height: @height).delete_all
      BlockBufferModel.where(height: @height).delete_all
      Cluster.where(id: @cluster&.id).delete_all
    end

    test "extracts live and later-spent receipts plus spends deterministically" do
      live = txid("live")
      later_spent = txid("later-spent")
      same_block_received = txid("same-block-received")
      same_block_spent = txid("same-block-spent")
      other_spent = txid("other-spent")

      create_utxo(txid: live, vout: 0)
      create_cluster_input(
        txid: later_spent,
        vout: 0,
        block_height: @height,
        spent_txid: txid("later-spender"),
        spent_block_height: @height + 1
      )
      create_cluster_input(
        txid: same_block_received,
        vout: 0,
        block_height: @height,
        spent_txid: same_block_spent,
        spent_block_height: @height
      )
      create_cluster_input(
        txid: txid("older-output"),
        vout: 0,
        block_height: @height - 1,
        spent_txid: other_spent,
        spent_block_height: @height
      )

      result = extract

      assert result.ok
      assert_equal :certified, result.reason
      assert_equal normalize(live, later_spent, same_block_received), result.received_txids
      assert_equal normalize(other_spent, same_block_spent), result.spent_txids
      assert_equal({ height: @height, block_hash: @hash }, result.checkpoint)
      assert_equal 3, result.expected_composition_version
    end

    test "deduplicates receipts across live and spent sources" do
      duplicated = txid("duplicate")
      create_utxo(txid: duplicated, vout: 0)
      create_cluster_input(
        txid: duplicated,
        vout: 1,
        block_height: @height,
        spent_txid: txid("spender"),
        spent_block_height: @height
      )

      result = extract

      assert result.ok
      assert_equal normalize(duplicated), result.received_txids
    end

    test "fails closed when Layer1 certification is absent or false" do
      BlockBufferModel.where(height: @height).delete_all
      assert_refused(:layer1_not_certified)

      certify_layer1(metrics: { "outputs_audit_ok" => false,
        "inputs_audit_ok" => true, "utxo_audit_ok" => true })
      assert_refused(:layer1_not_certified)
    end

    test "fails closed when Cluster certification is absent or false" do
      ClusterProcessedBlock.where(height: @height).delete_all
      assert_refused(:cluster_not_certified)

      certify_cluster(audit_result: { "ok" => false })
      assert_refused(:cluster_not_certified)
    end

    test "rejects divergent hashes and orphaned blocks" do
      assert_refused(:block_hash_mismatch, block_hash: txid("wrong-hash"))

      BlockBufferModel.where(height: @height).update_all(is_orphan: true)
      assert_refused(:orphaned_block)
    end

    test "rejects a divergent composition" do
      assert_refused(:composition_mismatch, expected_composition_version: 2)
    end

    test "invalid txids never expose partial activity" do
      create_utxo(txid: txid("valid"), vout: 0)
      create_utxo(txid: "invalid", vout: 1)
      counts_before = source_counts

      assert_refused(:invalid_txid)
      assert_equal counts_before, source_counts
    end

    test "reads certified activity in a repeatable read transaction" do
      service = CertifiedBlockActivity.new(
        cluster_id: @cluster.id,
        expected_composition_version: 3,
        block_height: @height,
        block_hash: @hash
      )
      source_reader = service.method(:received_source_txids)
      observed_isolation = nil

      service.define_singleton_method(:received_source_txids) do
        observed_isolation = ApplicationRecord.connection.select_value(
          "SHOW transaction_isolation"
        )
        source_reader.call
      end

      assert service.call.ok
      assert_equal "repeatable read", observed_isolation
    end

    private

    def extract(**overrides)
      CertifiedBlockActivity.call(
        cluster_id: @cluster.id,
        expected_composition_version: 3,
        block_height: @height,
        block_hash: @hash,
        **overrides
      )
    end

    def assert_refused(reason, **overrides)
      result = extract(**overrides)
      assert_equal false, result.ok
      assert_equal reason, result.reason
      assert_nil result.received_txids
      assert_nil result.spent_txids
      assert_nil result.checkpoint
    end

    def certify_layer1(metrics: nil)
      BlockBufferModel.where(height: @height).delete_all
      BlockBufferModel.create!(
        height: @height,
        block_hash: @hash,
        status: "processed",
        is_orphan: false,
        processed_at: Time.current,
        strict_metrics: metrics || {
          "outputs_audit_ok" => true,
          "inputs_audit_ok" => true,
          "utxo_audit_ok" => true
        }
      )
    end

    def certify_cluster(audit_result: { "ok" => true })
      ClusterProcessedBlock.where(height: @height).delete_all
      ClusterProcessedBlock.create!(
        height: @height,
        block_hash: @hash,
        status: "processed",
        processed_at: Time.current,
        audit_result: audit_result
      )
    end

    def create_utxo(txid:, vout:)
      UtxoOutput.create!(
        txid: txid,
        vout: vout,
        address: @address,
        block_height: @height,
        block_hash: @hash,
        amount_btc: 1
      )
    end

    def create_cluster_input(
      txid:,
      vout:,
      block_height:,
      spent_txid:,
      spent_block_height:
    )
      ClusterInput.create!(
        txid: txid,
        vout: vout,
        address: @address,
        amount_btc: 1,
        block_height: block_height,
        spent: true,
        spent_txid: spent_txid,
        spent_block_height: spent_block_height
      )
    end

    def normalize(*values)
      values.map { |value| Txid.normalize(value) }.uniq.sort
    end

    def source_counts
      {
        blocks: BlockBufferModel.where(height: @height).count,
        checkpoints: ClusterProcessedBlock.where(height: @height).count,
        clusters: Cluster.where(id: @cluster.id).count,
        addresses: Address.where(address: @address).count,
        inputs: ClusterInput.where(address: @address).count,
        utxos: UtxoOutput.where(address: @address).count
      }
    end

    def txid(seed)
      Digest::SHA256.hexdigest(seed)
    end
  end
end
