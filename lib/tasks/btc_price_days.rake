# lib/tasks/btc_price_days.rake
namespace :btc_price_days do
  desc "Catch up missing BTC price days until yesterday"
  task catchup: :environment do
    date = Date.current

    JobRunner.run!("btc_price_days_catchup", meta: { date: date }, triggered_by: "cron") do |jr|
      JobRunner.heartbeat!(jr)

      puts "[btc_price_days:catchup] start date=#{date}"

      result = BtcPriceDaysCatchup.call

      JobRunner.heartbeat!(jr)

      puts "[btc_price_days:catchup] from=#{result[:from]} to=#{result[:to]} built=#{result[:built]} ok=#{result[:ok]}"

      if result[:errors].present?
        result[:errors].each do |err|
          puts "[btc_price_days:catchup] day=#{err[:day]} error=#{err[:error]}"
        end

        raise "catchup failed"
      end

      puts "[btc_price_days:catchup] done"

      jr.update!(
        meta: { date: date }.merge(result: result).to_json
      )

      result
    end
  end
end