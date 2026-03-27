# frozen_string_literal: true

require "json"

class ModuleSpecResultsLoader
  BASE_PATH = Rails.root.join("tmp/qa")

  def self.for(module_slug, version)
    new(module_slug, version).call
  end

  def initialize(module_slug, version)
    @module_slug = module_slug.to_s.tr("-", "_")
    @version = version.to_s
  end

  def call
    return nil unless File.exist?(report_path)

    raw = JSON.parse(File.read(report_path))
    examples = Array(raw["examples"])

    grouped = examples.group_by do |example|
      file_path = example["file_path"].to_s
      File.basename(file_path, "_spec.rb")
    end

    entries = grouped.map do |component_key, component_examples|
      first = component_examples.first || {}
      file_path = first["file_path"].to_s

      {
        component_key: component_key,
        component_name: human_component_name(component_key),
        file_path: file_path,
        command: "bundle exec rspec ./#{file_path}",
        summary: summary_for(component_examples),
        status: status_for(component_examples),
        examples: component_examples.map do |example|
          {
            description: example["full_description"].to_s,
            short_description: example["description"].to_s,
            status: normalize_status(example["status"]),
            run_time: example["run_time"]
          }
        end
      }
    end.sort_by { |entry| entry[:component_name] }

    {
      module: @module_slug,
      version: @version,
      generated_at: file_mtime,
      summary: global_summary(raw, examples),
      entries: entries,
      status: global_status(entries, raw)
    }
  rescue JSON::ParserError
    nil
  end

  private

  def report_path
    BASE_PATH.join("#{@module_slug}_#{@version}.json")
  end

  def file_mtime
    File.mtime(report_path)
  rescue
    nil
  end

  def summary_for(examples)
    total = examples.size
    passed = examples.count { |e| e["status"].to_s == "passed" }
    failed = examples.count { |e| e["status"].to_s == "failed" }
    pending = examples.count { |e| e["status"].to_s == "pending" }

    {
      total: total,
      passed: passed,
      failed: failed,
      pending: pending,
      label: "#{passed}/#{total} OK"
    }
  end

  def status_for(examples)
    return :fail if examples.any? { |e| e["status"].to_s == "failed" }
    return :warn if examples.any? { |e| e["status"].to_s == "pending" }
    :ok
  end

  def normalize_status(value)
    case value.to_s
    when "passed" then :ok
    when "failed" then :fail
    when "pending" then :warn
    else :unknown
    end
  end

  def global_summary(raw, examples)
    summary_line = raw["summary"] || {}

    {
      total_examples: summary_line["example_count"] || examples.size,
      total_failures: summary_line["failure_count"] || examples.count { |e| e["status"].to_s == "failed" },
      total_pending: summary_line["pending_count"] || examples.count { |e| e["status"].to_s == "pending" },
      duration: summary_line["duration"]
    }
  end

  def global_status(entries, raw)
    failure_count = raw.dig("summary", "failure_count").to_i
    pending_count = raw.dig("summary", "pending_count").to_i

    return :fail if failure_count.positive?
    return :warn if pending_count.positive?
    return :missing if entries.empty?

    :ok
  end

  def human_component_name(component_key)
    component_key.to_s
      .split("_")
      .map(&:capitalize)
      .join
  end
end