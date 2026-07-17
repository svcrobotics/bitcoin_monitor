# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class CertificationTargetScopeTest <
    ActiveSupport::TestCase

    def setup
      @previous_singletons =
        ENV[
          CertificationTargetScope::
            INCLUDE_SINGLETONS_ENV
        ]

      ENV[
        CertificationTargetScope::
          INCLUDE_SINGLETONS_ENV
      ] = "false"

      ActorProfileCertificationEpoch.delete_all

      @epoch =
        ActorProfileCertificationEpoch.create!(
          profile_version:
            StrictBuildFromCluster::
              PROFILE_VERSION,

          start_height:
            957_300,

          activated_at:
            Time.current,

          source:
            ActorProfileCertificationEpoch::
              SOURCE_CLUSTER_STRICT_CHECKPOINT,

          metadata: {}
        )
    end

    def teardown
      ActorProfileCertificationEpoch.delete_all

      if @previous_singletons.nil?
        ENV.delete(
          CertificationTargetScope::
            INCLUDE_SINGLETONS_ENV
        )
      else
        ENV[
          CertificationTargetScope::
            INCLUDE_SINGLETONS_ENV
        ] = @previous_singletons
      end
    end

    test "refuses use without an active epoch" do
      ActorProfileCertificationEpoch.delete_all

      assert_raises(
        CertificationTargetScope::InactiveEpoch
      ) do
        CertificationTargetScope.call(
          checkpoint_height: 957_310
        )
      end
    end

    test "selects only eligible clusters active since epoch" do
      before_epoch =
        create_cluster(
          address_count: 2,
          last_seen_height: 957_299
        )

      at_epoch =
        create_cluster(
          address_count: 2,
          last_seen_height: 957_300
        )

      after_epoch =
        create_cluster(
          address_count: 2,
          last_seen_height: 957_305
        )

      ahead_of_checkpoint =
        create_cluster(
          address_count: 2,
          last_seen_height: 957_311
        )

      singleton =
        create_cluster(
          address_count: 1,
          last_seen_height: 957_305
        )

      ids =
        CertificationTargetScope
          .call(
            checkpoint_height:
              957_310
          )
          .pluck(:id)

      refute_includes ids, before_epoch.id
      assert_includes ids, at_epoch.id
      assert_includes ids, after_epoch.id
      refute_includes ids, ahead_of_checkpoint.id
      refute_includes ids, singleton.id
    end

    test "returns an empty scope when checkpoint precedes epoch" do
      scope =
        CertificationTargetScope.call(
          checkpoint_height: 957_299
        )

      assert_empty scope
    end

    test "provides the same scope as a reusable SQL condition" do
      selected =
        create_cluster(
          address_count: 2,
          last_seen_height: 957_304
        )

      excluded =
        create_cluster(
          address_count: 2,
          last_seen_height: 957_200
        )

      condition =
        CertificationTargetScope
          .sql_condition(
            checkpoint_height:
              957_310
          )

      ids =
        Cluster
          .where(condition)
          .pluck(:id)

      assert_includes ids, selected.id
      refute_includes ids, excluded.id
    end

    private

    def create_cluster(
      address_count:,
      last_seen_height:
    )
      Cluster.create!(
        address_count:
          address_count,

        first_seen_height:
          last_seen_height - 10,

        last_seen_height:
          last_seen_height,

        composition_version:
          1
      )
    end
  end
end
