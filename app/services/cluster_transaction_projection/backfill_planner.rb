# frozen_string_literal: true

module ClusterTransactionProjection
  class BackfillPlanner
    def self.plan!(...)
      new(...).plan!
    end

    def self.call(...)
      plan!(...)
    end

    def initialize(
      cluster_ids:,
      target_checkpoint_height:,
      target_checkpoint_hash:,
      source: "pilot_backfill",
      logger: Rails.logger
    )
      @cluster_ids = Array(cluster_ids).map(&:to_i).uniq.sort
      @target_checkpoint_height = target_checkpoint_height.to_i
      @target_checkpoint_hash = target_checkpoint_hash.to_s
      @source = source.to_s
      @logger = logger
    end

    def plan!
      raise ArgumentError, "cluster_ids required" if cluster_ids.empty?

      verify_target_checkpoint!

      existing = matching_active_run
      return existing if existing

      verify_no_competing_run!

      run = nil

      ApplicationRecord.transaction do
        clusters =
          Cluster
            .lock
            .where(id: cluster_ids)
            .order(:id)
            .index_by(&:id)

        missing = cluster_ids - clusters.keys
        raise ArgumentError, "missing clusters #{missing.join(',')}" if missing.any?

        run =
          ClusterTransactionProjectionBackfillRun.create!(
            target_checkpoint_height: target_checkpoint_height,
            target_checkpoint_hash: target_checkpoint_hash,
            status: "pending",
            source: source
          )

        clusters.each_value do |cluster|
          revision = cluster.composition_version.to_i
          raise ArgumentError, "invalid composition revision #{cluster.id}" if revision < 1

          ClusterTransactionProjectionBackfillItem.create!(
            run: run,
            cluster_id: cluster.id,
            composition_version: revision,
            projection_generation_id: nil,
            status: "pending",
            stage: BackfillRunner::STAGES.first,
            source_cursor: {}
          )
        end
      end

      run
    end

    private

    attr_reader(
      :cluster_ids,
      :target_checkpoint_height,
      :target_checkpoint_hash,
      :source,
      :logger
    )

    def matching_active_run
      ClusterTransactionProjectionBackfillRun.active
        .includes(:items)
        .order(:id)
        .detect do |run|
          same_signature?(run)
        end
    end

    def same_signature?(run)
      return false unless
        run.target_checkpoint_height.to_i == target_checkpoint_height &&
          run.target_checkpoint_hash.to_s == target_checkpoint_hash &&
          run.source.to_s == source

      run_cluster_ids =
        run.items.order(:cluster_id, :id).pluck(:cluster_id)

      return false unless run_cluster_ids == cluster_ids

      true
    end

    def verify_no_competing_run!
      return if matching_active_run

      active =
        ClusterTransactionProjectionBackfillRun.active.exists?

      raise "cluster transaction backfill already active" if active
    end

    def verify_target_checkpoint!
      checkpoint =
        ClusterProcessedBlock
          .where(status: "processed")
          .order(height: :desc)
          .first

      unless checkpoint&.height.to_i == target_checkpoint_height &&
             checkpoint.block_hash.to_s == target_checkpoint_hash
        raise "cluster checkpoint changed"
      end
    end
  end
end
