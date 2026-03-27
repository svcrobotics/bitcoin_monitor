# frozen_string_literal: true

require "open3"
require "fileutils"

class SystemTestRunner
  Result = Struct.new(:ok?, :output, :status, keyword_init: true)

  REPORT_DIR  = Rails.root.join("tmp/qa")
  JSON_REPORT = REPORT_DIR.join("cluster_v3_rspec.json")
  LOG_REPORT  = REPORT_DIR.join("cluster_v3_last_run.log")

  def self.call
    new.call
  end

  def call
    FileUtils.mkdir_p(REPORT_DIR)

    cmd = [
      "RAILS_ENV=test",
      "bundle exec rspec",
      "spec/services/cluster_aggregator_spec.rb",
      "spec/services/cluster_metrics_builder_spec.rb",
      "spec/services/cluster_signal_engine_spec.rb",
      "spec/services/cluster_scanner_spec.rb",
      "spec/requests/address_lookup_spec.rb",
      "spec/requests/address_lookup_edge_cases_spec.rb",
      "spec/requests/cluster_signals_spec.rb",
      "spec/requests/system_spec.rb",
      "spec/tasks/cluster_v3_tasks_spec.rb",
      "spec/system/cron_v3_spec.rb",
      "--format progress",
      "--format json --out #{JSON_REPORT}"
    ].join(" ")

    stdout, stderr, status = Open3.capture3(cmd, chdir: Rails.root.to_s)
    output = [stdout, stderr].reject(&:blank?).join("\n")

    File.write(LOG_REPORT, output)

    Result.new(
      ok?: status.success?,
      output: output,
      status: status.exitstatus
    )
  end
end