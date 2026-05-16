# frozen_string_literal: true

class ActorLabelsController < ApplicationController
  def index
    @actor_labels = ActorLabels::InterestingActorsQuery.call(limit: 100)
  end
end
