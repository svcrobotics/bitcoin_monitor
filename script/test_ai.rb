# script/test_ai.rb

context = {
  exchange_flow: {
    signal: "Pression vendeuse forte",
    inflow_btc: 15000,
    outflow_btc: 2000,
    netflow_btc: 13000
  },

  whales: {
    signal: "Ventes importantes détectées"
  },

  btc_price: {
    change_24h_pct: -4.5
  }
}

puts Intelligence::UserAssistant.call(
  question: "Pourquoi le Bitcoin baisse aujourd'hui ?",
  context: context
)