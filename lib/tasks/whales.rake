# lib/tasks/whales.rake
namespace :whales do
  desc "Scan whale alerts on last N blocks (default: 144)"
  task scan: :environment do
    n = (ENV["N"] || 144).to_i
    n = 1 if n <= 0

    puts "🐋 Whale scan starting (last #{n} blocks)…"

    ScanWhaleAlertsJob.perform_now(last_n_blocks: n)

    puts "✅ Whale scan done (last #{n} blocks)"
  rescue => e
    puts "❌ Whale scan failed: #{e.class} #{e.message}"
    raise
  end

  desc "Purge whale alerts older than DAYS (default: 7). Use DRY_RUN=1 to preview."
  task purge: :environment do
    days = (ENV["DAYS"] || 7).to_i
    days = 1 if days <= 0

    dry_run = ENV["DRY_RUN"].present?
    cutoff  = Time.current - days.days

    scope = WhaleAlert.where("block_time < ? OR block_time IS NULL", cutoff)

    count = scope.count

    if dry_run
      puts "🧪 DRY RUN — would purge #{count} whale alerts older than #{days} days"
    else
      deleted = scope.delete_all
      puts "🧹 purged=#{deleted} older_than=#{days}d"
    end
  end

  desc "Recompute exchange_likelihood for alerts where it is NULL"
  task recompute_exchange: :environment do
    scope = WhaleAlert.where(exchange_likelihood: nil)

    puts "🔁 Recomputing exchange_likelihood for #{scope.count} alerts…"

    scope.find_each(batch_size: 100) do |a|
      metrics = {
        total_out_btc: a.total_out_btc,
        inputs_count: a.inputs_count,
        outputs_count: a.outputs_count,
        outputs_nonzero_count: a.outputs_nonzero_count,
        largest_output_btc: a.largest_output_btc
      }

      classified = WhaleAlertClassifier.call(metrics)
      next unless classified

      a.update!(
        exchange_likelihood: classified[:exchange_likelihood],
        exchange_hint: classified[:exchange_hint],
        meta: (a.meta || {}).merge(classified[:meta])
      )
    end

    puts "✅ Recompute done"
  end
end
