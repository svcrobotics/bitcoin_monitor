# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class SchedulerActorProfileEpochTest <
    ActiveSupport::TestCase

    test "refreshes pipeline snapshot after epoch activation" do
      first_snapshot = {
        actor_profile: {
          epoch_active: false
        }
      }

      refreshed_snapshot = {
        actor_profile: {
          epoch_active: true
        }
      }

      snapshots = [
        first_snapshot,
        refreshed_snapshot
      ]

      snapshot_calls = 0
      activation_input = nil
      ordered_snapshot = nil

      scheduler =
        isolated_scheduler do |snapshot|
          ordered_snapshot = snapshot
        end

      with_singleton_method(
        System::PipelineController,
        :snapshot,
        replacement: lambda do
          result =
            snapshots.fetch(
              snapshot_calls
            )

          snapshot_calls += 1
          result
        end
      ) do
        with_singleton_method(
          ActorProfiles::
            CertificationEpochAutoActivator,
          :call,
          replacement: lambda do |snapshot:|
            activation_input = snapshot

            {
              status: "activated",
              start_height: 990
            }
          end
        ) do
          result =
            scheduler.call

          assert_equal(
            2,
            snapshot_calls
          )

          assert_same(
            first_snapshot,
            activation_input
          )

          assert_same(
            refreshed_snapshot,
            ordered_snapshot
          )

          assert_equal(
            "activated",
            result.dig(
              :actor_profile_epoch_activation,
              :status
            )
          )
        end
      end
    end

    test "keeps original snapshot while activation waits" do
      first_snapshot = {
        actor_profile: {
          epoch_active: false
        }
      }

      snapshot_calls = 0
      activation_input = nil
      ordered_snapshot = nil

      scheduler =
        isolated_scheduler do |snapshot|
          ordered_snapshot = snapshot
        end

      with_singleton_method(
        System::PipelineController,
        :snapshot,
        replacement: lambda do
          snapshot_calls += 1
          first_snapshot
        end
      ) do
        with_singleton_method(
          ActorProfiles::
            CertificationEpochAutoActivator,
          :call,
          replacement: lambda do |snapshot:|
            activation_input = snapshot

            {
              status: "waiting",
              reason:
                "address_spend_projection_not_caught_up"
            }
          end
        ) do
          result =
            scheduler.call

          assert_equal(
            1,
            snapshot_calls
          )

          assert_same(
            first_snapshot,
            activation_input
          )

          assert_same(
            first_snapshot,
            ordered_snapshot
          )

          assert_equal(
            "waiting",
            result.dig(
              :actor_profile_epoch_activation,
              :status
            )
          )
        end
      end
    end

    test "activation error does not stop scheduler" do
      scheduler =
        Scheduler.new

      with_singleton_method(
        ActorProfiles::
          CertificationEpochAutoActivator,
        :call,
        replacement: lambda do |snapshot:|
          raise "activation unavailable"
        end
      ) do
        result =
          scheduler.send(
            :activate_actor_profile_epoch,
            {}
          )

        assert_equal(
          "error",
          result[:status]
        )

        assert_match(
          "activation unavailable",
          result[:error]
        )
      end
    end

    private

    def isolated_scheduler(
      &ordered_snapshot_capture
    )
      scheduler =
        Scheduler.new

      scheduler.define_singleton_method(
        :publish_runtime_status
      ) {}

      scheduler.define_singleton_method(
        :ensure_actor_labels_worker_capability
      ) {}

      scheduler.define_singleton_method(
        :ordered_jobs
      ) do |snapshot|
        ordered_snapshot_capture.call(
          snapshot
        )

        []
      end

      scheduler.define_singleton_method(
        :run_anomaly_watchdog
      ) do
        {
          ok: true,
          notified: false
        }
      end

      scheduler
    end

    def with_singleton_method(
      target,
      method_name,
      replacement:
    )
      original =
        target.method(
          method_name
        )

      target.define_singleton_method(
        method_name,
        &replacement
      )

      yield
    ensure
      target.define_singleton_method(
        method_name,
        original
      )
    end
  end
end
