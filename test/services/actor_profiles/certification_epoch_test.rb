# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class CertificationEpochTest <
    ActiveSupport::TestCase

    def setup
      ActorProfileCertificationEpoch.delete_all
      ClusterProcessedBlock.delete_all
    end

    def teardown
      ActorProfileCertificationEpoch.delete_all
      ClusterProcessedBlock.delete_all
    end

    test "is inactive without an epoch" do
      refute CertificationEpoch.active?
      assert_nil CertificationEpoch.current
      assert_nil CertificationEpoch.start_height
    end

    test "refuses activation without cluster checkpoint" do
      assert_raises(
        CertificationEpoch::MissingCheckpoint
      ) do
        CertificationEpoch.activate_current!
      end
    end

    test "activates at latest processed cluster checkpoint" do
      create_checkpoint(
        height: 957_100
      )

      create_checkpoint(
        height: 957_101
      )

      epoch =
        CertificationEpoch.activate_current!

      assert_equal(
        StrictBuildFromCluster::PROFILE_VERSION,
        epoch.profile_version
      )

      assert_equal 957_101, epoch.start_height

      assert_equal(
        "cluster_strict_checkpoint",
        epoch.source
      )

      assert epoch.activated_at.present?
      assert CertificationEpoch.active?
      assert_equal 957_101, CertificationEpoch.start_height
    end

    test "activation is idempotent and never moves epoch" do
      create_checkpoint(
        height: 957_200
      )

      first =
        CertificationEpoch.activate_current!

      create_checkpoint(
        height: 957_250
      )

      second =
        CertificationEpoch.activate_current!

      assert_equal first.id, second.id
      assert_equal 957_200, second.start_height
      assert_equal 1, ActorProfileCertificationEpoch.count
    end

    test "persisted epoch is immutable" do
      create_checkpoint(
        height: 957_300
      )

      epoch =
        CertificationEpoch.activate_current!

      assert epoch.readonly?

      assert_raises(
        ActiveRecord::ReadOnlyRecord
      ) do
        epoch.update!(
          start_height: 957_301
        )
      end
    end

    private

    def create_checkpoint(height:)
      ClusterProcessedBlock.create!(
        height: height,
        block_hash: SecureRandom.hex(32),
        status: "processed",
        processed_at: Time.current
      )
    end
  end
end
