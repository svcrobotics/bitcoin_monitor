# frozen_string_literal: true

require "test_helper"

class ActorProfileCertificationContractTest < ActiveSupport::TestCase
  test "certification columns indexes and constraints are installed" do
    columns = ActorProfile.columns_hash

    assert_equal :integer, columns.fetch("certification_epoch_height").type
    assert_equal :string, columns.fetch("certification_scope").type
    assert_equal :datetime, columns.fetch("certified_at").type
    assert columns.fetch("certified_at").null

    index_names = ApplicationRecord.connection.indexes(:actor_profiles).map(&:name)
    assert_includes index_names, "index_actor_profiles_on_epoch_and_dirty"
    assert_includes index_names, "index_actor_profiles_on_scope_and_epoch"
    assert_includes index_names, "index_actor_profiles_on_certified_at"

    constraints = ApplicationRecord.connection.check_constraints(:actor_profiles).map(&:name)
    assert_includes constraints, "actor_profiles_positive_certification_epoch"
    assert_includes constraints, "actor_profiles_certification_scope_present"
  end

  test "PostgreSQL rejects invalid certification provenance" do
    cluster = Cluster.create!(composition_version: 1)

    assert_raises(ActiveRecord::StatementInvalid) do
      ActorProfile.create!(
        cluster: cluster,
        certification_epoch_height: 0,
        certification_scope: "strict"
      )
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      ActorProfile.create!(
        cluster: cluster,
        certification_epoch_height: 1,
        certification_scope: ""
      )
    end
  end
end
