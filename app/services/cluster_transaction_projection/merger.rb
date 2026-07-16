# frozen_string_literal: true

module ClusterTransactionProjection
  class Merger
    def self.call(...)
      new(...).call
    end

    def initialize(
      target_cluster_id:,
      target_composition_version:,
      checkpoint_height:,
      checkpoint_hash:,
      source_generation_ids:
    )
      @target_cluster_id = target_cluster_id.to_i
      @target_composition_version =
        target_composition_version.to_i
      @checkpoint_height = checkpoint_height.to_i
      @checkpoint_hash = checkpoint_hash.to_s
      @source_generation_ids =
        Array(source_generation_ids)
          .map(&:to_i)
          .reject(&:zero?)
          .uniq
    end

    def call
      ApplicationRecord.transaction do
        generation =
          ClusterTransactionProjectionGeneration.create!(
            cluster_id: target_cluster_id,
            composition_version: target_composition_version,
            base_checkpoint_height: checkpoint_height,
            base_checkpoint_hash: checkpoint_hash,
            checkpoint_height: checkpoint_height,
            checkpoint_hash: checkpoint_hash,
            source: "merge",
            status: "building",
            started_at: Time.current
          )

        insert_merged_facts!(generation)

        certification =
          Certifier.call(generation)

        if certification.ok
          ClusterTransactionProjectionGeneration
            .where(id: source_generation_ids)
            .update_all(
              status: "replaced",
              updated_at: Time.current
            )
        end

        certification
      end
    end

    private

    attr_reader(
      :target_cluster_id,
      :target_composition_version,
      :checkpoint_height,
      :checkpoint_hash,
      :source_generation_ids
    )

    def insert_merged_facts!(generation)
      return if source_generation_ids.empty?

      connection =
        ActiveRecord::Base.connection

      quoted_ids =
        source_generation_ids
          .map { |id| Integer(id) }
          .join(", ")

      now =
        connection.quote(Time.current)

      connection.execute(<<~SQL.squish)
        INSERT INTO cluster_transaction_facts (
          projection_generation_id,
          txid,
          received_height,
          spent_height,
          created_at,
          updated_at
        )
        SELECT
          #{Integer(generation.id)} AS projection_generation_id,
          txid,
          MIN(received_height) AS received_height,
          MIN(spent_height) AS spent_height,
          #{now} AS created_at,
          #{now} AS updated_at
        FROM cluster_transaction_facts
        WHERE projection_generation_id IN (#{quoted_ids})
        GROUP BY txid
        HAVING
          MIN(received_height) IS NOT NULL
          OR MIN(spent_height) IS NOT NULL
      SQL
    end
  end
end
