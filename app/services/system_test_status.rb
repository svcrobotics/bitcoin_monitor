# frozen_string_literal: true

require "json"

class SystemTestStatus
  REPORT_PATH = Rails.root.join("tmp/qa/cluster_v3_rspec.json")

  MODULES = [
    {
      key: "cluster_aggregator",
      label: "ClusterAggregator",
      files: ["./spec/services/cluster_aggregator_spec.rb"]
    },
    {
      key: "cluster_metrics_builder",
      label: "ClusterMetricsBuilder",
      files: ["./spec/services/cluster_metrics_builder_spec.rb"]
    },
    {
      key: "cluster_signal_engine",
      label: "ClusterSignalEngine",
      files: ["./spec/services/cluster_signal_engine_spec.rb"]
    },
    {
      key: "cluster_scanner",
      label: "ClusterScanner",
      files: ["./spec/services/cluster_scanner_spec.rb"]
    },
    {
      key: "address_lookup",
      label: "AddressLookup",
      files: ["./spec/requests/address_lookup_spec.rb"]
    },
    {
      key: "address_lookup_edge_cases",
      label: "AddressLookup edge cases",
      files: ["./spec/requests/address_lookup_edge_cases_spec.rb"]
    },
    {
      key: "cluster_signals_pages",
      label: "ClusterSignals pages",
      files: ["./spec/requests/cluster_signals_spec.rb"]
    },
    {
      key: "system_page",
      label: "/system",
      files: ["./spec/requests/system_spec.rb"]
    },
    {
      key: "v3_rake_tasks",
      label: "Tâches rake V3",
      files: ["./spec/tasks/cluster_v3_tasks_spec.rb"]
    },
    {
      key: "v3_cron",
      label: "Cron V3",
      files: ["./spec/system/cron_v3_spec.rb"]
    }
  ].freeze

  def self.summary
    new.summary
  end

  def self.groups
    new.groups
  end

  def initialize
    @report = load_report
  end

  def summary
    items = groups.flat_map { |g| g[:items] }

    {
      green: items.count { |i| i[:status] == :green },
      orange: items.count { |i| i[:status] == :orange },
      gray: items.count { |i| i[:status] == :gray },
      total: items.size,
      generated_at: report_generated_at
    }
  end

  def groups
    [
      {
        key: "cluster_services",
        title: "Cluster — Services",
        items: [
          module_status("cluster_aggregator"),
          module_status("cluster_metrics_builder"),
          module_status("cluster_signal_engine")
        ]
      },
      {
        key: "cluster_ui",
        title: "Cluster — UI",
        items: [
          module_status("address_lookup"),
          module_status("address_lookup_edge_cases"),
          module_status("cluster_signals_pages")
        ]
      },
      {
        key: "cluster_ops",
        title: "Cluster — Ops / Pipeline",
        items: [
          module_status("cluster_scanner"),
          module_status("system_page"),
          module_status("v3_rake_tasks"),
          module_status("v3_cron")
        ]
      }
    ]
  end

  def global_stats
    return {} unless report.present?

    summary = report["summary"]

    {
      examples: summary["example_count"],
      failures: summary["failure_count"],
      duration: summary["duration"]
    }
  end

  private

  attr_reader :report

  

  def load_report
    return nil unless File.exist?(REPORT_PATH)

    JSON.parse(File.read(REPORT_PATH))
  rescue JSON::ParserError
    nil
  end

  def report_generated_at
    return nil unless File.exist?(REPORT_PATH)

    File.mtime(REPORT_PATH)
  end

  def module_status(key)
    mod = MODULES.find { |m| m[:key] == key }
    examples = examples_for_files(mod[:files])

    if report.nil?
      return {
        key: mod[:key],
        label: mod[:label],
        status: :gray,
        coverage: "Aucun rapport RSpec disponible",
        command: nil
      }
    end

    if examples.empty?
      return {
        key: mod[:key],
        label: mod[:label],
        status: :orange,
        coverage: "Rapport présent, mais aucun exemple trouvé pour ce module",
        command: command_for(mod[:files])
      }
    end

    failed = examples.count { |e| e["status"] == "failed" }
    passed = examples.count { |e| e["status"] == "passed" }
    total  = examples.size

    status =
      if failed.zero? && passed == total
        :green
      elsif passed.positive?
        :orange
      else
        :orange
      end

    {
      key: mod[:key],
      label: mod[:label],
      status: status,
      coverage: "#{passed}/#{total} exemples verts#{failed.positive? ? " • #{failed} échec(s)" : ""}",
      command: command_for(mod[:files])
    }
  end

  def examples_for_files(files)
    return [] unless report.present?

    Array(report["examples"]).select do |example|
      files.include?(example["file_path"])
    end
  end

  def command_for(files)
    "bundle exec rspec #{files.join(' ')}"
  end

  def static_item(key, label, status, coverage)
    {
      key: key,
      label: label,
      status: status,
      coverage: coverage,
      command: nil
    }
  end
end