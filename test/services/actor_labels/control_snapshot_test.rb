# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class ControlSnapshotTest < ActiveSupport::TestCase
    test "does not reference actor profile classification or legacy pipelines" do
      source =
        Rails.root.join(
          "app/services/actor_labels/control_snapshot.rb"
        ).read

      refute_match(/ActorProfiles::StrictRuleSetV2/, source)
      refute_match(/ActorProfiles::ScoreCalculator/, source)
      refute_match(/RefreshFromActorProfile/, source)
      refute_match(/ActorProfile\.classification/, source)
    end

    test "uses the strict actor behavior rule version" do
      snapshot =
        ActorLabels::ControlSnapshot.call

      assert_equal(
        ActorLabels::StrictRuleSet::SOURCE,
        snapshot[:source]
      )

      assert_equal(
        ActorLabels::StrictRuleSet::RULE_VERSION,
        snapshot[:rule_version]
      )

      assert_equal(
        ActorLabels::StrictRuleSet::BEHAVIOR_VERSION,
        snapshot[:required_behavior_version]
      )
    end

    test "reports the write capability published by the worker" do
      payload = {
        observed_at: Time.current.iso8601(6),
        queue_name: "actor_labels_strict",
        write_enabled: true,
        pid: 12_345
      }

      Sidekiq.redis do |redis|
        redis.set(
          ActorLabels::StrictBatchJob::WORKER_STATUS_KEY,
          JSON.generate(payload)
        )
      end

      snapshot =
        ActorLabels::ControlSnapshot.call

      assert_equal true,
                   snapshot[:worker_write_observed]

      assert_equal true,
                   snapshot[:worker_write_enabled]

      assert_not_nil(
        snapshot[:worker_status_observed_at]
      )
    ensure
      Sidekiq.redis do |redis|
        redis.del(
          ActorLabels::StrictBatchJob::WORKER_STATUS_KEY
        )
      end
    end

    test "ignores expired worker write capability" do
      payload = {
        observed_at: 2.hours.ago.iso8601(6),
        queue_name: "actor_labels_strict",
        write_enabled: true,
        pid: 12_345
      }

      Sidekiq.redis do |redis|
        redis.set(
          ActorLabels::StrictBatchJob::WORKER_STATUS_KEY,
          JSON.generate(payload)
        )
      end

      snapshot =
        ActorLabels::ControlSnapshot.call

      assert_equal true,
                   snapshot[:worker_write_observed]

      assert_equal false,
                   snapshot[:worker_write_status_fresh]

      assert_equal false,
                   snapshot[:worker_write_enabled]
    ensure
      Sidekiq.redis do |redis|
        redis.del(
          ActorLabels::StrictBatchJob::WORKER_STATUS_KEY
        )
      end
    end

    test "reports the strict batch Redis lock" do
      Sidekiq.redis do |redis|
        redis.set(
          ActorLabels::StrictBatchJob::LOCK_KEY,
          "test-lock"
        )
      end

      snapshot =
        ActorLabels::ControlSnapshot.call

      assert_equal true,
                   snapshot[:lock_present]
    ensure
      Sidekiq.redis do |redis|
        redis.del(
          ActorLabels::StrictBatchJob::LOCK_KEY
        )
      end
    end

    test "reports no incremental work after the cursor" do
      filtered_scope =
        Object.new

      filtered_scope.define_singleton_method(
        :exists?
      ) do
        false
      end

      current_scope =
        Object.new

      current_scope.define_singleton_method(
        :where
      ) do |*_arguments|
        filtered_scope
      end

      current_scope.define_singleton_method(
        :exists?
      ) do
        true
      end

      snapshot =
        ActorLabels::ControlSnapshot.new(
          now: Time.current
        )

      snapshot.define_singleton_method(
        :sql_current_scope
      ) do
        current_scope
      end

      assert_equal false,
                   snapshot.send(
                     :work_available?,
                     123
                   )
    end

    test "does not write actor labels or actor behavior snapshots" do
      assert_no_difference -> { ActorLabel.count } do
        assert_no_difference -> { ActorBehaviorSnapshot.count } do
          ActorLabels::ControlSnapshot.call
        end
      end
    end
  end
end
