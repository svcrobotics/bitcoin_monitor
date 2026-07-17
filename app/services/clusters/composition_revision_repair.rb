# frozen_string_literal: true

module Clusters
  class CompositionRevisionRepair
    DEFAULT_BATCH_SIZE = 1_000

    def self.call(...)
      new(...).call
    end

    def initialize(
      batch_size: DEFAULT_BATCH_SIZE,
      checkpoint_id: 1
    )
      @batch_size = [batch_size.to_i, 1].max
      @checkpoint_id = checkpoint_id.to_i
    end

    def call
      ApplicationRecord.transaction do
        checkpoint = nil

        checkpoint =
          lock_checkpoint

        checkpoint.update!(
          status: "processing",
          started_at: checkpoint.started_at || Time.current,
          last_error: nil
        )

        ids =
          Cluster
            .where("id > ?", checkpoint.last_cluster_id.to_i)
            .order(:id)
            .limit(batch_size)
            .pluck(:id)

        if ids.empty?
          checkpoint.update!(
            status: "completed",
            completed_at: Time.current
          )

          return result(checkpoint, scanned: 0, updated: 0)
        end

        updated =
          Cluster
            .where(id: ids)
            .where(
              "composition_version IS NULL OR composition_version < 1"
            )
            .update_all(
              composition_version: Cluster::INITIAL_COMPOSITION_VERSION,
              updated_at: Time.current
            )

        checkpoint.update!(
          status: "pending",
          last_cluster_id: ids.max,
          scanned_count:
            checkpoint.scanned_count.to_i + ids.size,
          updated_count:
            checkpoint.updated_count.to_i + updated
        )

        result(
          checkpoint,
          scanned: ids.size,
          updated: updated
        )
      rescue => error
        checkpoint&.update!(
          status: "failed",
          failed_at: Time.current,
          last_error: "#{error.class}: #{error.message}"
        )

        raise
      end
    end

    private

    attr_reader :batch_size, :checkpoint_id

    def lock_checkpoint
      ClusterCompositionRevisionRepairCheckpoint
        .lock
        .find_or_create_by!(id: checkpoint_id) do |checkpoint|
          checkpoint.status = "pending"
        end
    end

    def result(checkpoint, scanned:, updated:)
      {
        ok: true,
        checkpoint_id: checkpoint.id,
        status: checkpoint.status,
        last_cluster_id: checkpoint.last_cluster_id.to_i,
        scanned: scanned,
        updated: updated,
        total_scanned: checkpoint.scanned_count.to_i,
        total_updated: checkpoint.updated_count.to_i
      }
    end
  end
end
