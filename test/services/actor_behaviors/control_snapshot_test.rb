# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ActorBehaviors
  class ControlSnapshotTest < ActiveSupport::TestCase
    test "uses PostgreSQL handoffs and no Redis state" do
      relation = Object.new
      relation.define_singleton_method(:exists?) { true }
      relation.define_singleton_method(:where) { |*| self }
      ActorProfiles::CertifiedScope.stub(:call, relation) do
        BuildDispatcher.stub(:work_available?, true) do
          ActorBehaviorBuildHandoff.stub(:where, relation) do
            result = ControlSnapshot.call
            assert result[:auto_enabled]
            assert result[:certified_profiles_available]
            assert result[:work_available]
            assert_equal "strict", result[:mode]
            assert_equal "strict_v2", result[:behavior_version]
          end
        end
      end
      source = Rails.root.join("app/services/actor_behaviors/control_snapshot.rb").read
      refute_match(/Redis|Sidekiq|DirtyMarker|StrictBatch/, source)
    end

    test "explicit disable is fail closed" do
      previous = ENV[ControlSnapshot::AUTO_ENABLED_ENV]
      ENV[ControlSnapshot::AUTO_ENABLED_ENV] = "false"
      relation = Object.new
      relation.define_singleton_method(:exists?) { false }
      relation.define_singleton_method(:where) { |*| self }
      ActorProfiles::CertifiedScope.stub(:call, relation) do
        BuildDispatcher.stub(:work_available?, false) do
          ActorBehaviorBuildHandoff.stub(:where, relation) do
            refute ControlSnapshot.call[:auto_enabled]
          end
        end
      end
    ensure
      ENV[ControlSnapshot::AUTO_ENABLED_ENV] = previous
    end
  end
end
