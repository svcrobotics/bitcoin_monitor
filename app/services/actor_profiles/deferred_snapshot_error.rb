# frozen_string_literal: true

module ActorProfiles
  class DeferredSnapshotError < StandardError
    attr_reader :cluster_id, :reason, :details

    def initialize(message, cluster_id:, reason:, details: {})
      @cluster_id = cluster_id.to_i
      @reason = reason.to_s
      @details = details

      super(message)
    end

    def to_h
      {
        cluster_id: cluster_id,
        reason: reason,
        message: message,
        details: details
      }
    end
  end
end
