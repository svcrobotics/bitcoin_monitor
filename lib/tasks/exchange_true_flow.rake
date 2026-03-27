# frozen_string_literal: true

# lib/tasks/exchange_true_flow.rake
#
# Tasks liées au moteur "True Exchange Flow"
#
# Utilisation :
#   bin/rails exchange_true_flow:build_addresses
#   bin/rails exchange_true_flow:rebuild
#   bin/rails exchange_true_flow:rebuild_missing
#   bin/rails exchange_true_flow:rebuild_1y
#
require "json"

namespace :exchange_true_flow do
  # ------------------------------------------------------------
  # Helpers: JobRun wrapper
  # ------------------------------------------------------------
  def with_job_run!(name, meta: {})
    started = Time.current

    run = JobRun.create!(
      name: name,
      status: "running",
      started_at: started,
      meta: meta.to_json
    )

    exit_code = 0

    begin
      result = yield

      run.update!(
        status: "ok",
        finished_at: Time.current,
        duration_ms: ((Time.current - started) * 1000).to_i,
        exit_code: exit_code,
        meta: meta.merge(result: result).to_json
      )

      result
    rescue => e
      exit_code = 1

      run.update!(
        status: "fail",
        finished_at: Time.current,
        duration_ms: ((Time.current - started) * 1000).to_i,
        exit_code: exit_code,
        error: "#{e.class}: #{e.message}",
        meta: meta.to_json
      )

      raise
    end
  end

  # ------------------------------------------------------------
  # Build / refresh exchange address set
  # ------------------------------------------------------------
  desc "Build exchange address set from WhaleAlerts (DAYS_BACK=30, MIN_OCC=8)"
  task build_addresses: :environment do
    days_back = Integer(ENV.fetch("DAYS_BACK", "30")) rescue 30
    min_occ   = Integer(ENV.fetch("MIN_OCC", ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "8"))) rescue 8

    # Le builder lit EXCHANGE_ADDR_MIN_OCC
    ENV["EXCHANGE_ADDR_MIN_OCC"] = min_occ.to_s

    puts "▶ Building exchange address set..."
    puts "  days_back = #{days_back}"
    puts "  min_occ   = #{min_occ}"

    begin
      with_job_run!(
        "exchange_addr_build",
        meta: { days_back: days_back, min_occ: min_occ }
      ) do
        ExchangeAddressBuilder.call(days_back: days_back)
        { ok: true }
      end

      puts "✅ OK: exchange addresses built"
    rescue => e
      warn "❌ ERROR: #{e.class} #{e.message}"
      exit 1
    end
  end

  # ------------------------------------------------------------
  # Full rebuild (recalcul complet)
  # ------------------------------------------------------------
  desc "Rebuild true exchange inflow/outflow/netflow (DAYS_BACK=220)"
  task rebuild: :environment do
    days_back = Integer(ENV.fetch("DAYS_BACK", "220")) rescue 220

    puts "▶ Rebuilding TRUE exchange flow (full)"
    puts "  days_back = #{days_back}"

    begin
      with_job_run!(
        "true_flow_rebuild_manual",
        meta: { mode: "full", days_back: days_back }
      ) do
        TrueExchangeFlowRebuilder.call(days_back: days_back, only_missing: false)
        { ok: true }
      end

      puts "✅ OK: true flows rebuilt (full)"
    rescue => e
      warn "❌ ERROR: #{e.class} #{e.message}"
      exit 1
    end
  end

  # ------------------------------------------------------------
  # Missing-only rebuild
  # ------------------------------------------------------------
  desc "Rebuild only missing / nil days (DAYS_BACK=220)"
  task rebuild_missing: :environment do
    days_back = Integer(ENV.fetch("DAYS_BACK", "220")) rescue 220

    puts "▶ Rebuilding TRUE exchange flow (missing only)"
    puts "  days_back = #{days_back}"

    begin
      with_job_run!(
        "true_flow_rebuild",
        meta: { mode: "missing", days_back: days_back }
      ) do
        TrueExchangeFlowRebuilder.call(days_back: days_back, only_missing: true)
        { ok: true }
      end

      puts "✅ OK: true flows rebuilt (missing only)"
    rescue => e
      warn "❌ ERROR: #{e.class} #{e.message}"
      exit 1
    end
  end

  # ------------------------------------------------------------
  # Rebuild suffisant pour écrans 1 an
  # ------------------------------------------------------------
  desc "Rebuild enough history for 1Y dashboards (DAYS_BACK=420)"
  task rebuild_1y: :environment do
    days_back = Integer(ENV.fetch("DAYS_BACK", "420")) rescue 420

    puts "▶ Rebuilding TRUE exchange flow (1Y coverage)"
    puts "  days_back = #{days_back}"

    begin
      with_job_run!(
        "true_flow_rebuild_manual",
        meta: { mode: "1y", days_back: days_back }
      ) do
        TrueExchangeFlowRebuilder.call(days_back: days_back, only_missing: false)
        { ok: true }
      end

      puts "✅ OK: true flows rebuilt for 1Y"
    rescue => e
      warn "❌ ERROR: #{e.class} #{e.message}"
      exit 1
    end
  end

  # ------------------------------------------------------------
  # Rebuild ALL (overwrite) — plutôt manuel
  # ------------------------------------------------------------
  desc "Rebuild TRUE exchange flow (overwrite ALL rows) (DAYS_BACK=45)"
  task rebuild_all: :environment do
    days_back = Integer(ENV.fetch("DAYS_BACK", "45")) rescue 45
    min_occ   = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "8")) rescue 8

    ENV["EXCHANGE_ADDR_MIN_OCC"] = min_occ.to_s

    puts "▶ Rebuilding TRUE exchange flow (ALL)"
    puts "  days_back = #{days_back}"
    puts "  min_occ   = #{min_occ}"

    begin
      with_job_run!(
        "true_flow_rebuild_manual",
        meta: { mode: "all", days_back: days_back, min_occ: min_occ }
      ) do
        TrueExchangeFlowRebuilder.call(days_back: days_back, only_missing: false)
        { ok: true }
      end

      puts "✅ OK: true flows rebuilt (ALL)"
    rescue => e
      warn "❌ ERROR: #{e.class} #{e.message}"
      exit 1
    end
  end
end
