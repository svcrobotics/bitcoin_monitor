# frozen_string_literal: true

module Btc
  class ChartPresenter
    class << self
      def call(history)
        new(history).call
      end
    end

    def initialize(history)
      @history = Array(history)
    end

    def call
      @history.map do |row|
        {
          x: row[:day].strftime("%Y-%m-%d"),
          y: row[:close_usd].to_f
        }
      end
    end
  end
end