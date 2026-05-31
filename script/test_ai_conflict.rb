context = {
  exchange_flow: {
    signal: "Pression vendeuse forte",
    direction: "bearish",
    importance: 90,
    confidence: 92,
    netflow_btc: 25_000,
    explanation: "Les entrées vers les exchanges dépassent largement les sorties."
  },

  whales: {
    signal: "Accumulation forte",
    direction: "bullish",
    importance: 85,
    confidence: 88,
    explanation: "Les acteurs whale_like augmentent leurs positions."
  },

  etf_flows: {
    signal: "Entrées ETF importantes",
    direction: "bullish",
    importance: 80,
    confidence: 95,
    explanation: "Les ETF absorbent une partie importante de l'offre disponible."
  },

  btc_price: {
    signal: "Correction modérée",
    direction: "bearish",
    importance: 70,
    confidence: 99,
    change_24h_pct: -1.2
  }
}
puts Intelligence::UserAssistant.call(
  question: "Pourquoi le marché est-il contradictoire aujourd'hui ?",
  context: context
)
puts Intelligence::UserAssistant.call(
  question: "Quel signal doit-on surveiller en priorité maintenant ?",
  context: context
)