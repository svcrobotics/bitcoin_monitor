# frozen_string_literal: true

module StrictPipeline
  # Strict IO exclusion is not an authority in the certified pipeline in HEAD.
  # The scheduler and the strict jobs enforce their bounded admission and
  # operational locks independently. Keep the legacy observation explicit so
  # callers never confuse a missing constant with an idle lease.
  class StrictIoLease
    UNAVAILABLE_REASON = "strict_io_lease_unavailable"

    Observation = Struct.new(
      :status,
      :available,
      :reason,
      :owner,
      :acquired_at,
      :expires_at,
      keyword_init: true
    ) do
      def available?
        available == true
      end
    end

    def self.current
      Observation.new(
        status: "unavailable",
        available: false,
        reason: UNAVAILABLE_REASON,
        owner: nil,
        acquired_at: nil,
        expires_at: nil
      )
    end
  end
end
