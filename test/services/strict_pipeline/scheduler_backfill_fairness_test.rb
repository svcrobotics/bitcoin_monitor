# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class SchedulerBackfillFairnessTest <
    ActiveSupport::TestCase

    test "cluster acquires strict io first above the backfill margin" do
      enqueued =
        run_scheduler(
          cluster_lag:
            System::PipelineController::
              ACTOR_PROFILE_MAX_CLUSTER_LAG + 1
        )

      assert_equal(
        [
          [
            :cluster,
            "cluster"
          ]
        ],
        enqueued
      )
    end

    test "layer1 keeps normal priority at the backfill margin" do
      enqueued =
        run_scheduler(
          cluster_lag:
            System::PipelineController::
              ACTOR_PROFILE_MAX_CLUSTER_LAG
        )

      assert_equal(
        [
          [
            :layer1,
            "layer1"
          ]
        ],
        enqueued
      )
    end

    test "realtime mode keeps layer1 first regardless of relative lag" do
      enqueued =
        run_scheduler(
          cluster_lag:
            20,
          pipeline_mode:
            "realtime"
        )

      assert_equal(
        [
          [
            :layer1,
            "layer1"
          ]
        ],
        enqueued
      )
    end

    test "existing strict io owner prevents a second strict owner" do
      enqueued =
        run_scheduler(
          cluster_lag:
            System::PipelineController::
              ACTOR_PROFILE_MAX_CLUSTER_LAG + 1,
          strict_io_owner:
            "layer1"
        )

      assert_empty enqueued
    end

    private

    def run_scheduler(
      cluster_lag:,
      pipeline_mode:
        "development_backfill",
      strict_io_owner:
        nil
    )
      snapshot = {
        cluster: {
          lag:
            cluster_lag
        }
      }

      scheduler =
        Scheduler.new

      scheduler.define_singleton_method(
        :publish_runtime_status
      ) do
        true
      end

      scheduler.define_singleton_method(
        :ensure_actor_labels_worker_capability
      ) do
        true
      end

      scheduler.define_singleton_method(
        :run_anomaly_watchdog
      ) do
        {
          ok: true
        }
      end

      scheduler.define_singleton_method(
        :active_count
      ) do |_queue|
        0
      end

      scheduler.define_singleton_method(
        :queued_count
      ) do |_queue|
        0
      end

      scheduler.define_singleton_method(
        :scheduled_count
      ) do |_queue|
        0
      end

      scheduler.define_singleton_method(
        :strict_lock_present?
      ) do |spec|
        strict_io_owner.present? &&
          %i[
            layer1
            cluster
          ].include?(
            spec.name
          )
      end

      enqueued = []

      scheduler.define_singleton_method(
        :enqueue
      ) do |spec, lease: nil|
        enqueued << [
          spec.name,
          lease&.owner
        ]
      end

      lease_for =
        lambda do |owner|
          StrictPipeline::
            StrictIoLease::
            Lease.new(
              owner:
                owner.to_s,
              token:
                "#{owner}-token",
              acquired_at:
                Time.current,
              expires_at:
                2.minutes.from_now
            )
        end

      current_lease =
        strict_io_owner.present? ?
          lease_for.call(strict_io_owner) :
          nil

      decisions =
        lambda do |name, current_snapshot: nil|
          if %i[
            layer1
            cluster
          ].include?(name)
            {
              module:
                name == :layer1 ?
                  :layer1_realtime :
                  :cluster,

              allowed:
                true,

              state:
                :runnable,

              reason:
                nil,

              work_available:
                true,

              snapshot:
                current_snapshot
            }
          else
            {
              module:
                name,

              allowed:
                false,

              state:
                :idle,

              reason:
                :no_work,

              work_available:
                false,

              snapshot:
                current_snapshot
            }
          end
        end

      with_env(
        "TANSA_PIPELINE_MODE" =>
          pipeline_mode
      ) do
        with_stubbed(
          System::PipelineController,
          :snapshot,
          snapshot
        ) do
          with_stubbed(
            System::PipelineController,
            :decision,
            decisions
          ) do
            with_stubbed(
              System::PipelineController,
              :work_available?,
              ->(decision) {
                decision[
                  :work_available
                ] == true
              }
            ) do
              with_stubbed(
                StrictPipeline::StrictIoLease,
                :current,
                current_lease
              ) do
                with_stubbed(
                  StrictPipeline::StrictIoLease,
                  :acquire,
                  ->(owner, **_options) {
                    lease_for.call(
                      owner
                    )
                  }
                ) do
                  scheduler.call
                end
              end
            end
          end
        end
      end

      enqueued
    end

    def with_stubbed(object, method_name, replacement)
      object.stub(
        method_name,
        replacement
      ) do
        yield
      end
    end

    def with_env(values)
      previous =
        values.to_h do |name, _value|
          [
            name,
            ENV.key?(name) ?
              ENV[name] :
              :__missing__
          ]
        end

      values.each do |name, value|
        if value.nil?
          ENV.delete(name)
        else
          ENV[name] =
            value
        end
      end

      yield
    ensure
      previous.each do |name, value|
        if value == :__missing__
          ENV.delete(name)
        else
          ENV[name] =
            value
        end
      end
    end
  end
end
