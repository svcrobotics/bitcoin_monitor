# frozen_string_literal: true

module ExchangeFlows
  module Questions
    class NetflowDirectionToday < SellingPressureToday
      private

      def answer_for(netflow)
        if netflow.positive?
          "Aujourd’hui, les BTC entrent davantage sur les exchanges qu’ils n’en sortent."
        elsif netflow.negative?
          "Aujourd’hui, les BTC sortent davantage des exchanges qu’ils n’y entrent."
        else
          "Aujourd’hui, les entrées et sorties des exchanges sont équilibrées."
        end
      end
    end
  end
end