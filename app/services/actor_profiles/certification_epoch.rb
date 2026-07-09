# frozen_string_literal: true

module ActorProfiles
  class CertificationEpoch
    SOURCE =
      ActorProfileCertificationEpoch::
        SOURCE_CLUSTER_STRICT_CHECKPOINT

    class MissingCheckpoint <
      StandardError
    end

    class << self
      def current
        ActorProfileCertificationEpoch.find_by(
          profile_version: profile_version
        )
      end

      def active?
        current.present?
      end

      def start_height
        current&.start_height
      end

      def activate_current!
        existing = current

        return existing if existing.present?

        height =
          ClusterProcessedBlock
            .where(status: "processed")
            .maximum(:height)
            .to_i

        if height <= 0
          raise(
            MissingCheckpoint,
            "Cluster strict checkpoint unavailable"
          )
        end

        ActorProfileCertificationEpoch.create!(
          profile_version: profile_version,
          start_height: height,
          activated_at: Time.current,
          source: SOURCE,
          metadata: {
            "checkpoint_model" =>
              "ClusterProcessedBlock",

            "checkpoint_status" =>
              "processed"
          }
        )
      rescue ActiveRecord::RecordNotUnique
        # Protection contre deux activations concurrentes.
        current || raise
      end

      private

      def profile_version
        ActorProfiles::
          StrictBuildFromCluster::
          PROFILE_VERSION
      end
    end
  end
end
