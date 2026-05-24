# frozen_string_literal: true

module ExchangeFlows
  module Questions
    class SellingPressureToday
      def self.call(question:)
        new(question: question).call
      end

      def initialize(question:)
        @question = question
      end

      def call
        flow = Dashboard::ExchangeCoreNetflowToday.call

        netflow = flow[:netflow_btc].to_d
        inflow  = flow[:inflow_btc].to_d
        outflow = flow[:outflow_btc].to_d

        {
          question: question.question,
          key: question.key,
          module_name: question.module_name,
          tier: question.tier,

          verdict: verdict_for(netflow),
          answer: answer_for(netflow),
          evidence: evidence_for(inflow, outflow, netflow, flow),
          interpretation: flow[:interpretation],
          methodology: methodology,
          confidence: confidence_for(flow),
          updated_at: flow[:updated_at],
          historical_path: question.historical_path
        }
      end

      private

      attr_reader :question

      def verdict_for(netflow)
        if netflow >= 2_000
          "Pression vendeuse élevée"
        elsif netflow >= 500
          "Pression vendeuse modérée"
        elsif netflow <= -2_000
          "Accumulation forte"
        elsif netflow <= -500
          "Accumulation modérée"
        else
          "Signal neutre"
        end
      end

      def answer_for(netflow)
        if netflow.positive?
          "Aujourd’hui, plus de BTC entrent sur les exchanges qu’ils n’en sortent. Cela suggère une pression vendeuse potentielle."
        elsif netflow.negative?
          "Aujourd’hui, plus de BTC sortent des exchanges qu’ils n’y entrent. Cela suggère une accumulation potentielle."
        else
          "Aujourd’hui, les flux entrants et sortants sont équilibrés. Le signal est neutre."
        end
      end

      def evidence_for(inflow, outflow, netflow, flow)
        [
          { label: "Inflow", value: inflow, unit: "BTC" },
          { label: "Outflow", value: outflow, unit: "BTC" },
          { label: "Netflow", value: netflow, unit: "BTC" },
          { label: "Événements analysés", value: flow[:events_count], unit: nil },
          { label: "Signal brut", value: flow[:signal], unit: nil }
        ]
      end

      def methodology
        "Le signal est calculé à partir des flux entre acteurs identifiés comme exchange-like et le reste du réseau. Netflow = inflow - outflow. Un netflow positif indique plus de BTC vers les exchanges ; un netflow négatif indique plus de BTC retirés des exchanges."
      end

      def confidence_for(flow)
        count = flow[:events_count].to_i

        if count >= 1_000
          "élevée"
        elsif count >= 100
          "moyenne"
        else
          "faible"
        end
      end
    end
  end
end