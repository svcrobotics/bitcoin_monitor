# frozen_string_literal: true

module ClusterTransactionProjection
  # Extracts activity for the currently certified Cluster composition.
  #
  # Address membership is deliberately read from the current certified
  # composition. This service does not reconstruct historical address
  # membership; a composition change must be handled by a later generation.
  class CertifiedBlockActivity
    AUDIT_FLAGS = %w[
      outputs_audit_ok
      inputs_audit_ok
      utxo_audit_ok
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(
      cluster_id:,
      expected_composition_version:,
      block_height:,
      block_hash:
    )
      @cluster_id = Integer(cluster_id)
      @expected_composition_version = Integer(expected_composition_version)
      @block_height = Integer(block_height)
      @block_hash = block_hash.to_s
    end

    def call
      ApplicationRecord.transaction(
        isolation: :repeatable_read,
        requires_new: true
      ) do
        validation = validate_certification
        return validation unless validation.ok

        received = normalize_txids(received_source_txids)
        spent = normalize_txids(spent_source_txids)

        Result.new(
          ok: true,
          reason: :certified,
          received_txids: received,
          spent_txids: spent,
          checkpoint: {
            height: block_height,
            block_hash: block_hash
          },
          expected_composition_version: expected_composition_version
        )
      rescue ArgumentError
        refused(:invalid_txid)
      end
    end

    private

    attr_reader(
      :cluster_id,
      :expected_composition_version,
      :block_height,
      :block_hash
    )

    def validate_certification
      layer1 = BlockBufferModel.where(height: block_height).to_a
      exact_layer1 = layer1.select { |block| block.block_hash == block_hash }

      return refused(:layer1_not_certified) if layer1.empty?
      return refused(:block_hash_mismatch) if exact_layer1.empty?
      return refused(:layer1_not_certified) unless exact_layer1.one?

      block = exact_layer1.first
      return refused(:orphaned_block) if block.is_orphan
      return refused(:layer1_not_certified) unless layer1_certified?(block)

      checkpoint = ClusterProcessedBlock.find_by(height: block_height)
      return refused(:cluster_not_certified) unless checkpoint
      return refused(:block_hash_mismatch) unless checkpoint.block_hash == block_hash
      return refused(:cluster_not_certified) unless cluster_certified?(checkpoint)

      cluster = Cluster.find_by(id: cluster_id)
      return refused(:composition_mismatch) unless cluster
      return refused(:composition_mismatch) unless
        cluster.composition_version == expected_composition_version

      Result.new(ok: true, reason: :certification_verified)
    end

    def layer1_certified?(block)
      metrics = block.strict_metrics.to_h

      block.status == "processed" &&
        block.processed_at.present? &&
        AUDIT_FLAGS.all? { |flag| metrics[flag] == true }
    end

    def cluster_certified?(checkpoint)
      checkpoint.status == "processed" &&
        checkpoint.processed_at.present? &&
        checkpoint.audit_result.to_h["ok"] == true
    end

    def cluster_addresses
      Address.where(cluster_id: cluster_id).select(:address)
    end

    def received_source_txids
      ClusterInput
        .where(block_height: block_height, address: cluster_addresses)
        .pluck(:txid) |
        UtxoOutput
          .where(
            block_height: block_height,
            block_hash: block_hash,
            address: cluster_addresses
          )
          .pluck(:txid)
    end

    def spent_source_txids
      ClusterInput
        .where(
          spent_block_height: block_height,
          address: cluster_addresses
        )
        .where.not(spent_txid: [nil, ""])
        .pluck(:spent_txid)
    end

    def normalize_txids(values)
      values.map { |value| Txid.normalize(value) }.uniq.sort
    end

    def refused(reason)
      Result.new(
        ok: false,
        reason: reason,
        received_txids: nil,
        spent_txids: nil,
        checkpoint: nil,
        expected_composition_version: expected_composition_version
      )
    end

    Result = Struct.new(
      :ok,
      :reason,
      :received_txids,
      :spent_txids,
      :checkpoint,
      :expected_composition_version,
      keyword_init: true
    )
  end
end
