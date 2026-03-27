# frozen_string_literal: true

# lib/tasks/whales.rake
namespace :whales do
  desc "Scan whale alerts on last N blocks (default: 144)"
  task scan: :environment do
    n = Integer(ENV.fetch("N", "144"))

    JobRun.log!("whale_scan", meta: { last_n_blocks: n }.to_json) do
      puts "🐋 Whale scan starting (last #{n} blocks)…"
      ScanWhaleAlertsJob.perform_now(last_n_blocks: n)
      puts "✅ Whale scan done (last #{n} blocks)"
      { last_n_blocks: n }
    end
  rescue => e
    puts "❌ Whale scan failed: #{e.class} #{e.message}"
    raise
  end

  desc "Backfill whale alerts over a block height range (FROM=..., TO=..., STEP=144)"
  task backfill: :environment do
    from = Integer(ENV.fetch("FROM"))
    to   = Integer(ENV.fetch("TO"))
    step = Integer(ENV.fetch("STEP", "144")) rescue 144
    step = 1 if step <= 0

    if from > to
      abort("FROM must be <= TO (got FROM=#{from} TO=#{to})")
    end

    puts "🐋 Whale backfill starting…"
    puts "  range=#{from}..#{to} step=#{step}"

    # On scanne par chunks, du plus ancien au plus récent
    h = from
    while h <= to
      chunk_from = h
      chunk_to   = [h + step - 1, to].min

      puts "▶ scanning blocks #{chunk_from}..#{chunk_to}"

      # ✅ Nécessite ScanWhaleAlertsJob qui supporte from_height/to_height
      ScanWhaleAlertsJob.perform_now(from_height: chunk_from, to_height: chunk_to)

      h = chunk_to + 1
    end

    puts "✅ Whale backfill done"
  rescue KeyError => e
    puts "❌ Missing ENV: #{e.message}"
    puts "Usage: FROM=900000 TO=905000 STEP=144 bin/rails whales:backfill"
    raise
  rescue => e
    puts "❌ Whale backfill failed: #{e.class} #{e.message}"
    raise
  end

  desc "Backfill whale alerts for last DAYS days (DAYS=30, STEP=144). Uses RPC to find block heights by date."
  task backfill_days: :environment do
    days = Integer(ENV.fetch("DAYS", "30")) rescue 30
    days = 1 if days <= 0
    step = Integer(ENV.fetch("STEP", "144")) rescue 144

    rpc = BitcoinRpc.new

    # Cherche le block height ~ début de la période et la fin (aujourd'hui)
    start_day = Date.current - days
    end_day   = Date.current

    # On prend ~ midi pour éviter les bords (jour qui change)
    start_time = start_day.to_time.in_time_zone.change(hour: 12)
    end_time   = end_day.to_time.in_time_zone.change(hour: 12)

    start_height = height_for_time(rpc, start_time)
    end_height   = height_for_time(rpc, end_time)

    puts "🐋 Whale backfill_days starting…"
    puts "  days=#{days} start_day=#{start_day} end_day=#{end_day}"
    puts "  heights=#{start_height}..#{end_height} step=#{step}"

    ENV["FROM"] = start_height.to_s
    ENV["TO"]   = end_height.to_s
    ENV["STEP"] = step.to_s

    Rake::Task["whales:backfill"].invoke
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

  desc "Reclassify whale alerts for last 7 days (no RPC)"
  task reclassify_last_7d: :environment do
    puts "🔁 whales:reclassify_last_7d"
    ReclassifyWhaleAlertsJob.perform_now(days_back: 7)
    puts "✅ whales:reclassify_last_7d done"
  rescue => e
    puts "❌ whales:reclassify_last_7d failed: #{e.class} #{e.message}"
    raise
  end

  desc "Reclassify whale alerts for last N days (no RPC). Usage: N=30 bin/rails whales:reclassify_last_nd"
  task reclassify_last_nd: :environment do
    n = Integer(ENV.fetch("N", "7")) rescue 7
    n = 1 if n <= 0
    puts "🔁 whales:reclassify_last_nd n=#{n}"
    ReclassifyWhaleAlertsJob.perform_now(days_back: n)
    puts "✅ whales:reclassify_last_nd done"
  rescue => e
    puts "❌ whales:reclassify_last_nd failed: #{e.class} #{e.message}"
    raise
  end

  desc "Reclassify whale alerts in height range (no RPC). Usage: FROM=... TO=... bin/rails whales:reclassify_range"
  task reclassify_range: :environment do
    from = Integer(ENV.fetch("FROM"))
    to   = Integer(ENV.fetch("TO"))

    if from > to
      abort("FROM must be <= TO (got FROM=#{from} TO=#{to})")
    end

    puts "🔁 whales:reclassify_range #{from}..#{to}"
    ReclassifyWhaleAlertsJob.perform_now(from_height: from, to_height: to)
    puts "✅ whales:reclassify_range done"
  rescue KeyError => e
    puts "❌ Missing ENV: #{e.message}"
    puts "Usage: FROM=938400 TO=938600 bin/rails whales:reclassify_range"
    raise
  rescue => e
    puts "❌ whales:reclassify_range failed: #{e.class} #{e.message}"
    raise
  end

  desc "Reclassify only alerts missing reclass_version or flow_kind (no RPC)"
  task reclassify_missing: :environment do
    scope = WhaleAlert.where(flow_kind: nil).or(WhaleAlert.where("meta->>'reclass_version' IS NULL"))
    puts "🔁 whales:reclassify_missing count=#{scope.count}"
    ids = scope.pluck(:txid) # simple
    ReclassifyWhaleAlertsJob.perform_now(since_time: 100.years.ago) if ids.any? # ou fais une version du job qui prend txids
  end

  # ---------------------------
  # Helpers
  # ---------------------------
  def height_for_time(rpc, target_time)
    chain = rpc.get_blockchain_info
    hi = chain["blocks"].to_i
    lo = 0

    target = target_time.to_i
    best = hi

    while lo <= hi
      mid = (lo + hi) / 2
      hash = rpc.getblockhash(mid)

      # ✅ on évite getblockheader (pas exposé dans ton wrapper)
      blk = rpc.getblock(hash)
      t   = blk["time"].to_i

      if t >= target
        best = mid
        hi = mid - 1
      else
        lo = mid + 1
      end
    end

    best
  end

end
