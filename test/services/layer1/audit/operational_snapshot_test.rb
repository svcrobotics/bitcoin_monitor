# frozen_string_literal: true

require "test_helper"
require "json"
require "minitest/mock"

module Layer1
  module Audit
    class OperationalSnapshotTest < ActiveSupport::TestCase
      FakeQueue = Struct.new(:size, :latency)
      FakeWork = Struct.new(:queue)

      setup do
        Layer1AuditRun.delete_all
        BlockBufferModel.delete_all
      end

      test "reports a healthy latest audit" do
        create_run(height: 100, status: "healthy")

        result = snapshot

        assert_equal "healthy", result[:status]
        assert_equal "healthy", result[:audit_status]
        assert_equal 100, result.dig(:latest_run, :audited_height)
      end

      test "reports a failed latest audit distinctly" do
        create_run(height: 101, status: "failed")

        result = snapshot

        assert_equal "critical", result[:status]
        assert_equal "failed", result[:audit_status]
        assert_equal "failed", result.dig(:latest_run, :status)
      end

      test "reports an errored latest audit distinctly" do
        create_run(height: 102, status: "error")

        result = snapshot

        assert_equal "critical", result[:status]
        assert_equal "error", result[:audit_status]
        assert_equal "error", result.dig(:latest_run, :status)
      end

      test "reports a running latest audit without claiming healthy" do
        create_run(height: 103, status: "running", finished_at: nil)

        result = snapshot

        assert_equal "warning", result[:status]
        assert_equal "running", result[:audit_status]
        assert_equal "running", result.dig(:latest_run, :status)
      end

      test "reports no data without inventing healthy heights or lag" do
        result = snapshot

        assert_equal "no_data", result[:status]
        assert_equal "no_data", result[:audit_status]
        assert_nil result[:latest_run]
        assert_nil result[:latest_healthy_run]
        assert_nil result[:highest_healthy_height]
        assert_nil result[:latest_healthy_lag]
        assert_empty result[:run_history]
        assert_equal 0, result.dig(:recent_runs, :sample_size)
      end

      test "a recent failure is not masked by an older healthy audit" do
        healthy = create_run(height: 110, status: "healthy", created_at: 2.minutes.ago)
        failed = create_run(height: 111, status: "failed", created_at: 1.minute.ago)

        result = snapshot

        assert_equal failed.audited_height, result.dig(:latest_run, :audited_height)
        assert_equal healthy.audited_height,
                     result.dig(:latest_healthy_run, :audited_height)
        assert_equal "failed", result[:audit_status]
        assert_equal "critical", result[:status]
      end

      test "distinguishes latest healthy run from highest healthy height" do
        create_run(height: 200, status: "healthy", created_at: 3.minutes.ago)
        latest_healthy =
          create_run(height: 150, status: "healthy", created_at: 2.minutes.ago)
        latest = create_run(height: 151, status: "failed", created_at: 1.minute.ago)
        create_tip(250)

        result = snapshot

        assert_equal latest.audited_height, result.dig(:latest_run, :audited_height)
        assert_equal latest_healthy.audited_height,
                     result.dig(:latest_healthy_run, :audited_height)
        assert_equal 200, result[:highest_healthy_height]
        assert_equal 100, result[:latest_healthy_lag]
        assert_equal 50, result[:highest_healthy_lag]
      end

      test "leaves lag unavailable when tip is absent" do
        create_run(height: 120, status: "healthy")

        result = snapshot

        assert_nil result[:realtime_tip]
        assert_nil result[:latest_healthy_lag]
        assert_nil result[:highest_healthy_lag]
      end

      test "leaves healthy lag unavailable when no healthy height exists" do
        create_run(height: 121, status: "failed")
        create_tip(130)

        result = snapshot

        assert_equal 130, result[:realtime_tip]
        assert_nil result[:last_healthy_height]
        assert_nil result[:latest_healthy_lag]
        assert_nil result[:highest_healthy_lag]
      end

      test "computes exact lag and clamps a negative lag to zero" do
        create_run(height: 140, status: "healthy")
        create_tip(150)

        assert_equal 10, snapshot[:highest_healthy_lag]

        BlockBufferModel.delete_all
        create_tip(130)

        assert_equal 0, snapshot[:highest_healthy_lag]
      end

      test "reports real idle activity" do
        result = snapshot(queue_size: 0, worker_queues: [])

        assert_equal "idle", result[:activity]
        assert_equal 0, result[:queue_size]
        assert_equal 0, result[:worker_count]
        assert_equal true, result[:sidekiq_available]
      end

      test "reports queued activity with explicit latency units" do
        result = snapshot(queue_size: 3, queue_latency: 12.3456, worker_queues: [])

        assert_equal "queued", result[:activity]
        assert_equal 3, result[:queue_size]
        assert_equal 12.346, result[:queue_latency_seconds]
        assert_equal 0, result[:worker_count]
      end

      test "reports deduplication marker expiry risk from queue latency" do
        cases = [
          { latency: 0, status: "healthy", ratio: 0.0 },
          { latency: 1_799.999, status: "healthy", ratio: 1_799.999 / 3_600.0 },
          { latency: 1_800, status: "warning", ratio: 0.5 },
          { latency: 3_599.999, status: "warning", ratio: 3_599.999 / 3_600.0 },
          { latency: 3_600, status: "critical", ratio: 1.0 },
          { latency: 7_200, status: "critical", ratio: 2.0 }
        ]

        cases.each do |entry|
          risk = snapshot(queue_latency: entry[:latency]).fetch(:deduplication_expiry_risk)

          assert_equal Layer1::Audit::BlockJob::INITIAL_MARKER_TTL_SECONDS,
            risk[:marker_ttl_seconds]
          assert_equal entry[:latency].to_f, risk[:queue_latency_seconds].to_f
          assert_in_delta entry[:ratio], risk[:queue_latency_to_ttl_ratio], 0.000_001
          assert_equal entry[:status], risk[:status]
        end
      end

      test "reports unavailable expiry risk when queue latency is absent or invalid" do
        [nil, -1, Float::INFINITY, Float::NAN].each do |latency|
          risk = snapshot(queue_latency: latency).fetch(:deduplication_expiry_risk)

          assert_nil risk[:queue_latency_seconds]
          assert_nil risk[:queue_latency_to_ttl_ratio]
          assert_equal "unavailable", risk[:status]
        end

        result = snapshot(queue_latency: "not-a-number")
        assert_equal false, result[:sidekiq_available]
        assert_nil result.dig(:deduplication_expiry_risk, :queue_latency_to_ttl_ratio)
        assert_equal "unavailable", result.dig(:deduplication_expiry_risk, :status)
      end

      test "uses the canonical BlockJob marker TTL without a local duplicate" do
        risk = snapshot(queue_latency: 1).fetch(:deduplication_expiry_risk)
        source = Rails.root.join("app/services/layer1/audit/operational_snapshot.rb").read

        assert_equal Layer1::Audit::BlockJob::INITIAL_MARKER_TTL_SECONDS,
          risk[:marker_ttl_seconds]
        assert_includes source, "Layer1::Audit::BlockJob::INITIAL_MARKER_TTL_SECONDS"
        refute_match(/\b(?:3_600|3600)\b/, source)
      end

      test "reports running activity when an audit worker is active" do
        result = snapshot(queue_size: 0, worker_queues: ["layer1_audit"])

        assert_equal "running", result[:activity]
        assert_equal 1, result[:worker_count]
      end

      test "reports running with backlog when queue and worker are active" do
        result = snapshot(queue_size: 4, worker_queues: ["other", "layer1_audit"])

        assert_equal "running", result[:activity]
        assert_equal 4, result[:queue_size]
        assert_equal 1, result[:worker_count]
      end

      test "sidekiq failure is unavailable and never becomes false idle" do
        create_run(height: 160, status: "healthy")
        broken_queue = Object.new
        broken_queue.define_singleton_method(:size) { raise "secret redis endpoint" }

        result =
          OperationalSnapshot.new(
            sidekiq_queue: broken_queue,
            sidekiq_workers: []
          ).call

        assert_equal "unavailable", result[:status]
        assert_equal "unavailable", result[:activity]
        assert_equal false, result[:sidekiq_available]
        assert_nil result[:queue_size]
        assert_nil result[:queue_latency_seconds]
        assert_nil result[:worker_count]
        assert_equal Layer1::Audit::BlockJob::INITIAL_MARKER_TTL_SECONDS,
          result.dig(:deduplication_expiry_risk, :marker_ttl_seconds)
        assert_nil result.dig(:deduplication_expiry_risk, :queue_latency_to_ttl_ratio)
        assert_equal "unavailable", result.dig(:deduplication_expiry_risk, :status)
        assert_equal "sidekiq_error",
                     result.dig(:observability, :sidekiq_error_category)
        refute_includes JSON.generate(result), "secret redis endpoint"
      end

      test "postgresql failure is unavailable rather than no data" do
        failure = ->(*) { raise ActiveRecord::ConnectionNotEstablished, "password=secret" }

        result =
          Layer1AuditRun.stub(:order, failure) do
            snapshot
          end

        assert_equal "unavailable", result[:status]
        assert_equal "unavailable", result[:audit_status]
        assert_equal "unavailable", result[:activity]
        assert_equal false, result[:database_available]
        assert_nil result[:realtime_tip]
        assert_nil result[:latest_run]
        assert_nil result[:highest_healthy_height]
        assert_empty result[:run_history]
        assert_equal "database_error",
                     result.dig(:observability, :database_error_category)
        refute_includes JSON.generate(result), "password=secret"
      end

      test "history is limited to twenty and ordered newest first" do
        22.times do |index|
          create_run(
            height: 200 + index,
            status: %w[healthy failed error running][index % 4],
            created_at: Time.current + index.seconds
          )
        end

        result = snapshot
        heights = result[:run_history].map { |run| run[:audited_height] }

        assert_equal 20, result[:run_history].size
        assert_equal (202..221).to_a.reverse, heights
        assert_equal 20, result.dig(:recent_runs, :sample_size)
      end

      test "serializes all four run states without payloads or issue details" do
        %w[healthy failed error running].each_with_index do |status, index|
          create_run(
            height: 300 + index,
            status: status,
            issues: [{ "private" => "do not expose" }],
            created_at: Time.current + index.seconds
          )
        end

        history = snapshot[:run_history]

        assert_equal %w[running error failed healthy], history.map { |run| run[:status] }
        assert_equal [1, 1, 1, 1], history.map { |run| run[:issues_count] }
        history.each do |run|
          refute run.key?(:issues)
          refute run.key?(:checks)
          refute run.key?(:block_hash)
        end
      end

      test "result is JSON serializable" do
        create_run(height: 400, status: "healthy")

        encoded = JSON.generate(snapshot)

        assert_kind_of String, encoded
        assert_includes encoded, '"audit_status":"healthy"'
        assert_includes encoded, '"deduplication_expiry_risk"'
      end

      test "service SQL is read only" do
        create_run(height: 500, status: "healthy")
        create_tip(505)
        sql = []
        subscriber = lambda do |_name, _start, _finish, _id, payload|
          statement = payload[:sql].to_s
          sql << statement unless payload[:name] == "SCHEMA" || statement.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
        end

        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          snapshot
        end

        assert sql.any?, "expected read queries"
        sql.each do |statement|
          assert_match(/\A\s*SELECT\b/i, statement)
          refute_match(/\b(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|CREATE)\b/i, statement)
        end
      end

      test "service has no Redis Sidekiq mutation scheduling or interface dependency" do
        source =
          Rails.root
            .join("app/services/layer1/audit/operational_snapshot.rb")
            .read

        forbidden = [
          /\bRedis\b/,
          /perform_(?:async|in|later)/,
          /Sidekiq::Client/,
          /\.push\b/,
          /\.delete\b/,
          /OverviewSnapshot/,
          /PipelineController/,
          /StrictPipeline::Scheduler/,
          /Controller/,
          /Presenter/
        ]

        forbidden.each do |pattern|
          refute_match pattern, source
        end
      end

      private

      def snapshot(queue_size: 0, queue_latency: 0.0, worker_queues: [])
        queue = FakeQueue.new(queue_size, queue_latency)
        workers = worker_queues.map { |queue_name| FakeWork.new(queue_name) }

        OperationalSnapshot.new(
          sidekiq_queue: queue,
          sidekiq_workers: workers
        ).call
      end

      def create_run(
        height:,
        status:,
        created_at: Time.current,
        finished_at: Time.current,
        issues: []
      )
        Layer1AuditRun.create!(
          audited_height: height,
          block_hash: "hash-#{height}-#{status}-#{created_at.to_f}",
          status: status,
          checks: {},
          issues: issues,
          started_at: created_at - 1.second,
          finished_at: finished_at,
          created_at: created_at,
          updated_at: created_at
        )
      end

      def create_tip(height)
        BlockBufferModel.create!(
          height: height,
          block_hash: "tip-hash-#{height}",
          status: "processed"
        )
      end
    end
  end
end
