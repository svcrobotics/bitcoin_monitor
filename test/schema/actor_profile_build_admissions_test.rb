# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260716120000_create_actor_profile_build_admissions")

class ActorProfileBuildAdmissionsSchemaTest < ActiveSupport::TestCase
  TABLE = :actor_profile_build_admissions

  test "defines the durable source-version identity and constraints" do
    columns = connection.columns(TABLE).index_by(&:name)
    assert_equal %w[id cluster_id cluster_composition_version source_height source_hash reason
      status attempts claimed_at completed_at last_error_class created_at updated_at].sort,
      columns.keys.sort
    assert_equal false, columns.fetch("cluster_id").null
    assert_equal false, columns.fetch("cluster_composition_version").null
    assert_equal false, columns.fetch("source_height").null
    assert_equal false, columns.fetch("source_hash").null
    assert_equal "pending", columns.fetch("status").default
    assert_equal "0", columns.fetch("attempts").default.to_s

    indexes = connection.indexes(TABLE).index_by(&:name)
    identity = indexes.fetch("idx_actor_profile_admissions_identity")
    assert identity.unique
    assert_equal %w[cluster_id cluster_composition_version source_height source_hash], identity.columns
    assert_equal %w[status source_height cluster_id id],
      indexes.fetch("idx_actor_profile_admissions_claim_order").columns
    assert_equal "clusters", connection.foreign_keys(TABLE).sole.to_table

    checks = connection.check_constraints(TABLE).map(&:name)
    %w[actor_profile_admissions_composition_version_check
      actor_profile_admissions_source_height_check actor_profile_admissions_source_hash_check
      actor_profile_admissions_reason_check actor_profile_admissions_attempts_check
      actor_profile_admissions_status_check actor_profile_admissions_claim_check
      actor_profile_admissions_completion_check].each { |name| assert_includes checks, name }
  end

  test "migration is reversible" do
    migration = CreateActorProfileBuildAdmissions.new
    migration.migrate(:down)
    connection.schema_cache.clear!
    assert_not connection.table_exists?(TABLE)
    migration.migrate(:up)
    connection.schema_cache.clear!
    assert connection.table_exists?(TABLE)
  ensure
    unless connection.table_exists?(TABLE)
      migration&.migrate(:up)
      connection.schema_cache.clear!
    end
  end

  private

  def connection = ActiveRecord::Base.connection
end
