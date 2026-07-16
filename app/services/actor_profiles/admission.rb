# frozen_string_literal: true

module ActorProfiles
  class Admission
    HANDOFF_STALE_AFTER = 15.minutes
    def self.register(cluster_id:, composition_version:, source_height:, source_hash:, reason:)
      new(cluster_id:, composition_version:, source_height:, source_hash:, reason:).register
    end

    def self.register_source(source_height:, source_hash:, reason: "address_spend")
      height = Integer(source_height)
      hash = source_hash.to_s
      raise ArgumentError, "source_height must be nonnegative" if height.negative?
      raise ArgumentError, "source_hash must be present" if hash.empty?
      validate_source!(height, hash)

      cluster_ids = affected_cluster_ids(height, hash)
      rows = Cluster.where(id: cluster_ids).order(:id).pluck(:id, :composition_version).map do |id, version|
        {
          cluster_id: id,
          cluster_composition_version: version,
          source_height: height,
          source_hash: hash,
          reason: reason.to_s,
          status: "pending",
          attempts: 0,
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      raise ArgumentError, "invalid reason" unless ActorProfileBuildAdmission::REASONS.include?(reason.to_s)

      inserted = if rows.empty?
        0
      else
        ActorProfileBuildAdmission.insert_all(
          rows, unique_by: :idx_actor_profile_admissions_identity, returning: %w[id]
        ).rows.size
      end
      ClusterActorProfileHandoff.where(cluster_height: height, block_hash: hash)
        .where.not(status: "completed")
        .update_all(status: "completed", completed_at: Time.current,
          last_error_class: nil, updated_at: Time.current)
      { ok: true, source_height: height, source_hash: hash,
        selected: rows.size, created: inserted, already_registered: rows.size - inserted }
    end

    def self.register_latest(cluster_ids:, reason: "recovery")
      raise ArgumentError, "invalid reason" unless
        ActorProfileBuildAdmission::REASONS.include?(reason.to_s)
      checkpoint = AddressSpendProjectionBlock.where(status: "completed").order(height: :desc).first
      return { ok: true, selected: 0, created: 0, already_registered: 0 } unless checkpoint
      validate_source!(checkpoint.height, checkpoint.block_hash)
      ids = Array(cluster_ids).filter_map { |id| Integer(id) rescue nil }.select(&:positive?).uniq
      rows = Cluster.where(id: ids).order(:id).pluck(:id, :composition_version).map do |id, version|
        { cluster_id: id, cluster_composition_version: version,
          source_height: checkpoint.height, source_hash: checkpoint.block_hash,
          reason: reason.to_s, status: "pending", attempts: 0,
          created_at: Time.current, updated_at: Time.current }
      end
      inserted = rows.empty? ? 0 : ActorProfileBuildAdmission.insert_all(
        rows, unique_by: :idx_actor_profile_admissions_identity, returning: %w[id]
      ).rows.size
      { ok: true, selected: rows.size, created: inserted,
        already_registered: rows.size - inserted,
        registered_cluster_ids: rows.map { |row| row.fetch(:cluster_id) } }
    end

    def self.cluster_handoff_work_available?(now: Time.current)
      cluster_handoff_scope(now: now).exists?
    end

    def self.import_cluster_handoffs(limit:, now: Time.current)
      imported = 0
      ApplicationRecord.transaction(requires_new: true) do
        handoffs = cluster_handoff_scope(now: now)
          .order("cluster_actor_profile_handoffs.cluster_height",
            "cluster_actor_profile_handoffs.cluster_id", "cluster_actor_profile_handoffs.id")
          .limit([[Integer(limit), 1].max, 100].min)
          .lock("FOR UPDATE SKIP LOCKED")
          .to_a
        rows = handoffs.map do |handoff|
          { cluster_id: handoff.cluster_id,
            cluster_composition_version: handoff.composition_version,
            source_height: handoff.cluster_height,
            source_hash: handoff.block_hash,
            reason: "cluster_composition", status: "pending", attempts: 0,
            created_at: now, updated_at: now }
        end
        ActorProfileBuildAdmission.insert_all(
          rows, unique_by: :idx_actor_profile_admissions_identity
        ) if rows.any?
        if handoffs.any?
          ClusterActorProfileHandoff.where(id: handoffs.map(&:id)).update_all(
            status: "completed", completed_at: now, last_error_class: nil, updated_at: now
          )
        end
        imported = handoffs.size
      end
      { ok: true, imported: imported }
    end

    def self.cluster_handoff_scope(now:)
      ready = ClusterActorProfileHandoff.joins(<<~SQL.squish)
        INNER JOIN address_spend_projection_blocks
          ON address_spend_projection_blocks.height = cluster_actor_profile_handoffs.cluster_height
         AND address_spend_projection_blocks.block_hash = cluster_actor_profile_handoffs.block_hash
         AND address_spend_projection_blocks.status = 'completed'
      SQL
      retryable = ready.where(status: %w[pending failed])
      stale = ready.where(status: "processing")
        .where("cluster_actor_profile_handoffs.claimed_at < ?", now - HANDOFF_STALE_AFTER)
      retryable.or(stale)
    end

    def self.validate_source!(height, hash)
      cluster = ClusterProcessedBlock.exists?(height: height, block_hash: hash, status: "processed")
      spend = AddressSpendProjectionBlock.exists?(height: height, block_hash: hash, status: "completed")
      raise ArgumentError, "certified source checkpoint is unavailable" unless cluster && spend
    end

    def self.affected_cluster_ids(height, hash)
      input_ids = Address.joins(
        "INNER JOIN cluster_inputs ON cluster_inputs.address = addresses.address"
      ).where(cluster_inputs: { spent_block_height: height }).where.not(cluster_id: nil).distinct.pluck(:cluster_id)
      output_ids = Address.joins(
        "INNER JOIN utxo_outputs ON utxo_outputs.address = addresses.address"
      ).where(utxo_outputs: { block_height: height }).where.not(cluster_id: nil).distinct.pluck(:cluster_id)
      handoff_ids = ClusterActorProfileHandoff.where(cluster_height: height, block_hash: hash).pluck(:cluster_id)
      (input_ids + output_ids + handoff_ids).uniq.sort
    end

    def initialize(cluster_id:, composition_version:, source_height:, source_hash:, reason:)
      @cluster_id = positive_integer(cluster_id, :cluster_id)
      @composition_version = positive_integer(composition_version, :composition_version)
      @source_height = nonnegative_integer(source_height, :source_height)
      @source_hash = source_hash.to_s
      @reason = reason.to_s
      raise ArgumentError, "source_hash must be present" if @source_hash.empty?
      raise ArgumentError, "invalid reason" unless ActorProfileBuildAdmission::REASONS.include?(@reason)
    end

    def register
      validate_provenance!
      admission = nil
      created = false

      ActorProfileBuildAdmission.transaction(requires_new: false) do
        admission = ActorProfileBuildAdmission.find_or_initialize_by(identity)
        if admission.new_record?
          admission.reason = @reason
          admission.save!
          created = true
        end
      end

      {
        ok: true,
        status: created ? "created" : "already_registered",
        admission_id: admission.id,
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        source_height: @source_height,
        source_hash: @source_hash,
        reason: admission.reason
      }
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    def identity
      {
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        source_height: @source_height,
        source_hash: @source_hash
      }
    end

    def validate_provenance!
      cluster = Cluster.find_by(id: @cluster_id)
      raise ArgumentError, "cluster is unavailable" unless cluster
      raise ArgumentError, "cluster composition version is not current" unless
        cluster.composition_version.to_i == @composition_version

      self.class.validate_source!(@source_height, @source_hash)
    end

    def positive_integer(value, name)
      integer = value.is_a?(String) ? Integer(value, 10) : Integer(value)
      raise ArgumentError unless integer.positive?
      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a positive integer"
    end

    def nonnegative_integer(value, name)
      integer = value.is_a?(String) ? Integer(value, 10) : Integer(value)
      raise ArgumentError if integer.negative?
      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a nonnegative integer"
    end
  end
end
