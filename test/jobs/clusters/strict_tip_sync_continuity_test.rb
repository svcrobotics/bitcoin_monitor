# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class StrictTipSyncContinuityTest < ActiveSupport::TestCase
    test "scheduler enables continuous Cluster wakeups" do
      spec =
        StrictPipeline::Scheduler::JOBS.find do |job_spec|
          job_spec.name == :cluster
        end

      assert_not_nil spec
      assert_equal true, spec.args.first[:reschedule]
    end

    test "successful Cluster slice wakes scheduler after releasing locks" do
      job = Clusters::StrictTipSyncJob.new

      events = []
      wakeups = []

      options = {
        "limit" => 2,
        "reschedule" => true,
        "strict_io_token" => "cluster-test-token",
        "strict_io_owner" => "cluster"
      }

      sync_result = {
        ok: true,
        status: "processed",
        from_height: 100,
        to_height: 101
      }

      wakeup =
        lambda do |reason:, wait:|
          events << :scheduler_wakeup

          wakeups << {
            reason: reason,
            wait: wait
          }

          {
            requested: true,
            enqueued: true,
            duplicate: false,
            reason: reason
          }
        end

      release_job_lock =
        lambda do |_token|
          events << :job_lock_released
          nil
        end

      release_strict_io =
        lambda do |*_, **_kwargs|
          events << :strict_io_released
          true
        end

      StrictPipeline::StrictIoLease.stub(:renew, true) do
        StrictPipeline::StrictIoLease.stub(
          :release,
          release_strict_io
        ) do
          System::PipelineController.stub(
            :decision,
            {
              allowed: true,
              state: :runnable,
              failed_constraints: []
            }
          ) do
            Clusters::StrictTipSyncer.stub(
              :call,
              sync_result
            ) do
              StrictPipeline::SchedulerWakeup.stub(
                :request!,
                wakeup
              ) do
                job.stub(:acquire_lock, true) do
                  job.stub(:clear_schedule_marker, nil) do
                    job.stub(
                      :release_lock,
                      release_job_lock
                    ) do
                      result = job.perform(options)

                      assert_equal(
                        true,
                        result.dig(
                          :automation,
                          :reschedule
                        )
                      )

                      assert_equal(
                        true,
                        result.dig(
                          :automation,
                          :scheduler_wakeup_after_release
                        )
                      )

                      assert_equal(
                        0,
                        result.dig(
                          :automation,
                          :scheduler_wakeup_wait_seconds
                        )
                      )
                    end
                  end
                end
              end
            end
          end
        end
      end

      assert_equal(
        [
          :job_lock_released,
          :strict_io_released,
          :scheduler_wakeup
        ],
        events
      )

      assert_equal 1, wakeups.size
      assert_equal "cluster_finished", wakeups.first[:reason]
      assert_equal 0, wakeups.first[:wait].to_i
    end
  end
end
