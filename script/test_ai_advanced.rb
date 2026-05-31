context = {
  market_summary: {
    price_change_24h_pct: -2.4,
    volatility: "élevée",
    market_phase: "correction court terme"
  },

  dominant_signal: {
    module: "exchange_flow",
    signal: "Pression vendeuse forte",
    direction: "bearish",
    importance: 94,
    confidence: 91
  },

  watch_priority: {
    module: "exchange_flow",
    reason: "Signal dominant avec importance 94 et confidence 91",
    watch: "Surveiller si le netflow_btc reste fortement positif"
  },

  signals: {
    exchange_flow: {
      signal: "Pression vendeuse forte",
      direction: "bearish",
      importance: 94,
      confidence: 91,
      netflow_btc: 28_500
    },

    whales: {
      signal: "Accumulation modérée",
      direction: "bullish",
      importance: 72,
      confidence: 78
    },

    etf_flows: {
      signal: "Entrées ETF importantes",
      direction: "bullish",
      importance: 84,
      confidence: 93
    }
  }
}

puts Intelligence::UserAssistant.call(
  question: "Explique la situation actuelle et ce qu'il faut surveiller en priorité.",
  context: context
)
