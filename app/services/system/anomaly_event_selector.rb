# frozen_string_literal: true

module System
  class AnomalyEventSelector
    TRANSITION_RANK = {
      "new" => 0,
      "worsened" => 1,
      "resolved" => 4
    }.freeze

    SEVERITY_RANK = {
      "critical" => 0,
      "warning" => 1
    }.freeze

    def self.call(events)
      Array(events)
        .select { |event| event[:notify] == true }
        .sort_by do |event|
          [
            severity_rank(event),
            TRANSITION_RANK.fetch(event[:transition].to_s, 3),
            event[:first_detected_at] || Time.current,
            event[:fingerprint].to_s
          ]
        end
        .first
    end

    def self.severity_rank(event)
      return 3 if event[:transition].to_s == "resolved"

      SEVERITY_RANK.fetch(event[:severity].to_s, 2)
    end
  end
end
