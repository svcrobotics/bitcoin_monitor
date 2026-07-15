# frozen_string_literal: true

require "test_helper"

module Layer1
  module Audit
    class BlockJobTest < ActiveSupport::TestCase
      class FakeRedis
        attr_reader :sets, :evals, :expires
        attr_accessor :set_error, :eval_error

        def initialize
          @values = {}
          @ttls = {}
          @sets = []
          @evals = []
          @expires = []
          @mutex = Mutex.new
        end

        def set(key, value, nx:, ex:)
          raise set_error if set_error

          @mutex.synchronize do
            sets << { key: key, value: value, nx: nx, ex: ex }
            return nil if nx && @values.key?(key)

            @values[key] = value
            @ttls[key] = ex
            true
          end
        end

        def eval(script, keys:, argv:)
          raise eval_error if eval_error

          @mutex.synchronize do
            evals << { script: script, keys: keys, argv: argv }
            key = keys.fetch(0)
            marker = argv.fetch(0)
            return 0 unless @values[key] == marker

            if script.include?("expire")
              ttl = Integer(argv.fetch(1))
              @ttls[key] = ttl
              expires << { key: key, marker: marker, ttl: ttl }
            else
              @values.delete(key)
              @ttls.delete(key)
            end

            1
          end
        end

        def mark(key, value = "foreign", ttl: nil)
          @mutex.synchronize do
            @values[key] = value
            @ttls[key] = ttl if ttl
          end
        end

        def value(key)
          @mutex.synchronize { @values[key] }
        end

        def ttl(key)
          @mutex.synchronize { @ttls[key] }
        end
      end

      test "declares the dedicated queue and retry limit" do
        options = BlockJob.get_sidekiq_options

        assert_equal :layer1_audit, options["queue"]
        assert_equal 2, options["retry"]
      end

      test "first enqueue acquires the initial marker and creates one job" do
        redis = FakeRedis.new
        calls = []

        result = enqueue_with(redis: redis, calls: calls, height: "955300")

        assert_equal "enqueued", result[:status]
        assert_equal true, result[:enqueued]
        assert_equal "jid-1", result[:jid]
        assert_equal 955_300, result[:height]
        assert_equal 1, calls.size
        assert_equal [955_300, 0], calls.first.first(2)
        assert_equal redis.sets.first[:value], calls.first.fetch(2)
        assert_equal initial_key(955_300), redis.sets.first[:key]
        assert_equal true, redis.sets.first[:nx]
        assert_equal BlockJob::INITIAL_MARKER_TTL_SECONDS, redis.sets.first[:ex]
      end

      test "second enqueue for the same height reports already enqueued" do
        redis = FakeRedis.new
        calls = []
        results = nil

        with_enqueue_doubles(redis: redis, calls: calls) do
          results = [BlockJob.enqueue(height: 955_301), BlockJob.enqueue(height: 955_301)]
        end

        assert_equal ["enqueued", "already_enqueued"], results.map { |result| result[:status] }
        assert_equal [true, false], results.map { |result| result[:enqueued] }
        assert_equal 1, calls.size
        assert_equal 2, redis.sets.size
      end

      test "different heights acquire independent markers" do
        redis = FakeRedis.new
        calls = []

        with_enqueue_doubles(redis: redis, calls: calls) do
          BlockJob.enqueue(height: 955_302)
          BlockJob.enqueue(height: 955_303)
        end

        assert_equal 2, calls.size
        assert_equal [initial_key(955_302), initial_key(955_303)], redis.sets.map { |entry| entry[:key] }
      end

      test "concurrent acquisition creates only one job" do
        redis = FakeRedis.new
        calls = []
        calls_mutex = Mutex.new
        gate = Queue.new
        results = Queue.new

        with_stubbed(Redis, :new, redis) do
          with_stubbed(
            BlockJob,
            :perform_async,
            lambda do |*args|
              calls_mutex.synchronize { calls << args }
              "jid-concurrent"
            end
          ) do
            threads = 2.times.map do
              Thread.new do
                gate.pop
                results << BlockJob.enqueue(height: 955_304)
              end
            end
            2.times { gate << true }
            threads.each(&:join)
          end
        end

        statuses = 2.times.map { results.pop[:status] }.sort
        assert_equal ["already_enqueued", "enqueued"], statuses
        assert_equal 1, calls.size
      end

      test "Redis failure propagates without enqueue" do
        redis = FakeRedis.new
        redis.set_error = Redis::CannotConnectError.new("unavailable")
        calls = []

        error = assert_raises(Redis::CannotConnectError) do
          enqueue_with(redis: redis, calls: calls, height: 955_305)
        end

        assert_equal "unavailable", error.message
        assert_empty calls
      end

      test "perform async exception deletes the owned marker and propagates" do
        redis = FakeRedis.new
        failure = Class.new(StandardError).new("enqueue failed")

        raised = assert_raises(failure.class) do
          enqueue_with(redis: redis, height: 955_306, perform_error: failure)
        end

        marker = redis.sets.first
        assert_same failure, raised
        assert_nil redis.value(marker[:key])
        assert_equal [marker[:key]], redis.evals.first[:keys]
        assert_equal [marker[:value]], redis.evals.first[:argv]
      end

      test "nil Sidekiq jid deletes marker and raises explicit enqueue error" do
        redis = FakeRedis.new

        error = assert_raises(BlockJob::EnqueueFailed) do
          enqueue_with(redis: redis, height: 955_307, jid: nil)
        end

        assert_match(/did not create/, error.message)
        assert_nil redis.value(initial_key(955_307))
      end

      test "foreign initial marker is never deleted" do
        redis = FakeRedis.new
        failure = Class.new(StandardError).new("enqueue failed")
        key = initial_key(955_308)

        error = assert_raises(failure.class) do
          with_stubbed(Redis, :new, redis) do
            with_stubbed(
              BlockJob,
              :perform_async,
              lambda do |*|
                redis.mark(key, "foreign")
                raise failure
              end
            ) do
              BlockJob.enqueue(height: 955_308)
            end
          end
        end

        assert_same failure, error
        assert_equal "foreign", redis.value(key)
      end

      test "initial marker remains queued and running then terminal success releases it" do
        redis = FakeRedis.new
        calls = []
        enqueue_with(redis: redis, calls: calls, height: 955_309)
        token = calls.first.fetch(2)
        key = initial_key(955_309)
        observed_while_running = nil

        assert_equal token, redis.value(key)

        result =
          with_decision(allowed: true) do
            with_stubbed(Redis, :new, redis) do
              with_stubbed(
                Layer1::AuditBlock,
                :call,
                lambda do |height:|
                  observed_while_running = redis.value(key)
                  { ok: true, height: height }
                end
              ) do
                BlockJob.new.perform(955_309, 0, token)
              end
            end
          end

        assert_equal token, observed_while_running
        assert_equal({ ok: true, height: 955_309 }, result)
        assert_nil redis.value(key)
      end

      test "audit exception keeps initial marker for Sidekiq retry" do
        redis = FakeRedis.new
        calls = []
        enqueue_with(redis: redis, calls: calls, height: 955_310)
        token = calls.first.fetch(2)
        failure = Class.new(StandardError).new("audit failed")

        assert_raises(failure.class) do
          with_decision(allowed: true) do
            with_stubbed(Redis, :new, redis) do
              with_stubbed(Layer1::AuditBlock, :call, ->(**) { raise failure }) do
                BlockJob.new.perform(955_310, 0, token)
              end
            end
          end
        end

        assert_equal token, redis.value(initial_key(955_310))
      end

      test "pipeline exception keeps initial marker for Sidekiq retry" do
        redis = FakeRedis.new
        calls = []
        enqueue_with(redis: redis, calls: calls, height: 955_311)
        token = calls.first.fetch(2)
        failure = Class.new(StandardError).new("pipeline failed")

        assert_raises(failure.class) do
          with_stubbed(Redis, :new, redis) do
            with_stubbed(System::PipelineController, :layer1_heavy_decision, ->(*) { raise failure }) do
              BlockJob.new.perform(955_311, 0, token)
            end
          end
        end

        assert_equal token, redis.value(initial_key(955_311))
      end

      test "deferred report renews initial TTL and transmits the same token" do
        redis = FakeRedis.new
        enqueue_calls = []
        enqueue_with(redis: redis, calls: enqueue_calls, height: 955_312)
        token = enqueue_calls.first.fetch(2)
        schedules = []

        result = perform_refused(
          height: 955_312,
          attempt: 0,
          token: token,
          redis: redis,
          scheduled: schedules
        )

        assert_equal "deferred", result[:status]
        assert_equal token, redis.value(initial_key(955_312))
        assert_equal BlockJob::INITIAL_MARKER_TTL_SECONDS, redis.ttl(initial_key(955_312))
        assert_equal token, schedules.first.fetch(:token)
        assert_equal 1, schedules.first.fetch(:attempt)
        assert_equal initial_key(955_312), redis.expires.first[:key]
        assert_equal deferred_key(955_312, 1), redis.sets.last[:key]
        refute_equal redis.sets.first[:key], redis.sets.last[:key]
      end

      test "lost ownership prevents a deferred report" do
        redis = FakeRedis.new
        token = "owned-token"
        redis.mark(initial_key(955_313), "foreign", ttl: 10)
        schedules = []

        assert_raises(BlockJob::InitialMarkerOwnershipLost) do
          perform_refused(
            height: 955_313,
            token: token,
            redis: redis,
            scheduled: schedules
          )
        end

        assert_empty schedules
        assert_equal "foreign", redis.value(initial_key(955_313))
      end

      test "deferred exhausted releases only the owned initial marker" do
        redis = FakeRedis.new
        token = "terminal-token"
        redis.mark(initial_key(955_314), token, ttl: 3_600)

        result = perform_refused(
          height: 955_314,
          attempt: BlockJob::MAX_DEFER_ATTEMPTS,
          token: token,
          redis: redis
        )

        assert_equal "deferred_exhausted", result[:status]
        assert_equal false, result[:scheduled_retry]
        assert_nil redis.value(initial_key(955_314))
      end

      test "cleanup error never masks initial enqueue failure" do
        redis = FakeRedis.new
        redis.eval_error = Redis::CommandError.new("cleanup failed")
        failure = Class.new(StandardError).new("enqueue failed")

        raised = assert_raises(failure.class) do
          enqueue_with(redis: redis, height: 955_315, perform_error: failure)
        end

        marker = redis.sets.first
        assert_same failure, raised
        assert_equal marker[:value], redis.value(marker[:key])
        assert_equal BlockJob::INITIAL_MARKER_TTL_SECONDS, redis.ttl(marker[:key])
      end

      test "legacy jobs without an initial token remain executable" do
        received = []

        result =
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, ->(height:) { received << height; { ok: true } }) do
              BlockJob.new.perform("955316")
            end
          end

        assert_equal({ ok: true }, result)
        assert_equal [955_316], received
      end

      test "deferred attempts remain bounded and delays remain capped" do
        (0..4).each do |attempt|
          scheduled = []
          result = perform_refused(height: 955_320 + attempt, attempt: attempt, scheduled: scheduled)

          assert_equal attempt + 1, result[:next_attempt]
          assert_equal attempt + 1, scheduled.first[:attempt]
        end

        low = []
        high = []
        low_result = perform_refused(height: 955_330, retry_in: -1, scheduled: low)
        high_result = perform_refused(height: 955_331, retry_in: 1.day, scheduled: high)

        assert_equal 30, low_result[:retry_in].to_i
        assert_equal 30, low.first[:delay].to_i
        assert_equal 900, high_result[:retry_in].to_i
        assert_equal 900, high.first[:delay].to_i
      end

      test "existing deferred marker prevents duplicate report" do
        redis = FakeRedis.new
        redis.mark(deferred_key(955_340, 1), "existing")
        schedules = []

        result = perform_refused(height: 955_340, redis: redis, scheduled: schedules)

        assert_equal "already_scheduled", result[:status]
        assert_equal false, result[:scheduled_retry]
        assert_empty schedules
        assert_equal "existing", redis.value(deferred_key(955_340, 1))
      end

      test "deferred Redis failure propagates without scheduling" do
        redis = FakeRedis.new
        redis.set_error = Redis::CannotConnectError.new("unavailable")
        schedules = []

        assert_raises(Redis::CannotConnectError) do
          perform_refused(height: 955_341, redis: redis, scheduled: schedules)
        end

        assert_empty schedules
      end

      test "job performs no direct SQL and strict window audit remains synchronous" do
        sql = []
        callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, { ok: true }) do
              BlockJob.new.perform(955_350)
            end
          end
        end

        job_source = File.read(Rails.root.join("app/jobs/layer1/audit/block_job.rb"))
        strict_source = File.read(Rails.root.join("app/services/layer1/strict_window_rebuilder.rb"))
        assert_empty sql.reject { |statement| statement.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i) }
        refute_match(/Layer1AuditController|Procfile|StrictPipeline::Scheduler/, job_source)
        assert_match(/Layer1::AuditBlock\.call\(height: height\)/, strict_source)
      end

      test "allowed decision audits the normalized height exactly once and returns its result" do
        audit_calls = []
        expected = { ok: false, status: "failed" }

        result =
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, ->(height:) { audit_calls << height; expected }) do
              BlockJob.new.perform("955400")
            end
          end

        assert_same expected, result
        assert_equal [955_400], audit_calls
      end

      test "refused decision never audits and schedules attempt one" do
        audit_calls = []
        scheduled = []

        result =
          with_stubbed(Layer1::AuditBlock, :call, ->(**args) { audit_calls << args }) do
            perform_refused(height: "955401", attempt: 0, scheduled: scheduled)
          end

        assert_empty audit_calls
        assert_equal "deferred", result[:status]
        assert_equal 1, scheduled.size
        assert_equal 1, scheduled.first[:attempt]
        assert_equal 955_401, scheduled.first[:height]
      end

      test "deferred attempts progress from one through five" do
        (0..4).each do |attempt|
          scheduled = []
          result = perform_refused(height: 955_410 + attempt, attempt: attempt, scheduled: scheduled)

          assert_equal attempt + 1, result[:next_attempt]
          assert_equal attempt + 1, scheduled.first[:attempt]
        end
      end

      test "attempt five is exhausted without Redis marker or scheduling" do
        redis = FakeRedis.new
        scheduled = []

        result = perform_refused(height: 955_420, attempt: 5, redis: redis, scheduled: scheduled)

        assert_equal "deferred_exhausted", result[:status]
        assert_empty redis.sets
        assert_empty scheduled
      end

      test "attempt greater than five is exhausted without scheduling" do
        scheduled = []
        result = perform_refused(height: 955_421, attempt: 8, scheduled: scheduled)

        assert_equal "deferred_exhausted", result[:status]
        assert_equal 8, result[:attempt]
        assert_empty scheduled
      end

      test "delay is bounded to thirty and nine hundred seconds" do
        low = []
        high = []

        low_result = perform_refused(height: 955_430, retry_in: -1, scheduled: low)
        high_result = perform_refused(height: 955_431, retry_in: 1.day, scheduled: high)

        assert_equal 30, low_result[:retry_in].to_i
        assert_equal 30, low.first[:delay].to_i
        assert_equal 900, high_result[:retry_in].to_i
        assert_equal 900, high.first[:delay].to_i
      end

      test "Redis marker uses NX positive TTL and distinguishes height and attempt" do
        redis = FakeRedis.new

        perform_refused(height: 955_440, attempt: 0, redis: redis)
        perform_refused(height: 955_440, attempt: 1, redis: redis)
        perform_refused(height: 955_441, attempt: 0, redis: redis)

        assert redis.sets.all? { |entry| entry[:nx] && entry[:ex].positive? }
        assert_equal [
          deferred_key(955_440, 1),
          deferred_key(955_440, 2),
          deferred_key(955_441, 1)
        ], redis.sets.map { |entry| entry[:key] }
      end

      test "existing marker prevents duplicate scheduling without deleting it" do
        redis = FakeRedis.new
        key = deferred_key(955_450, 1)
        redis.mark(key, "foreign")
        scheduled = []

        result = perform_refused(height: 955_450, redis: redis, scheduled: scheduled)

        assert_equal "already_scheduled", result[:status]
        assert_empty scheduled
        assert_equal "foreign", redis.value(key)
      end

      test "Redis failure propagates and never schedules without a marker" do
        redis = FakeRedis.new
        redis.set_error = Redis::CannotConnectError.new("unavailable")
        scheduled = []

        assert_raises(Redis::CannotConnectError) do
          perform_refused(height: 955_460, redis: redis, scheduled: scheduled)
        end

        assert_empty scheduled
      end

      test "scheduling failure removes only the marker owned by this execution" do
        redis = FakeRedis.new
        failure = Class.new(StandardError).new("schedule failed")

        raised = assert_raises(failure.class) do
          perform_refused(height: 955_470, redis: redis, perform_error: failure)
        end

        marker = redis.sets.first
        assert_same failure, raised
        assert_nil redis.value(marker[:key])
        assert_equal [marker[:value]], redis.evals.first[:argv]
      end

      test "cleanup failure preserves the original scheduling error and leaves TTL protection" do
        redis = FakeRedis.new
        redis.eval_error = Redis::CommandError.new("cleanup failed")
        failure = Class.new(StandardError).new("schedule failed")

        raised = assert_raises(failure.class) do
          perform_refused(height: 955_471, redis: redis, perform_error: failure)
        end

        marker = redis.sets.first
        assert_same failure, raised
        assert_equal marker[:value], redis.value(marker[:key])
        assert_operator marker[:ex], :>, 0
      end

      test "audit and pipeline errors propagate" do
        audit_error = Class.new(StandardError).new("audit failed")
        pipeline_error = Class.new(StandardError).new("pipeline failed")

        assert_raises(audit_error.class) do
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, ->(**) { raise audit_error }) do
              BlockJob.new.perform(955_480)
            end
          end
        end

        assert_raises(pipeline_error.class) do
          with_stubbed(System::PipelineController, :layer1_heavy_decision, ->(*) { raise pipeline_error }) do
            BlockJob.new.perform(955_480)
          end
        end
      end

      test "height and attempt reject invalid or negative values" do
        ["invalid", -1].each do |height|
          assert_raises(ArgumentError) { BlockJob.new.perform(height) }
          assert_raises(ArgumentError) { BlockJob.enqueue(height: height) }
        end

        ["invalid", -1].each do |attempt|
          assert_raises(ArgumentError) { BlockJob.new.perform(955_490, attempt) }
        end
      end

      test "job performs no direct SQL and has no forbidden integration dependency" do
        source = File.read(Rails.root.join("app/jobs/layer1/audit/block_job.rb"))

        refute_match(/Layer1AuditController|Procfile|OverviewSnapshot|OperationalSnapshot|StrictPipeline::Scheduler/, source)
        refute_match(/\.create!?\b|\.update!?\b|\.destroy!?\b/, source)
      end

      test "strict window audit remains synchronous and unchanged" do
        source = File.read(Rails.root.join("app/services/layer1/strict_window_rebuilder.rb"))

        assert_match(/Layer1::AuditBlock\.call\(height: height\)/, source)
      end

      test "records an already enqueued event exactly once" do
        redis = FakeRedis.new
        redis.mark(initial_key(956_000), "existing")
        events = []

        result = with_recorded_events(events) do
          enqueue_with(redis: redis, height: 956_000)
        end

        assert_equal "already_enqueued", result[:status]
        assert_equal [
          {
            event_type: :already_enqueued,
            severity: :info,
            audited_height: 956_000,
            metadata: {}
          }
        ], events
      end

      test "already enqueued result survives recorder failure without sensitive logging" do
        redis = FakeRedis.new
        redis.mark(initial_key(956_001), "existing")
        recorder_error = RuntimeError.new("token=secret redis_key=private payload=hidden")
        warnings = []

        result = with_recorder_failure(recorder_error, warnings: warnings) do
          enqueue_with(redis: redis, height: 956_001)
        end

        assert_equal "already_enqueued", result[:status]
        assert_equal false, result[:enqueued]
        assert_equal 1, warnings.size
        assert_safe_operational_log(warnings.first, event_type: :already_enqueued)
      end

      test "records lost initial marker ownership exactly once" do
        redis = FakeRedis.new
        redis.mark(initial_key(956_002), "foreign")
        events = []

        error = assert_raises(BlockJob::InitialMarkerOwnershipLost) do
          with_recorded_events(events) do
            perform_refused(height: 956_002, token: "owned", redis: redis)
          end
        end

        assert_match(/956002/, error.message)
        assert_equal [
          {
            event_type: :initial_marker_ownership_lost,
            severity: :critical,
            audited_height: 956_002,
            error_class: "Layer1::Audit::BlockJob::InitialMarkerOwnershipLost",
            metadata: {}
          }
        ], events
      end

      test "lost ownership remains the error when its recorder fails" do
        redis = FakeRedis.new
        redis.mark(initial_key(956_003), "foreign")
        recorder_error = RuntimeError.new("token=secret")
        warnings = []

        error = assert_raises(BlockJob::InitialMarkerOwnershipLost) do
          with_recorder_failure(recorder_error, warnings: warnings) do
            perform_refused(height: 956_003, token: "owned", redis: redis)
          end
        end

        assert_match(/956003/, error.message)
        assert_equal 1, warnings.size
        assert_safe_operational_log(warnings.first, event_type: :initial_marker_ownership_lost)
      end

      test "records Redis renewal failure exactly once and preserves the error" do
        redis = FakeRedis.new
        renewal_error = Redis::CommandError.new("renewal secret")
        redis.eval_error = renewal_error
        events = []

        raised = assert_raises(Redis::CommandError) do
          with_recorded_events(events) do
            perform_refused(height: 956_004, token: "owned", redis: redis)
          end
        end

        assert_same renewal_error, raised
        assert_equal [
          {
            event_type: :marker_renewal_failed,
            severity: :error,
            audited_height: 956_004,
            error_class: "Redis::CommandError",
            metadata: {}
          }
        ], events
      end

      test "renewal error remains identical when its recorder fails" do
        redis = FakeRedis.new
        renewal_error = Redis::CommandError.new("renewal secret")
        redis.eval_error = renewal_error
        warnings = []

        raised = assert_raises(Redis::CommandError) do
          with_recorder_failure(RuntimeError.new("payload=hidden"), warnings: warnings) do
            perform_refused(height: 956_005, token: "owned", redis: redis)
          end
        end

        assert_same renewal_error, raised
        assert_equal 1, warnings.size
        assert_safe_operational_log(warnings.first, event_type: :marker_renewal_failed)
      end

      test "records deferred exhaustion exactly once" do
        events = []

        result = with_recorded_events(events) do
          perform_refused(height: 956_006, attempt: BlockJob::MAX_DEFER_ATTEMPTS)
        end

        assert_equal "deferred_exhausted", result[:status]
        assert_equal [
          {
            event_type: :deferred_exhausted,
            severity: :warning,
            audited_height: 956_006,
            defer_attempt: BlockJob::MAX_DEFER_ATTEMPTS,
            metadata: {}
          }
        ], events
      end

      test "deferred exhaustion result survives recorder failure" do
        warnings = []

        result = with_recorder_failure(RuntimeError.new("backtrace=hidden"), warnings: warnings) do
          perform_refused(height: 956_007, attempt: BlockJob::MAX_DEFER_ATTEMPTS)
        end

        assert_equal "deferred_exhausted", result[:status]
        assert_equal false, result[:scheduled_retry]
        operational_warnings = warnings.grep(/operational_event_recording_failed/)
        assert_equal 1, operational_warnings.size
        assert_safe_operational_log(operational_warnings.first, event_type: :deferred_exhausted)
      end

      test "records initial enqueue marker cleanup failure exactly once" do
        redis = FakeRedis.new
        cleanup_error = Redis::CommandError.new("cleanup secret")
        enqueue_error = Class.new(StandardError).new("enqueue secret")
        redis.eval_error = cleanup_error
        events = []

        raised = assert_raises(enqueue_error.class) do
          with_recorded_events(events) do
            enqueue_with(redis: redis, height: 956_008, perform_error: enqueue_error)
          end
        end

        assert_same enqueue_error, raised
        assert_equal [
          {
            event_type: :marker_cleanup_failed,
            severity: :error,
            audited_height: 956_008,
            error_class: "Redis::CommandError",
            metadata: {}
          }
        ], events
      end

      test "cleanup recorder failure never masks the enqueue error or logs secrets" do
        redis = FakeRedis.new
        redis.eval_error = Redis::CommandError.new("cleanup secret")
        enqueue_error = Class.new(StandardError).new("enqueue secret")
        warnings = []

        raised = assert_raises(enqueue_error.class) do
          with_recorder_failure(RuntimeError.new("token=hidden"), warnings: warnings) do
            enqueue_with(redis: redis, height: 956_009, perform_error: enqueue_error)
          end
        end

        assert_same enqueue_error, raised
        assert_equal 2, warnings.size
        assert_safe_operational_log(
          warnings.find { |message| message.include?("operational_event_recording_failed") },
          event_type: :marker_cleanup_failed
        )
        warnings.each do |message|
          refute_match(/token=hidden|cleanup secret|enqueue secret|redis_key|payload|backtrace/i, message)
        end
      end

      test "records deferred marker cleanup failure with the planned attempt" do
        redis = FakeRedis.new
        redis.eval_error = Redis::CommandError.new("cleanup secret")
        scheduling_error = Class.new(StandardError).new("schedule secret")
        events = []

        raised = assert_raises(scheduling_error.class) do
          with_recorded_events(events) do
            perform_refused(height: 956_010, attempt: 2, redis: redis, perform_error: scheduling_error)
          end
        end

        assert_same scheduling_error, raised
        assert_equal [
          {
            event_type: :marker_cleanup_failed,
            severity: :error,
            audited_height: 956_010,
            defer_attempt: 3,
            error_class: "Redis::CommandError",
            metadata: {}
          }
        ], events
      end

      test "records terminal marker release failure and preserves the Redis error" do
        redis = FakeRedis.new
        cleanup_error = Redis::CommandError.new("release secret")
        redis.eval_error = cleanup_error
        events = []

        raised = assert_raises(Redis::CommandError) do
          with_recorded_events(events) do
            with_decision(allowed: true) do
              with_stubbed(Redis, :new, redis) do
                with_stubbed(Layer1::AuditBlock, :call, { ok: true }) do
                  BlockJob.new.perform(956_011, 0, "owned")
                end
              end
            end
          end
        end

        assert_same cleanup_error, raised
        assert_equal [
          {
            event_type: :marker_cleanup_failed,
            severity: :error,
            audited_height: 956_011,
            defer_attempt: nil,
            error_class: "Redis::CommandError",
            metadata: {}
          }
        ], events
      end

      test "does not record events on unrelated successful and exceptional paths" do
        events = []
        redis = FakeRedis.new

        with_recorded_events(events) do
          enqueue_with(redis: redis, height: 956_012)
          with_decision(allowed: true) do
            with_stubbed(Layer1::AuditBlock, :call, { ok: true }) do
              BlockJob.new.perform(956_013)
            end
          end
          perform_refused(height: 956_014)

          assert_raises(RuntimeError) do
            with_stubbed(System::PipelineController, :layer1_heavy_decision, ->(*) { raise "pipeline" }) do
              BlockJob.new.perform(956_015)
            end
          end
          assert_raises(RuntimeError) do
            with_decision(allowed: true) do
              with_stubbed(Layer1::AuditBlock, :call, ->(**) { raise "audit" }) do
                BlockJob.new.perform(956_016)
              end
            end
          end
        end

        assert_empty events
      end

      test "event attributes and logs never contain marker secrets" do
        redis = FakeRedis.new
        redis.mark(initial_key(956_017), "foreign-token")
        events = []

        assert_raises(BlockJob::InitialMarkerOwnershipLost) do
          with_recorded_events(events) do
            perform_refused(height: 956_017, token: "owned-token", redis: redis)
          end
        end

        serialized = JSON.generate(events)
        refute_match(/owned-token|foreign-token|redis_key|payload|backtrace|message/i, serialized)
        assert_equal %i[audited_height error_class event_type metadata severity].sort,
          events.first.keys.sort
      end

      private

      def with_recorded_events(events)
        with_stubbed(
          Layer1::Audit::OperationalEventRecorder,
          :call,
          lambda do |**attributes|
            events << attributes
            Layer1AuditOperationalEvent.new(attributes)
          end
        ) { yield }
      end

      def with_recorder_failure(error, warnings:)
        with_stubbed(Rails.logger, :warn, ->(message) { warnings << message }) do
          with_stubbed(Layer1::Audit::OperationalEventRecorder, :call, ->(**) { raise error }) do
            yield
          end
        end
      end

      def assert_safe_operational_log(message, event_type:)
        assert_includes message, "operational_event_recording_failed"
        assert_includes message, "event_type=#{event_type}"
        assert_includes message, "recorder_error_class="
        refute_match(/token|redis_key|payload|backtrace|secret|message=/i, message)
      end

      def enqueue_with(redis:, height:, calls: [], jid: "jid-1", perform_error: nil)
        with_enqueue_doubles(redis: redis, calls: calls, jid: jid, perform_error: perform_error) do
          BlockJob.enqueue(height: height)
        end
      end

      def with_enqueue_doubles(redis:, calls:, jid: "jid-1", perform_error: nil)
        with_stubbed(Redis, :new, redis) do
          with_stubbed(
            BlockJob,
            :perform_async,
            lambda do |*args|
              raise perform_error if perform_error

              calls << args
              jid
            end
          ) do
            yield
          end
        end
      end

      def perform_refused(
        height:,
        attempt: 0,
        token: nil,
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
              lambda do |delay, scheduled_height, scheduled_attempt, scheduled_token|
                raise perform_error if perform_error

                scheduled << {
                  delay: delay,
                  height: scheduled_height,
                  attempt: scheduled_attempt,
                  token: scheduled_token
                }
                "jid-deferred"
              end
            ) do
              BlockJob.new.perform(height, attempt, token)
            end
          end
        end
      end

      def with_decision(decision)
        with_stubbed(System::PipelineController, :layer1_heavy_decision, decision) { yield }
      end

      def initial_key(height)
        "#{BlockJob::INITIAL_KEY_PREFIX}:#{height}"
      end

      def deferred_key(height, attempt)
        "#{BlockJob::DEFER_KEY_PREFIX}:#{height}:#{attempt}"
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
