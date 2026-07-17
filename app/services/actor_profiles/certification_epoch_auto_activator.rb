# frozen_string_literal: true

module ActorProfiles
  class CertificationEpochAutoActivator
    LOOKBACK_BLOCKS = 10

    ACTIVATION_MODE =
      "scheduler_auto_cluster_lookback"

    def self.call(snapshot:)
      new(snapshot: snapshot).call
    end

    def initialize(snapshot:)
      @snapshot =
        if snapshot.respond_to?(
          :deep_symbolize_keys
        )
          snapshot.deep_symbolize_keys
        else
          snapshot
        end
    end

    def call
      existing =
        ActorProfiles::
          CertificationEpoch.current

      return existing_result(existing) if existing

      actor_profile =
        snapshot[:actor_profile] || {}

      unless actor_profile.key?(
        :epoch_active
      )
        return waiting(
          "actor_profile_epoch_state_unknown"
        )
      end

      if actor_profile[:epoch_active] == true
        return waiting(
          "epoch_reported_active_without_record"
        )
      end

      cluster =
        snapshot[:cluster] || {}

      projection =
        snapshot[
          :address_spend_projection
        ] || {}

      cluster_checkpoint =
        cluster[
          :processed_height
        ].to_i

      return waiting(
        "cluster_checkpoint_missing"
      ) unless
        cluster[
          :checkpoint_available
        ] == true &&
        cluster_checkpoint.positive?

      return waiting(
        "address_spend_projection_unavailable"
      ) unless
        projection[:available] == true &&
        projection[
          :checkpoint_available
        ] == true

      projection_checkpoint =
        projection[
          :checkpoint_height
        ].to_i

      return waiting(
        "address_spend_projection_not_caught_up"
      ) unless
        projection[
          :caught_up_to_cluster
        ] == true &&
        projection_checkpoint >=
          cluster_checkpoint

      start_height = [
        cluster_checkpoint -
          LOOKBACK_BLOCKS,
        1
      ].max

      epoch =
        create_epoch!(
          start_height:
            start_height,

          cluster_checkpoint:
            cluster_checkpoint,

          projection_checkpoint:
            projection_checkpoint
        )

      operational =
        ActorProfiles::
          OperationalSnapshot.refresh!

      Rails.logger.info(
        "[actor_profile_certification_epoch] " \
        "automatically_activated " \
        "start_height=#{epoch.start_height} " \
        "cluster_checkpoint=#{cluster_checkpoint} " \
        "projection_checkpoint=#{projection_checkpoint} " \
        "lookback_blocks=#{LOOKBACK_BLOCKS}"
      )

      {
        status:
          "activated",

        epoch_id:
          epoch.id,

        start_height:
          epoch.start_height,

        lookback_blocks:
          LOOKBACK_BLOCKS,

        cluster_checkpoint:
          cluster_checkpoint,

        projection_checkpoint:
          projection_checkpoint,

        pending_profiles_since_epoch:
          operational.dig(
            :progress,
            :pending_profiles_since_epoch
          )
      }
    rescue ActiveRecord::RecordNotUnique
      existing =
        ActorProfiles::
          CertificationEpoch.current

      return existing_result(
        existing
      ) if existing

      raise
    end

    private

    attr_reader :snapshot

    def create_epoch!(
      start_height:,
      cluster_checkpoint:,
      projection_checkpoint:
    )
      ActorProfileCertificationEpoch.create!(
        profile_version:
          ActorProfiles::
            StrictBuildFromCluster::
            PROFILE_VERSION,

        start_height:
          start_height,

        activated_at:
          Time.current,

        source:
          ActorProfileCertificationEpoch::
            SOURCE_CLUSTER_STRICT_CHECKPOINT,

        metadata: {
          activation_mode:
            ACTIVATION_MODE,

          lookback_blocks:
            LOOKBACK_BLOCKS,

          cluster_checkpoint:
            cluster_checkpoint,

          projection_checkpoint:
            projection_checkpoint,

          layer1_checkpoint:
            snapshot.dig(
              :layer1,
              :processed_height
            ),

          activated_by:
            "strict_pipeline_scheduler"
        }
      )
    end

    def waiting(reason)
      {
        status:
          "waiting",

        reason:
          reason,

        lookback_blocks:
          LOOKBACK_BLOCKS
      }
    end

    def existing_result(epoch)
      {
        status:
          "existing",

        epoch_id:
          epoch.id,

        start_height:
          epoch.start_height,

        lookback_blocks:
          epoch.metadata[
            "lookback_blocks"
          ] ||
          epoch.metadata[
            :lookback_blocks
          ]
      }
    end
  end
end
