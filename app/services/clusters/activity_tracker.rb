# frozen_string_literal: true

module Clusters
  class ActivityTracker
    def self.call(cluster_id:, height:, active_at: Time.current)
      new(cluster_id: cluster_id, height: height, active_at: active_at).call
    end

    def initialize(cluster_id:, height:, active_at:)
      @cluster_id = cluster_id
      @height = height.to_i
      @active_at = active_at
    end

    def call
      state = ClusterActivityState.find_or_initialize_by(cluster_id: cluster_id)

      previous_height = state.last_seen_height
      previous_at = state.last_seen_at

      state.last_active_height = previous_height
      state.last_active_at = previous_at
      state.last_seen_height = height
      state.last_seen_at = active_at
      state.inactive_blocks = previous_height.present? ? [height - previous_height.to_i, 0].max : nil
      state.inactive_seconds = previous_at.present? ? [active_at - previous_at, 0].max.to_i : nil
      state.activity_count = state.activity_count.to_i + 1

      state.save!
      state
    end

    private

    attr_reader :cluster_id, :height, :active_at
  end
end