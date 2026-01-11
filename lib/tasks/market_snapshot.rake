# frozen_string_literal: true

namespace :market do
  desc "Compute and store daily MarketSnapshot (macro context)"
  task snapshot: :environment do
    snap = MarketSnapshotBuilder.call

    if snap.persisted?
      puts "OK: MarketSnapshot saved at #{snap.computed_at} (status=#{snap.status})"
    else
      puts "WARN: MarketSnapshot not saved (validation?)"
      puts snap.errors.full_messages.join("\n")
      exit 1
    end
  end
end
