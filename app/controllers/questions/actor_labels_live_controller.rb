# frozen_string_literal: true

module Questions
  class ActorLabelsLiveController <
    ApplicationController

    def show
      @snapshot =
        ActorLabels::OverviewSnapshot.call
    end
  end
end
