# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class StrictTipSyncerTest < ActiveSupport::TestCase
    setup do
      ClusterActorProfileHandoff.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      @base = 960_000 + SecureRandom.random_number(1_000)
      create_layer1!(@base)
      create_cluster!(@base)
    end

    test "processes a bounded contiguous window with a guard before every height" do
      create_layer1!(@base + 1)
      create_layer1!(@base + 2)
      calls = []
      guards = 0
      rebuild = lambda do |from_height:, to_height:|
        calls << [from_height, to_height]
        create_cluster!(from_height)
        { ok: true, status: "processed", height: from_height }
      end
      decision = ->(*) { guards += 1; { allowed: true } }
      wakeups = []

      System::PipelineController.stub(:decision, decision) do
        StrictWindowRebuilder.stub(:call, rebuild) do
          ActorProfileHandoffDispatcher.stub(:work_available?, true) do
            ActorProfileHandoffDispatchJob.stub(:perform_later, -> { wakeups << true }) do
              result = StrictTipSyncer.call(limit: 2)
              assert_equal "synced", result[:status]
              assert_equal 2, result[:processed]
              assert_nil result[:next_height]
              assert JSON.generate(result)
            end
          end
        end
      end

      assert_equal [[@base + 1, @base + 1], [@base + 2, @base + 2]], calls
      assert_equal 2, guards
      assert_equal [true], wakeups
    end

    test "a guard refusal before a height is fail closed and mutation free" do
      create_layer1!(@base + 1)
      System::PipelineController.stub(:decision, { allowed: false, reason: :layer1_priority }) do
        StrictWindowRebuilder.stub(:call, ->(**) { flunk "must not rebuild" }) do
          result = StrictTipSyncer.call(limit: 2)
          assert_equal "preempted", result[:status]
          assert_equal @base + 1, result[:next_height]
          assert_equal 0, result[:processed]
        end
      end
      assert_nil ClusterProcessedBlock.find_by(height: @base + 1)
    end

    test "guard errors and malformed decisions raise without rebuilding" do
      create_layer1!(@base + 1)
      [->(*) { raise "guard down" }, ->(*) { { allowed: nil } }].each do |guard|
        System::PipelineController.stub(:decision, guard) do
          assert_raises(StrictTipSyncer::GuardDenied) { StrictTipSyncer.call }
        end
      end
    end

    test "detects a bounded checkpoint hole and hash divergence" do
      create_layer1!(@base + 1)
      create_layer1!(@base + 2)
      create_cluster!(@base + 2)
      assert_raises(StrictTipSyncer::ContinuityError) { StrictTipSyncer.call }

      create_cluster!(@base + 1)
      ClusterProcessedBlock.where(height: @base + 1).update_all(block_hash: "divergent")
      assert_raises(StrictTipSyncer::HashMismatch) { StrictTipSyncer.call }
    end

    test "refuses a missing next Layer1 height despite a higher processed tip" do
      create_layer1!(@base + 2)
      System::PipelineController.stub(:decision, { allowed: true }) do
        assert_raises(StrictTipSyncer::Layer1Unavailable) { StrictTipSyncer.call }
      end
    end

    test "requires an explicit durable start when no Cluster checkpoint exists" do
      ClusterProcessedBlock.delete_all
      previous = ENV.delete("CLUSTER_STRICT_START_HEIGHT")
      assert_raises(StrictTipSyncer::InvalidStartHeight) { StrictTipSyncer.call }

      System::PipelineController.stub(:decision, { allowed: true }) do
        StrictWindowRebuilder.stub(:call, { ok: true, status: "processed", height: @base }) do
          ActorProfileHandoffDispatcher.stub(:work_available?, false) do
            assert_equal 1, StrictTipSyncer.call(start_height: @base, limit: 1)[:processed]
          end
        end
      end
    ensure
      ENV["CLUSTER_STRICT_START_HEIGHT"] = previous if previous
    end

    test "work probe and continuity source stay PostgreSQL-only and bounded" do
      create_layer1!(@base + 1)
      assert_equal true, StrictTipSyncer.work_available?
      source = File.read(Rails.root.join("app/services/clusters/strict_tip_syncer.rb"))

      assert_match(/CONTINUITY_DEPTH/, source)
      assert_match(/\.limit\(@limit\)|results\.size < @limit/, source)
      assert_no_match(/Redis|tx_outputs|utxo_outputs|ActorProfiles::/, source)
    end

    private

    def create_layer1!(height)
      BlockBufferModel.create!(height: height, block_hash: hash_for(height), status: "processed")
    end

    def create_cluster!(height)
      ClusterProcessedBlock.create!(
        height: height,
        block_hash: hash_for(height),
        status: "processed",
        processed_at: Time.current
      )
    end

    def hash_for(height)
      Digest::SHA256.hexdigest("strict-sync-#{height}")
    end
  end
end
