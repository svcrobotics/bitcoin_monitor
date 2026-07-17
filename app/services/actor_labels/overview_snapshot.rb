# frozen_string_literal: true

module ActorLabels
  class OverviewSnapshot
    def self.call
      strict =
        ActorLabels::StrictHealthSnapshot.call

      strict.merge(
        heavy:
          ActorLabels::
            HeavyOverviewSnapshot.call,

        heavy_service:
          ActorBehaviors::Heavy::Service::
            OverviewSnapshot.call,

        final_resolution:
          ActorLabels::
            FinalResolutionSnapshot.call
      )
    end
  end
end
