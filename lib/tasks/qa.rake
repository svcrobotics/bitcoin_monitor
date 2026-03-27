# frozen_string_literal: true

namespace :qa do
  desc "Run cluster V3 RSpec suite and export JSON report"
  task cluster_v3: :environment do
    FileUtils.mkdir_p(Rails.root.join("tmp/qa"))

    cmd = [
      "bundle exec rspec",
      "spec/services/cluster_aggregator_spec.rb",
      "spec/services/cluster_metrics_builder_spec.rb",
      "spec/services/cluster_signal_engine_spec.rb",
      "spec/requests/address_lookup_spec.rb",
      "spec/requests/address_lookup_edge_cases_spec.rb",
      "spec/requests/cluster_signals_spec.rb",
      "--format progress",
      "--format json --out tmp/qa/cluster_v3_rspec.json"
    ].join(" ")

    puts "[qa:cluster_v3] #{cmd}"
    ok = system(cmd)

    abort("[qa:cluster_v3] failed") unless ok

    puts "[qa:cluster_v3] report written to tmp/qa/cluster_v3_rspec.json"
  end
end