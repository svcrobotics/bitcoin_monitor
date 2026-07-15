# frozen_string_literal: true

module Layer1
  class PaceSnapshot
    WINDOW_SIZE = 30
    RECENT_HISTORY_SIZE = 10
    QUERY_LIMIT = 90
    STABLE_BACKLOG_DELTA_PER_HOUR = 0.25

    def self.call(current_lag: nil)
      new(current_lag: current_lag).call
    end

    def initialize(current_lag: nil)
      @current_lag = current_lag
    end

    def call
      processed_rows =
        recent_processed_rows

      chronological_rows =
        processed_rows.sort_by(&:height)

      processing_rows =
        processed_rows
          .select { |row| row.duration_ms.present? }
          .sort_by(&:height)
          .last(WINDOW_SIZE)

      network_intervals =
        intervals_from(
          chronological_rows,
          timestamp: :block_time
        )

      ingestion_intervals =
        intervals_from(
          chronological_rows,
          timestamp: :created_at
        )

      certification_intervals =
        intervals_from(
          chronological_rows,
          timestamp: :processed_at
        )

      processing_seconds =
        processing_rows
          .map { |row| seconds(row.duration_ms) }
          .compact

      component_rows =
        processing_rows.last(RECENT_HISTORY_SIZE)

      network =
        interval_snapshot(network_intervals.last(WINDOW_SIZE - 1))

      certification =
        cadence_snapshot(
          certification_intervals.last(WINDOW_SIZE - 1)
        )

      processing =
        processing_snapshot(
          rows: processing_rows,
          seconds_values: processing_seconds
        )

      comparison =
        comparison_snapshot(
          network: network,
          certification: certification,
          processing: processing
        )

      {
        sample: {
          processing_blocks: processing_seconds.size,
          network_intervals:
            network_intervals.last(WINDOW_SIZE - 1).size,
          certification_intervals:
            certification_intervals.last(WINDOW_SIZE - 1).size
        },
        network: network,
        ingestion:
          interval_snapshot(ingestion_intervals.last(WINDOW_SIZE - 1)),
        certification: certification,
        processing: processing,
        components: components_snapshot(component_rows),
        comparison: comparison,
        recent_blocks:
          recent_history(
            rows: chronological_rows,
            processing_rows: processing_rows
          ),
        generated_at: Time.current
      }
    end

    private

    attr_reader :current_lag

    def recent_processed_rows
      BlockBufferModel
        .where(status: "processed", is_orphan: false)
        .where.not(block_time: nil)
        .order(height: :desc)
        .limit(QUERY_LIMIT)
        .to_a
    end

    def intervals_from(rows, timestamp:)
      rows
        .each_cons(2)
        .filter_map do |previous, current|
          next unless current.height.to_i == previous.height.to_i + 1

          previous_time =
            previous.public_send(timestamp)

          current_time =
            current.public_send(timestamp)

          interval =
            interval_seconds(previous_time, current_time)

          next if interval.nil?

          {
            from_height: previous.height,
            to_height: current.height,
            seconds: interval
          }
        end
    end

    def interval_seconds(previous_time, current_time)
      return nil if previous_time.blank? || current_time.blank?

      value =
        current_time.to_f - previous_time.to_f

      return nil unless value.positive?
      return nil if value > 3.days.to_i

      value
    end

    def interval_snapshot(intervals)
      values =
        intervals
          .map { |entry| entry[:seconds] }
          .compact

      {
        median_interval_seconds: median(values),
        average_interval_seconds: average(values),
        blocks_per_hour: blocks_per_hour(median(values))
      }
    end

    def cadence_snapshot(intervals)
      values =
        intervals
          .map { |entry| entry[:seconds] }
          .compact

      recent_values =
        values.last(10)

      reference =
        median(
          recent_values.any? ?
            recent_values :
            values
        )

      {
        last_interval_seconds: values.last,
        median_10_seconds: median(recent_values),
        average_10_seconds: average(recent_values),
        median_30_seconds: median(values),
        average_30_seconds: average(values),
        blocks_per_hour: blocks_per_hour(reference)
      }
    end

    def processing_snapshot(rows:, seconds_values:)
      current =
        current_processing_block

      slowest =
        rows
          .select { |row| row.duration_ms.present? }
          .max_by(&:duration_ms)

      last =
        rows.last

      {
        current_height: current&.height,
        current_elapsed_seconds: current_elapsed_seconds(current),
        last_height: last&.height,
        last_duration_seconds: seconds(last&.duration_ms),
        median_10_seconds: median(seconds_values.last(10)),
        average_10_seconds: average(seconds_values.last(10)),
        median_30_seconds: median(seconds_values),
        average_30_seconds: average(seconds_values),
        minimum_30_seconds: seconds_values.compact.min,
        maximum_30_seconds: seconds_values.compact.max,
        slowest_height: slowest&.height
      }
    end

    def current_processing_block
      BlockBufferModel
        .where(status: "processing", is_orphan: false)
        .order(:height)
        .first
    end

    def current_elapsed_seconds(row)
      return nil unless row

      started_at =
        row.processing_started_at ||
        row.updated_at ||
        row.created_at

      return nil unless started_at

      [
        Time.current.to_f - started_at.to_f,
        0
      ].max
    end

    def components_snapshot(rows)
      components =
        {
          rpc: average_component(rows, :rpc_duration_ms),
          parse: average_component(rows, :parse_duration_ms),
          db: average_component(rows, :db_duration_ms),
          flush: average_component(rows, :flush_duration_ms),
          total: average_component(rows, :duration_ms)
        }

      attributed =
        %i[rpc parse db flush]
          .map { |key| components[key] }
          .compact

      unattributed =
        if components[:total].present? && attributed.any?
          [
            components[:total] - attributed.sum,
            0
          ].max
        end

      flush_percent =
        if components[:total].present? && components[:flush].present? &&
           components[:total].positive?
          (components[:flush] / components[:total] * 100.0).round(1)
        end

      instrumented_total =
        attributed.sum if attributed.any?

      flush_instrumented_percent =
        if instrumented_total.present? && components[:flush].present? &&
           instrumented_total.positive?
          (components[:flush] / instrumented_total * 100.0).round(1)
        end

      dominant_stage =
        %i[rpc parse db flush]
          .filter_map do |stage|
            value = components[stage]
            value.present? ? [stage, value] : nil
          end
          .max_by { |_stage, value| value }
          &.first

      {
        rpc_average_seconds: components[:rpc],
        parse_average_seconds: components[:parse],
        db_average_seconds: components[:db],
        flush_average_seconds: components[:flush],
        unattributed_average_seconds: unattributed,
        average_duration_seconds: components[:total],
        flush_percent: flush_percent,
        flush_total_percent: flush_percent,
        flush_instrumented_percent: flush_instrumented_percent,
        dominant_stage: dominant_stage&.to_s
      }
    end

    def average_component(rows, column)
      values =
        rows
          .map { |row| seconds(row.public_send(column)) }
          .compact

      average(values)
    end

    def comparison_snapshot(
      network:,
      certification:,
      processing:
    )
      network_interval =
        network[:median_interval_seconds]

      internal_processing =
        processing[:median_10_seconds] ||
        processing[:median_30_seconds] ||
        processing[:last_duration_seconds]

      effective_layer1 =
        certification[:median_10_seconds] ||
        certification[:median_30_seconds] ||
        certification[:last_interval_seconds]

      network_bph =
        blocks_per_hour(network_interval)

      layer1_bph =
        blocks_per_hour(effective_layer1)

      backlog_change =
        if network_bph.present? && layer1_bph.present?
          network_bph - layer1_bph
        end

      scheduler_overhead =
        if effective_layer1.present? &&
           internal_processing.present?
          [
            effective_layer1 - internal_processing,
            0
          ].max
        end

      current_lag =
        current_lag_blocks

      {
        pace_ratio:
          pace_ratio(
            layer1_processing: effective_layer1,
            network_interval: network_interval
          ),
        effective_interval_seconds:
          effective_layer1,
        internal_processing_seconds:
          internal_processing,
        scheduler_overhead_seconds:
          scheduler_overhead,
        layer1_blocks_per_hour: layer1_bph,
        network_blocks_per_hour: network_bph,
        backlog_change_per_hour:
          backlog_change&.round(2),
        trend:
          trend(backlog_change),
        estimated_catchup_hours:
          estimated_catchup_hours(
            current_lag: current_lag,
            backlog_change: backlog_change
          ),
        current_lag: current_lag
      }
    end

    def current_lag_blocks
      return current_lag.to_i if current_lag.present?

      tip =
        BlockBufferModel
          .where(is_orphan: false)
          .maximum(:height)

      processed =
        BlockBufferModel
          .where(status: "processed", is_orphan: false)
          .maximum(:height)

      return nil if tip.blank? || processed.blank?

      [
        tip.to_i - processed.to_i,
        0
      ].max
    end

    def recent_history(rows:, processing_rows:)
      processing_by_height =
        processing_rows.index_by(&:height)

      network_intervals =
        intervals_from(rows, timestamp: :block_time)
          .index_by { |entry| entry[:to_height] }

      certification_intervals =
        intervals_from(rows, timestamp: :processed_at)
          .index_by { |entry| entry[:to_height] }

      rows
        .last(RECENT_HISTORY_SIZE)
        .reverse
        .map do |row|
          processing_row =
            processing_by_height[row.height]

          network_interval =
            network_intervals.dig(
              row.height,
              :seconds
            )

          certification_interval =
            certification_intervals.dig(
              row.height,
              :seconds
            )

          processing_duration =
            seconds(processing_row&.duration_ms)

          {
            height: row.height,
            network_interval_seconds:
              network_interval,
            certification_interval_seconds:
              certification_interval,
            processing_duration_seconds:
              processing_duration,
            delta_seconds:
              if network_interval.present? &&
                 certification_interval.present?
                certification_interval -
                  network_interval
              end
          }
        end
    end

    def pace_ratio(layer1_processing:, network_interval:)
      return nil if layer1_processing.blank? || network_interval.blank?
      return nil unless network_interval.positive?

      (layer1_processing / network_interval).round(2)
    end

    def trend(backlog_change)
      return "insufficient_data" if backlog_change.nil?
      return "stable" if backlog_change.abs <= STABLE_BACKLOG_DELTA_PER_HOUR

      backlog_change.positive? ? "falling_behind" : "catching_up"
    end

    def estimated_catchup_hours(current_lag:, backlog_change:)
      return nil if current_lag.blank? || current_lag.to_i <= 0
      return nil if backlog_change.nil?
      return nil unless backlog_change < -STABLE_BACKLOG_DELTA_PER_HOUR

      (current_lag.to_f / backlog_change.abs).round(2)
    end

    def blocks_per_hour(seconds_value)
      return nil if seconds_value.blank? || seconds_value.to_f <= 0

      (3600.0 / seconds_value.to_f).round(2)
    end

    def seconds(milliseconds)
      return nil if milliseconds.blank?

      milliseconds.to_f / 1000.0
    end

    def median(values)
      compact =
        values.compact.sort

      return nil if compact.empty?

      middle =
        compact.length / 2

      if compact.length.odd?
        compact[middle]
      else
        (compact[middle - 1] + compact[middle]) / 2.0
      end
    end

    def average(values)
      compact =
        values.compact

      return nil if compact.empty?

      compact.sum.to_f / compact.length
    end
  end
end
