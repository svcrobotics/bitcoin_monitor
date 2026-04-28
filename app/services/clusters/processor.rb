# frozen_string_literal: true

module Clusters
  class Processor
    def self.call(heights:)
      new(heights: heights).call
    end

    def initialize(heights:)
      @heights = heights.map(&:to_i).sort
    end

    def call
      return { status: "empty", processed: 0 } if @heights.empty?

      from_height = @heights.min
      to_height = @heights.max

      result = ClusterScanner.call(
        from_height: from_height,
        to_height: to_height,
        refresh: false
      )

      Clusters::WriteBuffer.push(
        event: "cluster.scan.completed",
        payload: result.merge(
          requested_heights: @heights,
          realtime: true,
          detected_at: Time.current.iso8601
        )
      )

      {
        status: "ok",
        from_height: from_height,
        to_height: to_height,
        scanner: result
      }
    end
  end
end