# frozen_string_literal: true

module ActorLabels
  class HealthSnapshot
    def self.call
      ActorLabels::OverviewSnapshot.call
    end
  end
end
