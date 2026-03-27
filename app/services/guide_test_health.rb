# frozen_string_literal: true

class GuideTestHealth
  MODULES = {
    "inflow-outflow" => {
      doc_path: "docs/modules/inflow_outflow",
      test_patterns: [
        "test/**/*inflow_outflow*",
        "test/**/*exchange_observed*",
        "test/**/*true_flow*"
      ]
    },

    "whales" => {
      doc_path: "docs/modules/whales",
      test_patterns: [
        "test/**/*whale*"
      ]
    },

    "cluster" => {
      doc_path: "docs/modules/cluster",
      test_patterns: [
        "test/**/*cluster*",
        "test/**/*address_link*",
        "test/**/*cluster_metric*"
      ]
    }
  }.freeze

  def self.for(guide)
    return nil unless guide

    key = guide.slug.to_s
    config = MODULES[key]
    return nil unless config

    new(config).call
  end

  def initialize(config)
    @config = config
  end

  def call
    {
      tests_doc_present: tests_doc_present?,
      test_files: test_files,
      status: compute_status
    }
  end

  private

  def tests_doc_present?
    Dir.glob(File.join(@config[:doc_path], "v*/tests.md")).any?
  end

  def test_files
    @test_files ||= @config[:test_patterns].flat_map do |pattern|
      Dir.glob(pattern)
    end.uniq
  end

  def compute_status
    has_doc   = tests_doc_present?
    has_tests = test_files.any?

    return :ok if has_doc && has_tests
    return :warn if has_doc || has_tests

    :missing
  end
end