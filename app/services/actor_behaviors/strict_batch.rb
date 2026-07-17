# frozen_string_literal: true

module ActorBehaviors
  class StrictBatch
    DEFAULT_LIMIT = 25
    MAX_LIMIT = 500

    def self.call(
      limit: DEFAULT_LIMIT,
      trigger: "manual",
      cooperative_guard: nil
    )
      new(
        limit: limit,
        trigger: trigger,
        cooperative_guard: cooperative_guard
      ).call
    end

    def self.normalize_limit(value)
      Integer(value)
    rescue ArgumentError, TypeError
      DEFAULT_LIMIT
    else
      [[Integer(value), 1].max, MAX_LIMIT].min
    end

    def self.normalize_trigger(value)
      trigger =
        value.to_s.presence || "manual"

      return trigger if ActorBehaviorRun::TRIGGERS.include?(trigger)

      raise ArgumentError, "invalid actor behavior batch trigger: #{trigger}"
    end

    def initialize(
      limit: DEFAULT_LIMIT,
      trigger: "manual",
      cooperative_guard: nil
    )
      @limit =
        self.class.normalize_limit(limit)

      @trigger =
        self.class.normalize_trigger(trigger)

      @cooperative_guard =
        cooperative_guard
    end

    def call
      started_at_monotonic =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      counters =
        Hash.new(0)

      reasons =
        Hash.new(0)

      run =
        create_run!

      selection = nil

      begin
        selection =
          ActorBehaviors::StrictBatchBuilder.call(
            limit: limit
          )

        profiles =
          selection.fetch(:profiles)

        profile_count =
          if profiles.respond_to?(:size)
            profiles.size
          else
            selection.fetch(:missing_selected).to_i +
              selection.fetch(:stale_selected).to_i
          end

        index =
          0

        profiles.each do |profile|
          stop_reason =
            cooperative_stop_reason

          if stop_reason
            remaining =
              [
                profile_count.to_i - index,
                0
              ].max

            counters[:deferred] += remaining
            reasons[reason_key(stop_reason)] += remaining

            Rails.logger.info(
              "[actor_behavior_strict_batch] " \
              "cooperative_stop reason=#{stop_reason} " \
              "remaining=#{remaining}"
            )

            break
          end

          process_profile(
            profile: profile,
            counters: counters,
            reasons: reasons
          )

          index += 1
        end

        result =
          result_hash(
            selection: selection,
            counters: counters,
            reasons: reasons,
            started_at_monotonic: started_at_monotonic
          )

        finish_run!(
          run: run,
          result: result
        )

        result.merge(
          run_id: run.id,
          run_status: run.reload.status
        )
      rescue StandardError => error
        finish_failed_run(
          run: run,
          error: error,
          counters: counters,
          reasons: reasons,
          started_at_monotonic: started_at_monotonic
        )

        raise
      end
    end

    private

    attr_reader :limit, :trigger, :cooperative_guard

    def cooperative_stop_reason
      return nil unless cooperative_guard.respond_to?(:call)

      cooperative_guard.call
    end

    def process_profile(profile:, counters:, reasons:)
      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      case result[:status].to_s
      when "certified"
        count_certified_result(
          result: result,
          counters: counters
        )
      when "deferred"
        counters[:deferred] += 1
        reasons[reason_key(result[:reason])] += 1
      else
        counters[:failed] += 1
        reasons[reason_key(result[:reason] || :unexpected_error)] += 1
      end
    rescue StandardError => error
      counters[:failed] += 1
      reasons[:unexpected_error] += 1

      Rails.logger.warn(
        "[actor_behavior_strict_batch] " \
        "profile_failed " \
        "cluster_id=#{profile.cluster_id} " \
        "actor_profile_id=#{profile.id} " \
        "#{error.class}: #{error.message}"
      )
    end

    def count_certified_result(result:, counters:)
      if result[:created]
        counters[:created] += 1
      elsif result[:updated]
        counters[:updated] += 1
      else
        counters[:unchanged] += 1
      end
    end

    def reason_key(value)
      value.presence&.to_sym || :unknown
    end

    def result_hash(
      selection:,
      counters:,
      reasons:,
      started_at_monotonic:
    )
      {
        ok: counters[:failed].zero?,
        status:
          counters[:failed].zero? ? "completed" : "completed_with_errors",
        requested_limit: limit,
        selected: selection.fetch(:profiles).size,
        missing_selected: selection.fetch(:missing_selected),
        stale_selected: selection.fetch(:stale_selected),
        created: counters[:created],
        updated: counters[:updated],
        unchanged: counters[:unchanged],
        deferred: counters[:deferred],
        failed: counters[:failed],
        duration_ms: elapsed_ms(started_at_monotonic),
        reasons: reasons.sort.to_h
      }
    end

    def create_run!
      ActorBehaviorRun.create!(
        behavior_version:
          ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,
        mode: ActorBehaviors::OperationalSnapshot::MODE,
        trigger: trigger,
        requested_limit: limit,
        status: "running",
        started_at: Time.current,
        actor_profiles_certified_at_start:
          actor_profiles_certified_at_start,
        actor_profile_max_height_at_start:
          actor_profile_max_height_at_start,
        cluster_processed_tip_at_start:
          cluster_processed_tip_at_start
      )
    end

    def finish_run!(run:, result:)
      run.update!(
        status: result.fetch(:status),
        finished_at: Time.current,
        duration_ms: result.fetch(:duration_ms),
        selected: result.fetch(:selected),
        missing_selected: result.fetch(:missing_selected),
        stale_selected: result.fetch(:stale_selected),
        created_count: result.fetch(:created),
        updated_count: result.fetch(:updated),
        unchanged_count: result.fetch(:unchanged),
        deferred_count: result.fetch(:deferred),
        failed_count: result.fetch(:failed),
        reasons: stringify_reason_keys(result.fetch(:reasons))
      )
    end

    def finish_failed_run(
      run:,
      error:,
      counters:,
      reasons:,
      started_at_monotonic:
    )
      selected =
        counters.values_at(
          :created,
          :updated,
          :unchanged,
          :deferred,
          :failed
        ).sum

      run.update_columns(
        status: "failed",
        finished_at: Time.current,
        duration_ms: elapsed_ms(started_at_monotonic),
        selected: selected,
        created_count: counters[:created],
        updated_count: counters[:updated],
        unchanged_count: counters[:unchanged],
        deferred_count: counters[:deferred],
        failed_count: counters[:failed],
        reasons: stringify_reason_keys(reasons),
        error_code: error.class.name,
        error_message: sanitized_error_message(error),
        updated_at: Time.current
      )
    rescue StandardError => finish_error
      Rails.logger.warn(
        "[actor_behavior_strict_batch] " \
        "run_failed_update_failed " \
        "run_id=#{run.id} " \
        "#{finish_error.class}: #{finish_error.message}"
      )
    end

    def actor_profiles_certified_at_start
      # The exact coverage count is a heavy observability metric.
      # It must not block the strict batch execution path.
      nil
    end

    def actor_profile_max_height_at_start
      ActorBehaviors::SnapshotStateScope
        .certified_profiles
        .maximum(:last_computed_height)
    rescue StandardError => error
      log_context_metric_error(
        metric: "actor_profile_max_height_at_start",
        error: error
      )

      nil
    end

    def cluster_processed_tip_at_start
      return nil unless defined?(ClusterProcessedBlock)

      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
    rescue StandardError => error
      log_context_metric_error(
        metric: "cluster_processed_tip_at_start",
        error: error
      )

      nil
    end

    def log_context_metric_error(metric:, error:)
      Rails.logger.warn(
        "[actor_behavior_strict_batch] " \
        "context_metric_unavailable " \
        "metric=#{metric} " \
        "#{error.class}: #{error.message}"
      )
    end

    def stringify_reason_keys(reasons)
      reasons
        .sort
        .to_h
        .transform_keys(&:to_s)
    end

    def sanitized_error_message(error)
      "#{error.class}: #{error.message}"
        .to_s
        .squish
        .first(2_000)
    end

    def elapsed_ms(started_at)
      elapsed =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) - started_at

      (elapsed * 1000).round
    end
  end
end
