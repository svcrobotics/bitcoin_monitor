# frozen_string_literal: true

class ActorLabelsController < ApplicationController
  def index
    @actor_labels = ActorLabel
      .includes(:cluster)
      .order(confidence: :desc, updated_at: :desc)
      .limit(100)

    @actor_labels_status = {
      total: ActorLabel.count,
      displayed: @actor_labels.size,
      exchange_like: ActorLabel.where(label: "exchange_like").count,
      whale_like: ActorLabel.where(label: "whale_like").count,
      service_like: ActorLabel.where(label: "service_like").count,
      retail_like: ActorLabel.where(label: "retail_like").count,
      unknown: ActorLabel.where(label: "unknown").count,
      last_updated_at: ActorLabel.maximum(:updated_at)
    }
  end
end
