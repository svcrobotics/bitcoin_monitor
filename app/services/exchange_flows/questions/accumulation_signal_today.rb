# frozen_string_literal: true

module ExchangeFlows
  module Questions
    class AccumulationSignalToday < SellingPressureToday
      private

      def verdict_for(netflow)
        if netflow <= -2_000
          "Accumulation forte"
        elsif netflow <= -500
          "Accumulation modérée"
        elsif netflow >= 500
          "Pas de signal d’accumulation"
        else
          "Accumulation neutre"
        end
      end

      def answer_for(netflow)
        if netflow.negative?
          "Oui, les sorties nettes des exchanges suggèrent une accumulation potentielle."
        elsif netflow.positive?
          "Non, les flux actuels ne suggèrent pas une accumulation. Les BTC entrent davantage sur les exchanges."
        else
          "Le signal est neutre : les flux ne montrent pas clairement une accumulation."
        end
      end
    end
  end
end