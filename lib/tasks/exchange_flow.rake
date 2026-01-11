# lib/tasks/exchange_flow.rake
namespace :exchange_flow do
  desc "Rebuild exchange inflow (estimated) baselines from WhaleAlerts"
  task rebuild: :environment do
    ExchangeInflowRebuilder.call(days_back: 220)
    puts "OK: ExchangeFlow rebuilt."
  end
end
