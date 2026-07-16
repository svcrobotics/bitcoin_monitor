# frozen_string_literal: true

module ActorProfiles
  class OperationalSnapshot
    class << self
      def call(**options) = StrictHealthSnapshot.call(**options)
      alias read call
      alias refresh! call

      def refresh_from_batch(_result) = call
      def mark_waiting(reason:, result: {}) = call.merge(activity: { wait_reason: reason, result: result })
    end
  end
end
