# frozen_string_literal: true

require "bigdecimal"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"
require_relative "project_block"

module AddressUtxoStats
  class SequentialRunner
    DEFAULT_LIMIT =
      1

    class DefaultClusterCheckpointSource
      def initialize(model_name: "ClusterProcessedBlock")
        @model_name =
          model_name
      end

      def available?
        model.present?
      end

      def processed_from(from_height:, limit:)
        return nil unless model

        scope =
          model
            .where(status: "processed")
            .order(:height)

        if from_height
          scope =
            scope.where(
              "height >= ?",
              from_height
            )
        end

        scope.limit(limit).to_a
      end

      private

      attr_reader :model_name

      def model
        @model ||=
          model_name.safe_constantize
      end
    end

    def self.call(**attributes)
      new(**attributes).call
    end

    def initialize(
      from_height: nil,
      limit: DEFAULT_LIMIT,
      max_runtime_seconds: nil,
      cluster_checkpoint_source: DefaultClusterCheckpointSource.new,
      project_block: AddressUtxoStats::ProjectBlock,
      clock: nil
    )
      @from_height =
        integer_or_nil(
          from_height
        )

      @limit =
        Integer(limit)

      raise(
        ArgumentError,
        "limit must be greater than zero"
      ) unless @limit.positive?

      @max_runtime_seconds =
        decimal_or_nil(
          max_runtime_seconds
        )

      @cluster_checkpoint_source =
        cluster_checkpoint_source

      @project_block =
        project_block

      @clock =
        clock ||
        lambda do
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )
        end
    end

    def call
      started_at =
        monotonic_seconds

      state =
        initial_state(
          started_at
        )

      return state if
        state[:status] == :blocked

      run(
        state,
        started_at
      )
    rescue StandardError => error
      failed_result(
        error,
        started_at: started_at
      )
    end

    private

    attr_reader(
      :from_height,
      :limit,
      :max_runtime_seconds,
      :cluster_checkpoint_source,
      :project_block,
      :clock
    )

    def initial_state(started_at)
      unless source_available?
        return base_result(
          ok: false,
          status: :blocked,
          next_expected_height: from_height,
          stopped_reason: :cluster_checkpoint_source_unavailable,
          started_at: started_at
        )
      end

      expected_height =
        initial_expected_height

      unless expected_height
        return base_result(
          ok: true,
          status: :completed,
          next_expected_height: nil,
          stopped_reason: :no_cluster_checkpoint,
          started_at: started_at
        )
      end

      base_result(
        ok: true,
        status: :completed,
        next_expected_height: expected_height,
        stopped_reason: nil,
        started_at: started_at
      )
    end

    def run(state, started_at)
      result =
        state

      while result.fetch(:processed_count) < limit
        if result.fetch(:processed_count).positive? &&
           runtime_budget_reached?(started_at)
          return result.merge(
            stopped_reason: :runtime_budget_reached,
            duration_ms: elapsed_ms(started_at)
          )
        end

        checkpoint =
          next_cluster_checkpoint(
            result.fetch(:next_expected_height)
          )

        unless checkpoint
          return result.merge(
            stopped_reason: :no_cluster_checkpoint,
            duration_ms: elapsed_ms(started_at)
          )
        end

        validation =
          validate_cluster_checkpoint(
            checkpoint,
            expected_height:
              result.fetch(:next_expected_height)
          )

        if validation
          return result.merge(
            ok: false,
            status: :blocked,
            stopped_reason: validation.fetch(:reason),
            error: validation,
            duration_ms: elapsed_ms(started_at)
          )
        end

        projection =
          project_block.call(
            height: checkpoint.height.to_i,
            block_hash: checkpoint.block_hash
          )

        result =
          record_projection(
            result,
            projection
          )

        case projection[:status].to_s
        when "completed", "already_completed"
          next
        when "blocked"
          return result.merge(
            ok: false,
            status: :blocked,
            stopped_reason: :project_block_blocked,
            blocking_result: projection,
            duration_ms: elapsed_ms(started_at)
          )
        when "failed"
          return result.merge(
            ok: false,
            status: :failed,
            stopped_reason: :project_block_failed,
            blocking_result: projection,
            duration_ms: elapsed_ms(started_at)
          )
        else
          return result.merge(
            ok: false,
            status: :failed,
            stopped_reason: :project_block_failed,
            blocking_result: projection,
            duration_ms: elapsed_ms(started_at)
          )
        end
      end

      result.merge(
        stopped_reason: :limit_reached,
        duration_ms: elapsed_ms(started_at)
      )
    rescue StandardError => error
      failed_result(
        error,
        started_at: started_at,
        partial_result: result
      )
    end

    def source_available?
      return cluster_checkpoint_source.available? if
        cluster_checkpoint_source.respond_to?(:available?)

      true
    end

    def initial_expected_height
      return from_height if from_height

      completed_height =
        AddressUtxoProjectionBlock
          .completed
          .maximum(:height)

      return completed_height.to_i + 1 if completed_height

      first =
        cluster_checkpoints_from(
          nil,
          fetch_limit: 1
        ).first

      first&.height&.to_i
    end

    def next_cluster_checkpoint(expected_height)
      cluster_checkpoints_from(
        expected_height,
        fetch_limit: 1
      ).first
    end

    def cluster_checkpoints_from(start_height, fetch_limit:)
      checkpoints =
        if cluster_checkpoint_source.respond_to?(:processed_from)
          cluster_checkpoint_source.processed_from(
            from_height: start_height,
            limit: fetch_limit
          )
        else
          cluster_checkpoint_source.call(
            from_height: start_height,
            limit: fetch_limit
          )
        end

      Array(checkpoints)
    end

    def validate_cluster_checkpoint(checkpoint, expected_height:)
      actual_height =
        integer_or_nil(
          checkpoint.height
        )

      unless actual_height
        return {
          code: :cluster_checkpoint_height_missing,
          reason: :cluster_checkpoint_height_missing,
          expected_height: expected_height
        }
      end

      if actual_height != expected_height
        return {
          code: :cluster_height_gap,
          reason: :cluster_height_gap,
          expected_height: expected_height,
          actual_height: actual_height
        }
      end

      unless checkpoint.status.to_s == "processed"
        return {
          code: :cluster_checkpoint_not_processed,
          reason: :cluster_checkpoint_not_processed,
          expected_height: expected_height,
          actual_height: actual_height
        }
      end

      if checkpoint.block_hash.blank?
        return {
          code: :cluster_checkpoint_hash_missing,
          reason: :cluster_checkpoint_hash_missing,
          expected_height: expected_height,
          actual_height: actual_height
        }
      end

      nil
    end

    def record_projection(result, projection)
      height =
        projection.fetch(:height).to_i

      completed_increment =
        projection[:status].to_s == "completed" ? 1 : 0

      already_completed_increment =
        projection[:status].to_s == "already_completed" ? 1 : 0

      result.merge(
        processed_count:
          result.fetch(:processed_count) + 1,
        completed_count:
          result.fetch(:completed_count) +
          completed_increment,
        already_completed_count:
          result.fetch(:already_completed_count) +
          already_completed_increment,
        attempted_heights:
          result.fetch(:attempted_heights) + [height],
        results:
          result.fetch(:results) + [projection],
        next_expected_height:
          height + 1
      )
    end

    def base_result(
      ok:,
      status:,
      next_expected_height:,
      stopped_reason:,
      started_at:
    )
      {
        ok: ok,
        status: status,
        from_height: from_height,
        next_expected_height: next_expected_height,
        requested_limit: limit,
        processed_count: 0,
        completed_count: 0,
        already_completed_count: 0,
        attempted_heights: [],
        results: [],
        stopped_reason: stopped_reason,
        duration_ms: elapsed_ms(started_at)
      }
    end

    def failed_result(
      error,
      started_at:,
      partial_result: nil
    )
      base =
        partial_result ||
        base_result(
          ok: false,
          status: :failed,
          next_expected_height: from_height,
          stopped_reason: nil,
          started_at: started_at
        )

      base.merge(
        ok: false,
        status: :failed,
        stopped_reason: :project_block_failed,
        error: {
          class: error.class.name,
          message: error.message
        },
        duration_ms: elapsed_ms(started_at)
      )
    end

    def runtime_budget_reached?(started_at)
      return false unless max_runtime_seconds

      monotonic_seconds - started_at >=
        max_runtime_seconds
    end

    def monotonic_seconds
      clock.call
    end

    def elapsed_ms(started_at)
      (
        (
          monotonic_seconds -
          started_at
        ) * 1000
      ).round
    end

    def integer_or_nil(value)
      return nil if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def decimal_or_nil(value)
      return nil if value.nil?

      decimal =
        BigDecimal(value.to_s)

      decimal.positive? ? decimal : nil
    end
  end
end
