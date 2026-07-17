# frozen_string_literal: true

module ActorProfiles
  class CertificationTargetScope
    INCLUDE_SINGLETONS_ENV =
      "ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS"

    class InactiveEpoch <
      StandardError
    end

    class InvalidCheckpoint <
      StandardError
    end

    class << self
      def call(checkpoint_height:)
        new(
          checkpoint_height:
            checkpoint_height
        ).call
      end

      def sql_condition(checkpoint_height:)
        relation =
          call(
            checkpoint_height:
              checkpoint_height
          )

        "clusters.id IN (" \
          "#{relation.select(:id).to_sql}" \
          ")"
      end
    end

    def initialize(checkpoint_height:)
      @checkpoint_height =
        checkpoint_height.to_i
    end

    def call
      epoch =
        ActorProfiles::
          CertificationEpoch::
          current

      unless epoch
        raise(
          InactiveEpoch,
          "ActorProfile certification epoch is inactive"
        )
      end

      if @checkpoint_height <= 0
        raise(
          InvalidCheckpoint,
          "Cluster strict checkpoint is unavailable"
        )
      end

      if @checkpoint_height <
         epoch.start_height
        return Cluster.none
      end

      Cluster
        .where(
          "clusters.address_count >= ?",
          minimum_address_count
        )
        .where(
          last_seen_height:
            epoch.start_height..
              @checkpoint_height
        )
    end

    private

    def minimum_address_count
      include_singletons? ? 1 : 2
    end

    def include_singletons?
      ActiveModel::Type::Boolean
        .new
        .cast(
          ENV.fetch(
            INCLUDE_SINGLETONS_ENV,
            "false"
          )
        )
    end
  end
end
