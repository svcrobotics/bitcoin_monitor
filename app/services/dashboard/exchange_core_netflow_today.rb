# app/services/dashboard/exchange_core_netflow_today.rb
# frozen_string_literal: true

module Dashboard
  class ExchangeCoreNetflowToday
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
      @range = now.beginning_of_day..now
    end

    def call
      rows = ExchangeCoreFlowEvent.where(event_time: @range)

      inflow_btc = rows.where(direction: "inflow").sum(:amount_btc).to_d
      outflow_btc = rows.where(direction: "outflow").sum(:amount_btc).to_d
      netflow_btc = inflow_btc - outflow_btc

      {
        inflow_btc: inflow_btc,
        outflow_btc: outflow_btc,
        netflow_btc: netflow_btc,
        events_count: rows.count,
        signal: signal_for(netflow_btc),
        interpretation: interpretation_for(netflow_btc),
        updated_at: rows.maximum(:event_time) || @now,
        source: "ExchangeCoreFlowEvent"
      }
    end

    private

    def signal_for(netflow_btc)
      if netflow_btc >= 2_000
        "Pression vendeuse forte"
      elsif netflow_btc >= 500
        "Pression vendeuse modérée"
      elsif netflow_btc <= -2_000
        "Accumulation forte"
      elsif netflow_btc <= -500
        "Accumulation modérée"
      else
        "Flux équilibrés"
      end
    end

    def interpretation_for(netflow_btc)
      if netflow_btc >= 2_000
        "Depuis le début de la journée, les entrées vers exchanges dominent fortement. Le marché peut subir une pression vendeuse importante."
      elsif netflow_btc >= 500
        "Depuis le début de la journée, les entrées vers exchanges sont supérieures aux sorties. Le signal indique une pression vendeuse modérée."
      elsif netflow_btc <= -2_000
        "Depuis le début de la journée, les sorties des exchanges dominent fortement. Le signal indique une accumulation importante."
      elsif netflow_btc <= -500
        "Depuis le début de la journée, les sorties des exchanges sont supérieures aux entrées. Le signal indique une accumulation modérée."
      else
        "Depuis le début de la journée, les entrées et sorties d’exchanges restent proches de l’équilibre."
      end
    end
  end
end