# frozen_string_literal: true

module ExchangeLike
  class StatusPresenter
    def initialize(status_hash)
      @status = (status_hash || {}).symbolize_keys
    end

    def label
      health.to_s.upcase.presence || "UNKNOWN"
    end

    def badge_classes
      case health
      when "ok"
        "bg-green-500/15 text-green-300 border border-green-500/30"
      when "late"
        "bg-yellow-500/15 text-yellow-300 border border-yellow-500/30"
      when "stale"
        "bg-red-500/15 text-red-300 border border-red-500/30"
      else
        "bg-gray-500/15 text-gray-300 border border-gray-500/30"
      end
    end

    def cursor_height
      @status[:cursor_height] || "—"
    end

    def lag
      value = @status[:lag]
      value.nil? ? "—" : value
    end

    def updated_at
      value = @status[:updated_at]
      return "—" if value.blank?

      value.strftime("%Y-%m-%d %H:%M")
    end

    def health
      @status[:health].to_s
    end

    def ok?
      health == "ok"
    end

    def late?
      health == "late"
    end

    def stale?
      health == "stale"
    end

    def unknown?
      health.blank? || health == "unknown"
    end
  end
end
