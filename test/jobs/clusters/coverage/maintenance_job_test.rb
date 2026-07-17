# frozen_string_literal: true

require "test_helper"

module Clusters
  module Coverage
    class MaintenanceJobTest <
      ActiveJob::TestCase

      test "is disabled by default" do
        previous =
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ]

        ENV.delete(
          "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
        )

        result =
          MaintenanceJob.perform_now(
            {
              "reschedule" => false,
              "lock" => false
            }
          )

        assert_equal true, result[:ok]
        assert_equal "disabled", result[:status]
      ensure
        if previous.nil?
          ENV.delete(
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          )
        else
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ] = previous
        end
      end

      test "runs backfill normal coverage and reconciliation" do
        previous =
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ]

        ENV[
          "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
        ] = "1"

        backfill_calls = []
        runner_calls = []

        backfill =
          lambda do |**arguments|
            backfill_calls << arguments

            {
              ok: true,
              addresses_upserted: 4,
              from_height: 955_300,
              to_height: 955_301
            }
          end

        runner =
          lambda do |**arguments|
            runner_calls << arguments

            {
              ok: true,
              singleton_clusters_created:
                arguments[:reconcile] ? 2 : 3
            }
          end

        health = {
          status: "completed",
          address_id_lag: 0,
          null_addresses_after_cursor: 0
        }

        coverage = {
          complete: true,
          from_height: 955_300,
          to_height: 955_301
        }

        result = nil

        with_stubbed(
          InputAddressBackfill,
          :call,
          backfill
        ) do
          with_stubbed(
            AddressRunner,
            :call,
            runner
          ) do
            with_stubbed(
              AddressHealthSnapshot,
              :call,
              health
            ) do
              with_stubbed(
                OperationalSnapshot,
                :refresh,
                coverage
              ) do
                with_stubbed(
                  System::PipelineController,
                  :decision,
                  { allowed: true }
                ) do
                  result =
                    MaintenanceJob.perform_now(
                      {
                        "reschedule" => false,
                        "lock" => false
                      }
                    )
                end
              end
            end
          end
        end

        assert_equal true, result[:ok]
        assert_equal "completed", result[:status]
        assert_equal true, backfill_calls.first[:lock]
        assert_equal 2, runner_calls.size
        assert_equal false, runner_calls[0][:reconcile]
        assert_equal true, runner_calls[1][:reconcile]
        assert_equal 0, result.dig(:health, :address_id_lag)
      ensure
        if previous.nil?
          ENV.delete(
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          )
        else
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ] = previous
        end
      end

      private

      def with_stubbed(object, method_name, value = nil)
        original = object.method(method_name)
        replacement =
          if value.respond_to?(:call)
            value
          else
            ->(*_args, **_kwargs) { value }
          end

        object.define_singleton_method(method_name, &replacement)

        yield
      ensure
        object.define_singleton_method(method_name) do |*args, **kwargs, &block|
          original.call(*args, **kwargs, &block)
        end
      end
    end
  end
end
