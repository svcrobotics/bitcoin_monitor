# frozen_string_literal: true

module ClusterTransactionProjection
  class ApplyBlock
    def self.call(...)
      new(...).call
    end

    def initialize(
      cluster_id:,
      expected_composition_version:,
      block_height:,
      block_hash:,
      received_txids: [],
      spent_txids: []
    )
      @cluster_id = cluster_id.to_i
      @expected_composition_version = Integer(expected_composition_version)
      @block_height = block_height.to_i
      @block_hash = block_hash.to_s
      @received_txids =
        Array(received_txids).map { |txid| Txid.normalize(txid) }.uniq
      @spent_txids =
        Array(spent_txids).map { |txid| Txid.normalize(txid) }.uniq
    end

    def call
      ApplicationRecord.transaction do
        generation_result = locked_generation
        return generation_result unless generation_result.ok

        generation = generation_result.generation

        cluster_result =
          validate_cluster_revision(generation)

        return cluster_result unless cluster_result.ok

        block_result =
          lock_and_validate_projection_block(generation)

        return block_result unless block_result.ok

        return idempotent_result(generation) if
          block_result.reason == :already_projected

        changes =
          compute_counter_changes(generation)

        upsert_facts!

        after_upsert_hook

        generation.update!(
          checkpoint_height: block_height,
          checkpoint_hash: block_hash,
          inflow_count:
            generation.inflow_count.to_i +
              changes.fetch(:inflow_delta),
          outflow_count:
            generation.outflow_count.to_i +
              changes.fetch(:outflow_delta),
          tx_count:
            generation.tx_count.to_i +
              changes.fetch(:tx_delta),
          facts_count:
            generation.facts_count.to_i +
              changes.fetch(:facts_delta)
        )

        block_result.block.update!(
          status: "projected",
          block_hash: block_hash,
          completed_at: Time.current,
          last_error: nil
        )

        Result.new(
          ok: true,
          reason: :projected,
          generation: generation,
          block: block_result.block,
          changes: changes
        )
      end
    end

    private

    attr_reader(
      :cluster_id,
      :expected_composition_version,
      :block_height,
      :block_hash,
      :received_txids,
      :spent_txids
    )

    def locked_generation
      generations =
        ClusterTransactionProjectionGeneration
          .lock
          .where(
            cluster_id: cluster_id,
            status: "certified"
          )
          .to_a

      return refused(:missing_generation) if generations.empty?
      return refused(:ambiguous_certified_generation) if
        generations.size > 1

      @certified_generation_id =
        generations.first.id

      Result.new(
        ok: true,
        reason: :generation_locked,
        generation: generations.first
      )
    end

    def validate_cluster_revision(generation)
      cluster =
        Cluster.lock.find(generation.cluster_id)

      if cluster.composition_version.to_i < 1 ||
         expected_composition_version < 1 ||
         generation.composition_version.to_i < 1
        return refused(
          :invalid_composition_revision,
          generation: generation
        )
      end

      unless cluster.composition_version.to_i ==
             expected_composition_version
        return refused(
          :expected_composition_mismatch,
          generation: generation
        )
      end

      unless cluster.composition_version.to_i ==
             generation.composition_version.to_i
        return refused(
          :composition_mismatch,
          generation: generation
        )
      end

      Result.new(
        ok: true,
        reason: :composition_verified,
        generation: generation
      )
    end

    def lock_and_validate_projection_block(generation)
      if block_height <= generation.checkpoint_height.to_i
        return validate_already_projected(generation)
      end

      unless block_height == generation.checkpoint_height.to_i + 1
        return refused(
          :projection_gap,
          generation: generation
        )
      end

      previous =
        ClusterTransactionProjectionBlock
          .lock
          .find_by(block_height: generation.checkpoint_height)

      unless previous&.status == "projected"
        return refused(
          :projection_gap,
          generation: generation
        )
      end

      unless previous.block_hash.to_s == generation.checkpoint_hash.to_s
        return refused(
          :hash_mismatch,
          generation: generation,
          block: previous
        )
      end

      source_checkpoint =
        ClusterProcessedBlock.find_by(
          height: block_height
        )

      unless source_checkpoint&.status.to_s == "processed"
        return refused(
          :checkpoint_missing,
          generation: generation
        )
      end

      unless source_checkpoint.block_hash.to_s == block_hash
        return refused(
          :hash_mismatch,
          generation: generation
        )
      end

      block =
        ClusterTransactionProjectionBlock
          .lock
          .find_or_initialize_by(block_height: block_height)

      if block.persisted? &&
         block.status == "projected" &&
         block.block_hash.to_s != block_hash
        return refused(
          :hash_mismatch,
          generation: generation,
          block: block
        )
      end

      if block.status == "stale"
        return refused(
          :stale,
          generation: generation,
          block: block
        )
      end

      block.status = "processing"
      block.block_hash = block_hash
      block.started_at ||= Time.current
      block.last_error = nil
      block.save!

      Result.new(
        ok: true,
        reason: :processing,
        generation: generation,
        block: block
      )
    end

    def validate_already_projected(generation)
      block =
        ClusterTransactionProjectionBlock
          .lock
          .find_by(block_height: block_height)

      unless block&.status == "projected"
        return refused(
          :projection_gap,
          generation: generation,
          block: block
        )
      end

      unless block.block_hash.to_s == block_hash
        return refused(
          :hash_mismatch,
          generation: generation,
          block: block
        )
      end

      Result.new(
        ok: true,
        reason: :already_projected,
        generation: generation,
        block: block
      )
    end

    def compute_counter_changes(generation)
      existing =
        existing_facts(generation)

      activity =
        activity_by_txid

      previous_checkpoint =
        generation.checkpoint_height.to_i

      changes = {
        inflow_delta: 0,
        outflow_delta: 0,
        tx_delta: 0,
        facts_delta: 0
      }

      activity.each do |txid, flags|
        old_received, old_spent =
          existing[txid]

        old_activity =
          counted_at?(old_received, previous_checkpoint) ||
          counted_at?(old_spent, previous_checkpoint)

        new_received =
          min_height(
            old_received,
            flags[:received] ? block_height : nil
          )

        new_spent =
          min_height(
            old_spent,
            flags[:spent] ? block_height : nil
          )

        new_activity =
          counted_at?(new_received, block_height) ||
          counted_at?(new_spent, block_height)

        changes[:facts_delta] += 1 unless existing.key?(txid)

        changes[:inflow_delta] += 1 if
          !counted_at?(old_received, previous_checkpoint) &&
          counted_at?(new_received, block_height)

        changes[:outflow_delta] += 1 if
          !counted_at?(old_spent, previous_checkpoint) &&
          counted_at?(new_spent, block_height)

        changes[:tx_delta] += 1 if !old_activity && new_activity
      end

      changes
    end

    def activity_by_txid
      activity =
        Hash.new do |hash, key|
          hash[key] = {
            received: false,
            spent: false
          }
        end

      received_txids.each do |txid|
        activity[txid][:received] = true
      end

      spent_txids.each do |txid|
        activity[txid][:spent] = true
      end

      activity
    end

    def existing_facts(generation)
      txids = activity_by_txid.keys
      return {} if txids.empty?

      sql = <<~SQL.squish
        SELECT
          encode(txid, 'hex') AS txid_hex,
          received_height,
          spent_height
        FROM cluster_transaction_facts
        WHERE projection_generation_id = #{Integer(generation.id)}
          AND txid IN (#{txid_sql_list(txids)})
        FOR UPDATE
      SQL

      ActiveRecord::Base.connection
        .select_all(sql)
        .each_with_object({}) do |row, index|
          index[Txid.pack(row.fetch("txid_hex"))] = [
            row["received_height"]&.to_i,
            row["spent_height"]&.to_i
          ]
        end
    end

    def upsert_facts!
      rows =
        activity_by_txid.map do |txid, flags|
          [
            txid,
            flags[:received] ? block_height : nil,
            flags[:spent] ? block_height : nil
          ]
        end

      return if rows.empty?

      now =
        ActiveRecord::Base.connection.quote(Time.current)

      values =
        rows.map do |txid, received_height, spent_height|
          [
            "(#{certified_generation_id_sql},",
            "decode('#{Txid.unpack(txid)}', 'hex'),",
            sql_integer_or_null(received_height),
            ",",
            sql_integer_or_null(spent_height),
            ",",
            now,
            ",",
            now,
            ")"
          ].join(" ")
        end.join(", ")

      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO cluster_transaction_facts (
          projection_generation_id,
          txid,
          received_height,
          spent_height,
          created_at,
          updated_at
        )
        VALUES #{values}
        ON CONFLICT (projection_generation_id, txid)
        DO UPDATE SET
          received_height =
            CASE
              WHEN cluster_transaction_facts.received_height IS NULL
                THEN EXCLUDED.received_height
              WHEN EXCLUDED.received_height IS NULL
                THEN cluster_transaction_facts.received_height
              ELSE LEAST(
                cluster_transaction_facts.received_height,
                EXCLUDED.received_height
              )
            END,
          spent_height =
            CASE
              WHEN cluster_transaction_facts.spent_height IS NULL
                THEN EXCLUDED.spent_height
              WHEN EXCLUDED.spent_height IS NULL
                THEN cluster_transaction_facts.spent_height
              ELSE LEAST(
                cluster_transaction_facts.spent_height,
                EXCLUDED.spent_height
              )
            END,
          updated_at = EXCLUDED.updated_at
      SQL
    end

    def certified_generation_id_sql
      Integer(@certified_generation_id)
    end

    def txid_sql_list(txids)
      txids.map do |txid|
        "decode('#{Txid.unpack(txid)}', 'hex')"
      end.join(", ")
    end

    def sql_integer_or_null(value)
      value.nil? ? "NULL" : Integer(value).to_s
    end

    def counted_at?(height, checkpoint)
      height.present? && height.to_i <= checkpoint.to_i
    end

    def min_height(left, right)
      values =
        [left, right]
          .compact
          .map(&:to_i)

      values.min
    end

    def after_upsert_hook
      # Test hook for transaction rollback assertions.
    end

    def idempotent_result(generation)
      Result.new(
        ok: true,
        reason: :already_projected,
        generation: generation,
        changes: {
          inflow_delta: 0,
          outflow_delta: 0,
          tx_delta: 0,
          facts_delta: 0
        }
      )
    end

    def refused(reason, generation: nil, block: nil)
      Result.new(
        ok: false,
        reason: reason,
        generation: generation,
        block: block
      )
    end

    Result = Struct.new(
      :ok,
      :reason,
      :generation,
      :block,
      :changes,
      keyword_init: true
    )
  end
end
