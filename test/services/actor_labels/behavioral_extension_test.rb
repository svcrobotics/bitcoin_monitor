# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module ActorLabels
  class BehavioralExtensionTest < ActiveSupport::TestCase
    include ActorBehaviorTestHelper

    test "emits retention at the exact 80 percent and 20 receive threshold" do
      snapshot = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 1)

      result = BehavioralExtensionRuleSet.call(snapshot: snapshot)

      assert_equal true, result[:eligible]
      assert_equal ["high_retention_behavior"], result[:labels].map { |label| label[:label] }
    end

    test "emits spend through at the exact 95 percent and 20 spend threshold" do
      snapshot = build_snapshot(balance: "5", received: "100", sent: "95", received_transactions: 1, spending_transactions: 20)

      result = BehavioralExtensionRuleSet.call(snapshot: snapshot)

      assert_equal true, result[:eligible]
      assert_equal ["high_spend_through_behavior"], result[:labels].map { |label| label[:label] }
    end

    test "rejects values just below either ratio or activity threshold" do
      retention = BehavioralExtensionRuleSet.call(
        snapshot: build_snapshot(balance: "79.99", received: "100", sent: "20.01", received_transactions: 20, spending_transactions: 1)
      )
      spend_through = BehavioralExtensionRuleSet.call(
        snapshot: build_snapshot(balance: "5.01", received: "100", sent: "94.99", received_transactions: 1, spending_transactions: 20)
      )
      retention_activity = BehavioralExtensionRuleSet.call(
        snapshot: build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 19, spending_transactions: 1)
      )
      spend_activity = BehavioralExtensionRuleSet.call(
        snapshot: build_snapshot(balance: "5", received: "100", sent: "95", received_transactions: 1, spending_transactions: 19)
      )

      assert_empty retention[:labels]
      assert_empty spend_through[:labels]
      assert_empty retention_activity[:labels]
      assert_empty spend_activity[:labels]
    end

    test "rejects zero received volume" do
      result = BehavioralExtensionRuleSet.call(
        snapshot: build_snapshot(balance: "0", received: "0", sent: "0", received_transactions: 20, spending_transactions: 20)
      )

      assert_equal false, result[:eligible]
      assert_equal :total_received_not_positive, result[:reason]
    end

    test "rejects a fingerprint mismatch and incomplete financial facts" do
      fingerprint_snapshot = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 1)
      fingerprint_snapshot.update!(source_hash: "different-source-hash")
      missing_snapshot = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 1)
      missing_snapshot.update!(evidence: missing_snapshot.evidence.deep_dup.tap { |e| e["facts"].delete("outflow_count") })

      fingerprint_result = BehavioralExtensionRuleSet.call(snapshot: fingerprint_snapshot)
      missing_result = BehavioralExtensionRuleSet.call(snapshot: missing_snapshot)

      assert_equal :fingerprint_mismatch, fingerprint_result[:reason]
      assert_equal :required_facts_missing, missing_result[:reason]
    end

    test "rejects non-certified and obsolete snapshots" do
      failed = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 1)
      failed.update!(status: "failed")
      dirty = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 1)
      dirty.actor_profile.update!(dirty: true)
      composition = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 1)
      composition.actor_profile.cluster.update!(composition_version: 2)

      failed_result = BehavioralExtensionRuleSet.call(snapshot: failed)
      dirty_result = BehavioralExtensionRuleSet.call(snapshot: dirty)
      composition_result = BehavioralExtensionRuleSet.call(snapshot: composition)

      assert_equal :behavior_not_certified, failed_result[:reason]
      assert_equal :certified_scope_mismatch, dirty_result[:reason]
      assert_equal :certified_scope_mismatch, composition_result[:reason]
    end

    test "cannot emit both behaviors for a coherent accounting identity" do
      snapshot = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 20)

      result = BehavioralExtensionRuleSet.call(snapshot: snapshot)

      refute_includes result[:labels].map { |label| label[:label] }, "high_spend_through_behavior"
      assert_includes result[:labels].map { |label| label[:label] }, "high_retention_behavior"
    end

    test "writer is idempotent, traceable, and source-isolated" do
      snapshot = build_snapshot(balance: "80", received: "100", sent: "20", received_transactions: 20, spending_transactions: 1)

      first = BehavioralExtensionWriter.call(snapshot: snapshot, dry_run: false)
      second = BehavioralExtensionWriter.call(snapshot: snapshot, dry_run: false)
      label = ActorLabel.find_by!(cluster_id: snapshot.cluster_id, source: BehavioralExtensionRuleSet::SOURCE)

      assert_equal true, first[:ok]
      assert_empty second[:written_labels]
      assert_equal snapshot.id, label.actor_behavior_snapshot_id
      assert_equal BehavioralExtensionRuleSet::RULE_VERSION, label.rule_version
      assert_equal snapshot.certified_at, label.certified_at
      assert_equal "0.8", label.metadata.dig("evidence", "ratios", "retention_ratio")
    end

    test "writer removes only its own obsolete output and preserves strict and heavy labels" do
      snapshot = build_snapshot(balance: "50", received: "100", sent: "50", received_transactions: 20, spending_transactions: 1)
      ActorLabel.create!(cluster_id: snapshot.cluster_id, actor_profile_id: snapshot.actor_profile_id, label: "exchange_like", confidence: 70, source: ActorLabels::StrictRuleSet::SOURCE)
      ActorLabel.create!(cluster_id: snapshot.cluster_id, actor_profile_id: snapshot.actor_profile_id, label: "exchange_infrastructure_candidate", confidence: 90, source: ActorLabels::HeavyRuleSet::SOURCE)
      ActorLabel.create!(cluster_id: snapshot.cluster_id, actor_profile_id: snapshot.actor_profile_id, label: "high_retention_behavior", confidence: 80, source: BehavioralExtensionRuleSet::SOURCE)

      result = BehavioralExtensionWriter.call(snapshot: snapshot, dry_run: false)

      assert_equal ["high_retention_behavior"], result[:deleted_labels]
      assert ActorLabel.exists?(cluster_id: snapshot.cluster_id, source: ActorLabels::StrictRuleSet::SOURCE, label: "exchange_like")
      assert ActorLabel.exists?(cluster_id: snapshot.cluster_id, source: ActorLabels::HeavyRuleSet::SOURCE, label: "exchange_infrastructure_candidate")
      refute ActorLabel.exists?(cluster_id: snapshot.cluster_id, source: BehavioralExtensionRuleSet::SOURCE)
    end

    test "batch is dry-run by default and is not connected to the scheduler" do
      source = File.read(Rails.root.join("app/services/strict_pipeline/scheduler.rb"))

      assert_equal true, BehavioralExtensionBatch.call(limit: 1)[:dry_run]
      refute_includes source, "BehavioralExtensionBatch"
      refute_includes source, "behavioral_extension"
    end

    test "batch reconciles a missing output from an empty final page" do
      snapshot = build_snapshot(balance: "5", received: "100", sent: "95", received_transactions: 1, spending_transactions: 20)
      ActorLabel.where(source: BehavioralExtensionRuleSet::SOURCE).delete_all
      scope = ActorBehaviorSnapshot.where(id: snapshot.id)

      with_certified_scope(scope) do
        result = BehavioralExtensionBatch.call(limit: 5_000, after_id: snapshot.id, dry_run: false)

        assert_equal 0, result[:scanned]
        assert_equal ["high_spend_through_behavior"], result[:created_or_updated_labels]
        assert ActorLabel.exists?(cluster_id: snapshot.cluster_id, label: "high_spend_through_behavior", source: BehavioralExtensionRuleSet::SOURCE)
      end
    end

    test "batch dry-run reports changes without mutating on an empty final page" do
      snapshot = build_snapshot(balance: "5", received: "100", sent: "95", received_transactions: 1, spending_transactions: 20)
      ActorLabel.where(source: BehavioralExtensionRuleSet::SOURCE).delete_all
      scope = ActorBehaviorSnapshot.where(id: snapshot.id)

      with_certified_scope(scope) do
        result = BehavioralExtensionBatch.call(limit: 5_000, after_id: snapshot.id, dry_run: true)

        assert_equal ["high_spend_through_behavior"], result[:expected_upsert_labels]
        assert_empty ActorLabel.where(source: BehavioralExtensionRuleSet::SOURCE)
      end
    end

    test "batch does not mutate when global expected-set construction fails" do
      existing = build_snapshot(balance: "5", received: "100", sent: "95", received_transactions: 1, spending_transactions: 20)
      ActorLabel.create!(cluster_id: existing.cluster_id, actor_profile_id: existing.actor_profile_id, label: "high_spend_through_behavior", source: BehavioralExtensionRuleSet::SOURCE)
      with_certified_scope(-> { raise "scope failure" }) do
        assert_raises(RuntimeError) do
          BehavioralExtensionBatch.call(limit: 5_000, after_id: 1_000_000, dry_run: false)
        end
        assert ActorLabel.exists?(cluster_id: existing.cluster_id, label: "high_spend_through_behavior", source: BehavioralExtensionRuleSet::SOURCE)
      end
    end

    private

    def with_certified_scope(value)
      singleton = ActorBehaviors::CertifiedScope.singleton_class
      original = singleton.instance_method(:call)
      singleton.define_method(:call) { value.respond_to?(:call) ? value.call : value }
      yield
    ensure
      singleton.define_method(:call, original)
    end

    def build_snapshot(balance:, received:, sent:, received_transactions:, spending_transactions:)
      profile = create_certified_actor_profile(
        balance_btc: balance,
        total_received_btc: received,
        total_sent_btc: sent,
        net_btc: balance,
        tx_count: received_transactions + spending_transactions,
        inflow_count: received_transactions,
        outflow_count: spending_transactions
      )

      create_current_behavior_snapshot(profile)
    end
  end
end
