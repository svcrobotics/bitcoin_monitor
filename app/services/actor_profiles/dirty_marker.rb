# frozen_string_literal: true

module ActorProfiles
  class DirtyMarker
    class << self
      def mark(cluster_id)
        new.mark(cluster_id)
      end
    end

    def mark(cluster_id)
      id = normalize_id(cluster_id)
      return false unless id

      ActorProfile
        .where(cluster_id: id)
        .update_all(dirty: true)
        .positive?
    end

    private

    def normalize_id(value)
      id = Integer(value)
      id.positive? ? id : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
