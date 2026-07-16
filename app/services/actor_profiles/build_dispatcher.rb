# frozen_string_literal: true

module ActorProfiles
  class BuildDispatcher
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 100
    MAX_ATTEMPTS = 5
    STALE_AFTER = 15.minutes

    class UnexpectedResult < StandardError; end

    def self.call(limit: DEFAULT_LIMIT, now: Time.current)
      new(limit: limit, now: now).call
    end

    def self.claimable_scope(now: Time.current)
      retryable = ActorProfileBuildAdmission.joins(certified_source_join)
        .where(actor_profile_build_admissions: { status: %w[pending failed] })
        .where("actor_profile_build_admissions.attempts < ?", MAX_ATTEMPTS)
      stale = ActorProfileBuildAdmission.joins(certified_source_join)
        .where(actor_profile_build_admissions: { status: "processing" })
        .where("actor_profile_build_admissions.attempts < ?", MAX_ATTEMPTS)
        .where("actor_profile_build_admissions.claimed_at < ?", now - STALE_AFTER)
      retryable.or(stale)
    end

    def self.certified_source_join
      <<~SQL.squish
        INNER JOIN cluster_processed_blocks
          ON cluster_processed_blocks.height = actor_profile_build_admissions.source_height
         AND cluster_processed_blocks.block_hash = actor_profile_build_admissions.source_hash
         AND cluster_processed_blocks.status = 'processed'
        INNER JOIN address_spend_projection_blocks
          ON address_spend_projection_blocks.height = actor_profile_build_admissions.source_height
         AND address_spend_projection_blocks.block_hash = actor_profile_build_admissions.source_hash
         AND address_spend_projection_blocks.status = 'completed'
      SQL
    end

    def self.work_available?(now: Time.current)
      claimable_scope(now: now).exists? || Admission.cluster_handoff_work_available?(now: now)
    end

    def initialize(limit:, now:, logger: Rails.logger)
      @limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      @now = now
      @logger = logger
    end

    def call
      imported = Admission.import_cluster_handoffs(limit: @limit, now: @now)
      admissions = claim
      results = admissions.map { |admission| process(admission) }
      { ok: results.none? { |result| result[:status] == "failed" },
        imported_cluster_handoffs: imported.fetch(:imported),
        claimed: admissions.size,
        completed: results.count { |result| result[:status] == "completed" },
        failed: results.count { |result| result[:status] == "failed" },
        results: results }
    end

    private

    def claim
      claimed = []
      ApplicationRecord.transaction(requires_new: true) do
        self.class.claimable_scope(now: @now)
          .order("actor_profile_build_admissions.source_height",
            "actor_profile_build_admissions.cluster_id", "actor_profile_build_admissions.id")
          .limit(@limit)
          .lock("FOR UPDATE SKIP LOCKED").each do |admission|
            admission.claim!(at: @now)
            claimed << admission
          end
      end
      claimed
    end

    def process(admission)
      result = StrictBuildFromCluster.call(
        cluster_id: admission.cluster_id,
        composition_version: admission.cluster_composition_version,
        source_height: admission.source_height,
        source_hash: admission.source_hash
      )
      case result.fetch(:status)
      when "built", "already_current", "superseded"
        admission.complete!(at: Time.current)
        { admission_id: admission.id, cluster_id: admission.cluster_id,
          status: "completed", actor_profile_status: result.fetch(:status) }
      when "refused"
        admission.fail!(error_class: "ActorProfileSourceRefused")
        { admission_id: admission.id, cluster_id: admission.cluster_id,
          status: "failed", actor_profile_status: "refused", reason: result[:reason] }
      else
        raise UnexpectedResult, "ActorProfile returned a non-terminal result"
      end
    rescue StandardError => original
      persist_failure(admission, original)
      raise original
    end

    def persist_failure(admission, original)
      return unless admission&.persisted? && admission.status == "processing"
      admission.fail!(error_class: original.class.name)
    rescue StandardError => secondary
      @logger.error("[actor_profile_build_dispatch] failure_persistence_failed " \
        "admission_id=#{admission.id} error_class=#{secondary.class.name}")
    end
  end
end
