# lib/tasks/exchange_true_flow.rake
namespace :exchange_true_flow do
  desc "Build exchange address set from WhaleAlerts"
  task build_addresses: :environment do
    ExchangeAddressBuilder.call(days_back: 30)
    puts "OK: exchange addresses built."
  end

  desc "Rebuild true exchange inflow/outflow/netflow"
  task rebuild: :environment do
    ExchangeTrueFlowRebuilder.call(days_back: 220)
    puts "OK: true flows rebuilt."
  end
end
