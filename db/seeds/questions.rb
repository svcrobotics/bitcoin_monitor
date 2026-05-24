questions = [
  {
    key: "exchange_selling_pressure_today",
    module_name: "exchange_flows",
    tier: "free",
    question: "Le marché est-il sous pression vendeuse aujourd’hui ?",
    intent: "selling_pressure",
    answer_service: "ExchangeFlows::Questions::SellingPressureToday",
    historical_path: "/exchange-flows/history",
    position: 10
  },
  {
    key: "exchange_netflow_direction_today",
    module_name: "exchange_flows",
    tier: "free",
    question: "Les BTC entrent-ils ou sortent-ils des exchanges aujourd’hui ?",
    intent: "netflow_direction",
    answer_service: "ExchangeFlows::Questions::NetflowDirectionToday",
    historical_path: "/exchange-flows/history",
    position: 20
  },
  {
    key: "exchange_accumulation_today",
    module_name: "exchange_flows",
    tier: "free",
    question: "Les investisseurs semblent-ils accumuler actuellement ?",
    intent: "accumulation_signal",
    answer_service: "ExchangeFlows::Questions::AccumulationSignalToday",
    historical_path: "/exchange-flows/history",
    position: 30
  }
]

questions.each do |attrs|
  QuestionDefinition.find_or_initialize_by(key: attrs[:key]).update!(attrs)
end