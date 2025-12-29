# lib/tasks/whales.rake
namespace :whales do
  desc "Scan whale alerts on last N blocks (default 144)"
  task scan: :environment do
    n = (ENV["N"] || "144").to_i
    ScanWhaleAlertsJob.perform_now(last_n_blocks: n)
    puts "✅ Whale scan done (last #{n} blocks)"
  end

  desc "Purge whale alerts older than DAYS (default 7)"
  task purge: :environment do
    days   = (ENV["DAYS"] || "7").to_i
    cutoff = Time.current - days.days

    n = WhaleAlert.where("block_time < ? OR block_time IS NULL", cutoff).delete_all
    puts "🧹 purged=#{n} older_than=#{days}d"
  end
end
