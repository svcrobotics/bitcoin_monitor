# lib/tasks/btc_price_days.rake
namespace :btc_price_days do
  desc "Catch up missing BTC price days until yesterday"
  task catchup: :environment do
    date = Date.current

    JobRun.log!("btc_price_days_catchup", meta: { date: date }.to_json) do
      puts "[btc_price_days:catchup] start date=#{date}"

      result = BtcPriceDaysCatchup.call

      puts "[btc_price_days:catchup] from=#{result[:from]} to=#{result[:to]} built=#{result[:built]} ok=#{result[:ok]}"

      if result[:errors].present?
        result[:errors].each do |err|
          puts "[btc_price_days:catchup] day=#{err[:day]} error=#{err[:error]}"
        end

        raise "catchup failed"
      end

      puts "[btc_price_days:catchup] done"

      result
    end
  end
end