# frozen_string_literal: true

class ActorLabelsController <
  ApplicationController

  def index
    @snapshot =
      ActorLabels::OverviewSnapshot.call
  end
end
