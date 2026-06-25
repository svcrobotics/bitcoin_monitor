# frozen_string_literal: true

require "test_helper"

module Clusters
  module Coverage
    class IncrementalJobTest < ActiveJob::TestCase
      test "is disabled by default and does not enqueue follow up work" do
        previous =
          ENV["CLUSTER_COVERAGE_INCREMENTAL_ENABLED"]

        ENV.delete("CLUSTER_COVERAGE_INCREMENTAL_ENABLED")

        result =
          Clusters::Coverage::IncrementalJob
            .perform_now

        assert_equal true, result[:ok]
        assert_equal "disabled", result[:status]
        assert_equal false, result[:rescheduled]
      ensure
        if previous.nil?
          ENV.delete("CLUSTER_COVERAGE_INCREMENTAL_ENABLED")
        else
          ENV["CLUSTER_COVERAGE_INCREMENTAL_ENABLED"] = previous
        end
      end

      test "source does not schedule itself" do
        source =
          Rails.root.join(
            "app/jobs/clusters/coverage/incremental_job.rb"
          ).read

        refute_match(/perform_later/, source)
        refute_match(/set\(wait:/, source)
        refute_match(/perform_in/, source)
      end
    end
  end
end
