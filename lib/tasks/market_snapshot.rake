# frozen_string_literal: true
require "json"

namespace :market do
  desc "Compute and store daily MarketSnapshot (macro context)"
  task snapshot: :environment do
    name    = "market_snapshot"
    started = Time.current

    run = JobRun.create!(
      name: name,
      status: "running",
      started_at: started
    )

    exit_code = 0

    begin
      snap = MarketSnapshotBuilder.call

      if snap.persisted?
        puts "OK: MarketSnapshot saved at #{snap.computed_at} (status=#{snap.status})"

        run.update!(
          status: "ok",
          finished_at: Time.current,
          duration_ms: ((Time.current - started) * 1000).to_i,
          exit_code: exit_code,
          meta: {
            snapshot_id: snap.id,
            computed_at: snap.computed_at,
            status: snap.status
          }.to_json
        )
      else
        exit_code = 1
        msg = "MarketSnapshot not saved (validation?)"
        warn "WARN: #{msg}"
        warn snap.errors.full_messages.join("\n")

        run.update!(
          status: "fail",
          finished_at: Time.current,
          duration_ms: ((Time.current - started) * 1000).to_i,
          exit_code: exit_code,
          error: msg,
          meta: {
            errors: snap.errors.full_messages
          }.to_json
        )

        exit 1
      end
    rescue => e
      exit_code = 1
      warn "❌ ERROR: #{e.class} #{e.message}"

      run.update!(
        status: "fail",
        finished_at: Time.current,
        duration_ms: ((Time.current - started) * 1000).to_i,
        exit_code: exit_code,
        error: "#{e.class}: #{e.message}"
      )

      exit 1
    end
  end
end
