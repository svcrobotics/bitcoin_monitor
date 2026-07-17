# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class StrictBatchSlowQuarantineTest <
        ActiveSupport::TestCase
    def setup
      ActorProfiles::
        SlowProfileQuarantine
        .clear_all!

      ActorProfileCertificationEpoch
        .delete_all

      ActorProfileCertificationEpoch.create!(
        profile_version:
          ActorProfiles::
            StrictBuildFromCluster::
            PROFILE_VERSION,

        start_height:
          100,

        activated_at:
          Time.current,

        source:
          ActorProfileCertificationEpoch::
            SOURCE_CLUSTER_STRICT_CHECKPOINT,

        metadata: {}
      )
    end

    def teardown
      ActorProfiles::
        SlowProfileQuarantine
        .clear_all!

      ActorProfileCertificationEpoch
        .delete_all
    end

    test "normal selection excludes active quarantined clusters" do
      ActorProfiles::
        SlowProfileQuarantine
        .quarantine!(
          cluster_id: 42,
          reason: "profile_timeout"
        )

      builder =
        ActorProfiles::
          StrictBatchBuilder.new(
            limit: 5
          )

      observed_exclusions = []

      builder.define_singleton_method(
        :select_missing_cluster_ids
      ) do |limit:, exclude_ids: []|
        observed_exclusions <<
          exclude_ids

        []
      end

      builder.define_singleton_method(
        :select_existing_profile_cluster_ids
      ) do |condition:, limit:, exclude_ids: []|
        observed_exclusions <<
          exclude_ids

        []
      end

      result =
        builder.send(
          :next_cluster_ids
        )

      assert_empty result
      assert observed_exclusions.any?

      assert(
        observed_exclusions.all? do |ids|
          ids.include?(42)
        end,
        "Le cluster en quarantaine doit être exclu " \
        "de toutes les sélections normales"
      )
    end
  end
end
