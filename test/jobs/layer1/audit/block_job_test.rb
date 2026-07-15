# frozen_string_literal: true

require "test_helper"

module Layer1
  module Audit
    class BlockJobTest < ActiveSupport::TestCase
      class FakeRedis
        attr_reader :sets, :evals
        attr_accessor :set_error, :eval_error

        def initialize
          @values = {}
          @sets = []
          @evals = []
        end

        def set(key, value, nx:, ex:)
          raise set_error if set_error

          sets << { key: key, value: value, nx: nx, ex: ex }
          return nil if nx && @values.key?(key)

          @values[key] = value
          true
        end

        def eval(script, keys:, argv:)
          raise eval_error if eval_error

          evals << { script: script, keys: keys, argv: argv }
          key = keys.fetch(0)
          marker = argv.fetch(0)
          return 0 unless @values[key] == marker

          @values.delete(key)
          1
        end

        def mark(key, value = "foreign")
          @values[key] = value
        end

        def value(key)
          @values[key]
        end
      end

      test "declares the dedicated queue and retry limit" do
        options = BlockJob.get_sidekiq_options

        assert_equal :layer1_audit, options["queue"]
        assert_equal 2, options["retry"]
      end

      test "allowed decision audits the normalized height exactly once and returns its result" do
        audit_calls = []
        expected = { ok: false, status: "failed" }

        result =
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, ->(height:) { audit_calls << height; expected }) do
              BlockJob.new.perform("955300")
            end
          end

        assert_same expected, result
        assert_equal [955_300], audit_calls
      end

      test "refused decision never audits and schedules attempt one" do
        audit_calls = []
        scheduled = []

        result =
          with_stubbed(Layer1::AuditBlock, :call, ->(**args) { audit_calls << args }) do
            perform_refused(height: "955301", attempt: 0, scheduled: scheduled)
          end

        assert_empty audit_calls
        assert_equal "deferred", result[:status]
        assert_equal 0, result[:attempt]
        assert_equal 1, result[:next_attempt]
        assert_equal [{ delay: 120, height: 955_301, attempt: 1 }], normalized_schedules(scheduled)
      end

      test "deferred attempts progress from one through five" do
        (0..4).each do |attempt|
          scheduled = []
          result = perform_refused(height: 955_310 + attempt, attempt: attempt, scheduled: scheduled)

          assert_equal attempt + 1, result[:next_attempt]
          assert_equal attempt + 1, scheduled.fetch(0).fetch(:attempt)
        end
      end

      test "attempt five is exhausted without Redis marker or scheduling" do
        redis = FakeRedis.new
        scheduled = []

        result = perform_refused(height: 955_320, attempt: 5, redis: redis, scheduled: scheduled)

        assert_equal "deferred_exhausted", result[:status]
        assert_equal false, result[:scheduled_retry]
        assert_empty redis.sets
        assert_empty scheduled
      end

      test "attempt greater than five is exhausted without scheduling" do
        scheduled = []
        result = perform_refused(height: 955_321, attempt: 8, scheduled: scheduled)

        assert_equal "deferred_exhausted", result[:status]
        assert_equal 8, result[:attempt]
        assert_empty scheduled
      end

      test "delay is bounded to thirty and nine hundred seconds" do
        low = []
        high = []

        low_result = perform_refused(height: 955_330, retry_in: -1, scheduled: low)
        high_result = perform_refused(height: 955_331, retry_in: 1.day, scheduled: high)

        assert_equal 30, low_result[:retry_in].to_i
        assert_equal 30, low.fetch(0).fetch(:delay).to_i
        assert_equal 900, high_result[:retry_in].to_i
        assert_equal 900, high.fetch(0).fetch(:delay).to_i
      end

      test "Redis marker uses NX positive TTL and distinguishes height and attempt" do
        redis = FakeRedis.new

        perform_refused(height: 955_340, attempt: 0, redis: redis)
        perform_refused(height: 955_340, attempt: 1, redis: redis)
        perform_refused(height: 955_341, attempt: 0, redis: redis)

        assert_equal 3, redis.sets.size
        assert redis.sets.all? { |entry| entry[:nx] == true }
        assert redis.sets.all? { |entry| entry[:ex].positive? }
        assert_equal [
          "#{BlockJob::DEFER_KEY_PREFIX}:955340:1",
          "#{BlockJob::DEFER_KEY_PREFIX}:955340:2",
          "#{BlockJob::DEFER_KEY_PREFIX}:955341:1"
        ], redis.sets.map { |entry| entry[:key] }
      end

      test "existing marker prevents duplicate scheduling without deleting it" do
        redis = FakeRedis.new
        key = "#{BlockJob::DEFER_KEY_PREFIX}:955350:1"
        redis.mark(key)
        scheduled = []

        result = perform_refused(height: 955_350, redis: redis, scheduled: scheduled)

        assert_equal "already_scheduled", result[:status]
        assert_equal false, result[:scheduled_retry]
        assert_empty scheduled
        assert_equal "foreign", redis.value(key)
        assert_empty redis.evals
      end

      test "Redis failure propagates and never schedules without a marker" do
        redis = FakeRedis.new
        redis.set_error = Redis::CannotConnectError.new("unavailable")
        scheduled = []

        error = assert_raises(Redis::CannotConnectError) do
          perform_refused(height: 955_360, redis: redis, scheduled: scheduled)
        end

        assert_equal "unavailable", error.message
        assert_empty scheduled
      end

      test "scheduling failure removes only the marker owned by this execution" do
        redis = FakeRedis.new
        scheduling_error = Class.new(StandardError).new("schedule failed")

        raised = assert_raises(scheduling_error.class) do
          perform_refused(height: 955_370, redis: redis, perform_error: scheduling_error)
        end

        marker = redis.sets.fetch(0)
        assert_same scheduling_error, raised
        assert_nil redis.value(marker[:key])
        assert_equal [marker[:key]], redis.evals.fetch(0).fetch(:keys)
        assert_equal [marker[:value]], redis.evals.fetch(0).fetch(:argv)
      end

      test "cleanup failure preserves the original scheduling error and leaves TTL protection" do
        redis = FakeRedis.new
        redis.eval_error = Redis::CommandError.new("cleanup failed")
        scheduling_error = Class.new(StandardError).new("schedule failed")

        raised = assert_raises(scheduling_error.class) do
          perform_refused(height: 955_371, redis: redis, perform_error: scheduling_error)
        end

        marker = redis.sets.fetch(0)
        assert_same scheduling_error, raised
        assert_equal marker[:value], redis.value(marker[:key])
        assert_operator marker[:ex], :>, 0
      end

      test "audit and pipeline errors propagate" do
        audit_error = Class.new(StandardError).new("audit failed")
        pipeline_error = Class.new(StandardError).new("pipeline failed")

        assert_raises(audit_error.class) do
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, ->(**) { raise audit_error }) do
              BlockJob.new.perform(955_380)
            end
          end
        end

        assert_raises(pipeline_error.class) do
          with_stubbed(System::PipelineController, :layer1_heavy_decision, ->(*) { raise pipeline_error }) do
            BlockJob.new.perform(955_380)
          end
        end
      end

      test "height and attempt reject invalid or negative values" do
        ["invalid", -1].each do |height|
          assert_raises(ArgumentError) { BlockJob.new.perform(height) }
        end

        ["invalid", -1].each do |attempt|
          assert_raises(ArgumentError) { BlockJob.new.perform(955_390, attempt) }
        end
      end

      test "job performs no direct SQL and has no forbidden integration dependency" do
        sql = []
        callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, { ok: true }) do
              BlockJob.new.perform(955_400)
            end
          end
        end

        source = File.read(Rails.root.join("app/jobs/layer1/audit/block_job.rb"))
        assert_empty sql.reject { |statement| statement.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i) }
        refute_match(/Layer1AuditController|Procfile|OverviewSnapshot|OperationalSnapshot|StrictWindowRebuilder|StrictPipeline::Scheduler/, source)
        refute_match(/\.create!?\b|\.update!?\b|\.delete!?\b|\.destroy!?\b/, source)
      end

      test "strict window audit remains synchronous and unchanged" do
        source = File.read(Rails.root.join("app/services/layer1/strict_window_rebuilder.rb"))

        assert_match(/Layer1::AuditBlock\.call\(height: height\)/, source)
      end

      private

      def perform_refused(
        height:,
        attempt: 0,
        retry_in: 120.seconds,
        redis: FakeRedis.new,
        scheduled: [],
        perform_error: nil
      )
        decision = {
          allowed: false,
          reason: :layer1_realtime_priority,
          retry_in: retry_in,
          failed_constraints: [:layer1_not_processing]
        }

        with_stubbed(System::PipelineController, :layer1_heavy_decision, decision) do
          with_stubbed(Redis, :new, redis) do
            with_stubbed(
              BlockJob,
              :perform_in,
              lambda do |delay, scheduled_height, scheduled_attempt|
                raise perform_error if perform_error

                scheduled << {
                  delay: delay,
                  height: scheduled_height,
                  attempt: scheduled_attempt
                }
                "jid"
              end
            ) do
              BlockJob.new.perform(height, attempt)
            end
          end
        end
      end

      def with_decision(decision)
        with_stubbed(System::PipelineController, :layer1_heavy_decision, decision) { yield }
      end

      def normalized_schedules(schedules)
        schedules.map do |entry|
          entry.merge(delay: entry.fetch(:delay).to_i)
        end
      end

      def with_stubbed(object, method_name, value = nil)
        original = object.method(method_name)
        replacement = value.respond_to?(:call) ? value : ->(*, **) { value }
        object.define_singleton_method(method_name, &replacement)
        yield
      ensure
        object.define_singleton_method(method_name) do |*args, **kwargs, &block|
          original.call(*args, **kwargs, &block)
        end
      end
    end
  end
end
