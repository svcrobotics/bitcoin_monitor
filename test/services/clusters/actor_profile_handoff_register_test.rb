# frozen_string_literal: true

require "test_helper"

module Clusters
  class ActorProfileHandoffRegisterTest < ActiveSupport::TestCase
    setup do
      ClusterActorProfileHandoff.delete_all
      Cluster.delete_all
      @first = Cluster.create!(composition_version: 3)
      @second = Cluster.create!(composition_version: 2)
    end

    test "registers deterministic handoffs for persisted composition versions" do
      result = register([
        { cluster_id: @second.id, composition_version: 2 },
        { cluster_id: @first.id, composition_version: 3 },
        { cluster_id: @first.id, composition_version: 3 }
      ])

      assert_equal 2, result[:registered]
      assert_equal [@first.id, @second.id], result[:handoffs].pluck(:cluster_id)
      assert_equal [3, 2], result[:handoffs].pluck(:composition_version)
      assert_equal %w[pending pending], result[:handoffs].pluck(:status)
      assert JSON.generate(result)
    end

    test "same certification replay is idempotent" do
      touched = [{ cluster_id: @first.id, composition_version: 3 }]

      first = register(touched)
      second = register(touched)

      assert_equal 1, first[:registered]
      assert_equal 0, second[:registered]
      assert_equal first[:handoffs], second[:handoffs]
      assert_equal 1, ClusterActorProfileHandoff.count
    end

    test "divergent block hash creates a distinct certification identity" do
      touched = [{ cluster_id: @first.id, composition_version: 3 }]
      register(touched)
      other = register(touched, block_hash: "other-certified-hash")

      assert_equal 1, other[:registered]
      assert_equal 2, ClusterActorProfileHandoff.count
      assert_equal %w[certified-hash other-certified-hash],
        ClusterActorProfileHandoff.order(:block_hash).pluck(:block_hash)
    end

    test "empty scanner result is explicit and mutation free" do
      assert_equal({ registered: 0, handoffs: [] }, register([]))
      assert_equal 0, ClusterActorProfileHandoff.count
    end

    test "refuses missing or changed Cluster versions" do
      error = assert_raises(ActorProfileHandoffRegister::CompositionChanged) do
        register([{ cluster_id: @first.id, composition_version: 2 }])
      end

      assert_match(/composition changed/i, error.message)
      assert_equal 0, ClusterActorProfileHandoff.count
    end

    test "does not depend on Redis Sidekiq or downstream models" do
      sql = capture_sql do
        @result = register([{ cluster_id: @first.id, composition_version: 3 }])
      end
      source = File.read(Rails.root.join("app/services/clusters/actor_profile_handoff_register.rb"))

      assert_no_match(/Redis|Sidekiq|ActorProfile\.|ActorLabel|ActorBehavior/, source)
      assert_empty sql.grep(/actor_profiles|actor_labels|actor_behaviors/i)
      assert JSON.generate(@result)
    end

    private

    def register(clusters, block_hash: "certified-hash")
      ActorProfileHandoffRegister.call(
        cluster_height: 910_000,
        block_hash: block_hash,
        clusters_touched: clusters
      )
    end

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        statements << payload[:sql].to_s unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end
  end
end
