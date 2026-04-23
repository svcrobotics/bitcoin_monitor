# app/services/btc/health/freshness_checker.rb
# frozen_string_literal: true

module Btc
  module Health
    class FreshnessChecker
      class << self
        def call(timestamp)
          new(timestamp).call
        end
      end

      def initialize(timestamp)
        @timestamp = timestamp
      end

      def call
        return "offline" if @timestamp.blank?

        age_in_hours = ((Time.current - @timestamp.to_time) / 1.hour).to_f

        if age_in_hours < 24
          "fresh"
        elsif age_in_hours <= 48
          "delayed"
        else
          "stale"
        end
      end
    end
  end
end