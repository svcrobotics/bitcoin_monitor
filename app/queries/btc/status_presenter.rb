# app/presenters/btc/status_presenter.rb
# frozen_string_literal: true

module Btc
  class StatusPresenter
    MAPPING = {
      "fresh" => { label: "Fresh", badge_class: "bg-green-500/15 text-green-300 border border-green-500/30" },
      "delayed" => { label: "Delayed", badge_class: "bg-amber-500/15 text-amber-300 border border-amber-500/30" },
      "stale" => { label: "Stale", badge_class: "bg-red-500/15 text-red-300 border border-red-500/30" },
      "offline" => { label: "Offline", badge_class: "bg-gray-500/15 text-gray-300 border border-gray-500/30" }
    }.freeze

    class << self
      def call(status)
        new(status).call
      end
    end

    def initialize(status)
      @status = status.to_s
    end

    def call
      MAPPING.fetch(@status, MAPPING["offline"])
    end
  end
end