# frozen_string_literal: true

module ExchangeLike
  class ScanRangeResolver
    Result = Struct.new(
      :mode,
      :start_height,
      :end_height,
      :best_height,
      :cursor_last_blockheight,
      keyword_init: true
    ) do
      def empty?
        start_height.nil? || end_height.nil? || start_height > end_height
      end

      def blocks_count
        return 0 if empty?

        end_height - start_height + 1
      end
    end

    def initialize(
      best_height:,
      cursor_name:,
      days_back: nil,
      blocks_back: nil,
      initial_blocks_back: 50,
      blocks_per_day: 144,
      reset: false
    )
      @best_height = best_height.to_i
      @cursor_name = cursor_name
      @days_back = days_back
      @blocks_back = blocks_back
      @initial_blocks_back = initial_blocks_back.to_i
      @blocks_per_day = blocks_per_day.to_i
      @reset = !!reset

      @days_back_explicit = !days_back.nil?
      @blocks_back_explicit = !blocks_back.nil?
    end

    def call
      cursor = ScannerCursor.find_or_create_by!(name: @cursor_name)
      cursor_last_blockheight = cursor.last_blockheight

      return resolve_manual(cursor_last_blockheight) if manual_mode?

      resolve_incremental(cursor_last_blockheight)
    end

    private

    def manual_mode?
      @blocks_back_explicit || @days_back_explicit || @reset
    end

    def resolve_manual(cursor_last_blockheight)
      if @blocks_back.present? && @blocks_back.to_i.positive?
        start_height = [0, @best_height - @blocks_back.to_i + 1].max

        return Result.new(
          mode: :manual_blocks_back,
          start_height: start_height,
          end_height: @best_height,
          best_height: @best_height,
          cursor_last_blockheight: cursor_last_blockheight
        )
      end

      if @days_back.present? && @days_back.to_i.positive?
        computed_blocks_back = [1, @days_back.to_i * @blocks_per_day].max
        start_height = [0, @best_height - computed_blocks_back + 1].max

        return Result.new(
          mode: :manual_days_back,
          start_height: start_height,
          end_height: @best_height,
          best_height: @best_height,
          cursor_last_blockheight: cursor_last_blockheight
        )
      end

      # reset=true sans fenêtre explicite
      start_height = [0, @best_height - @initial_blocks_back + 1].max

      Result.new(
        mode: :manual_reset,
        start_height: start_height,
        end_height: @best_height,
        best_height: @best_height,
        cursor_last_blockheight: cursor_last_blockheight
      )
    end

    def resolve_incremental(cursor_last_blockheight)
      start_height =
        if cursor_last_blockheight.present?
          cursor_last_blockheight.to_i + 1
        else
          [0, @best_height - @initial_blocks_back + 1].max
        end

      Result.new(
        mode: :incremental,
        start_height: start_height,
        end_height: @best_height,
        best_height: @best_height,
        cursor_last_blockheight: cursor_last_blockheight
      )
    end
  end
end