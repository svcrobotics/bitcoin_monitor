# frozen_string_literal: true

module ActorProfiles
  class CertifiedScope
    PROFILE_VERSION =
      ActorProfiles::
        StrictBuildFromCluster::
        PROFILE_VERSION

    class << self
      def call
        epoch =
          ActorProfiles::
            CertificationEpoch::
            current

        return ActorProfile.none unless epoch

        ActorProfile
          .joins(:cluster)
          .where(
            "EXISTS (" \
            "SELECT 1 FROM addresses " \
            "WHERE addresses.cluster_id = clusters.id" \
            ")"
          )
          .where(
            "clusters.last_seen_height >= ?",
            epoch.start_height
          )
          .where(
            certification_epoch_height:
              epoch.start_height
          )
          .where(
            certification_scope:
              ActorProfile::
                CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH
          )
          .where.not(
            certified_at: nil
          )
          .where(
            "actor_profiles.dirty IS NOT TRUE"
          )
          .where(
            "actor_profiles.cluster_composition_version = " \
            "clusters.composition_version"
          )
          .where(
            "COALESCE(" \
            "actor_profiles.last_computed_height, " \
            "0" \
            ") >= COALESCE(" \
            "clusters.last_seen_height, " \
            "0" \
            ")"
          )
          .where(
            "actor_profiles.last_computed_height >= ?",
            epoch.start_height
          )
          .where(
            "actor_profiles.traits ->> 'profile_version' = ?",
            PROFILE_VERSION
          )
          .where(
            "COALESCE(" \
            "actor_profiles.metadata ->> 'strict', " \
            "'false'" \
            ") = 'true'"
          )
      end
    end
  end
end
