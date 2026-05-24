# frozen_string_literal: true

module Actors
  class ExchangeCoreIntradayQuery
    BUCKET_MINUTES = 5

    def self.call(day: Date.current)
      new(day: day).call
    end

    def initialize(day:)
      @day = day.to_date
    end

    def call
      start_time = @day.beginning_of_day
      end_time = [@day.end_of_day, Time.current].min

      rows =
        ExchangeCoreFlowEvent
          .where(event_time: start_time..end_time)
          .group(Arel.sql("date_trunc('hour', event_time) + floor(date_part('minute', event_time) / 5) * interval '5 minutes'"))
          .group(:direction)
          .sum(:amount_btc)

      buckets(start_time, end_time).map do |bucket|
        inflow = rows[[bucket, "inflow"]] || 0.to_d
        outflow = rows[[bucket, "outflow"]] || 0.to_d

        {
          time: bucket,
          inflow_btc: inflow,
          outflow_btc: outflow,
          netflow_btc: inflow - outflow
        }
      end
    end

    private

    def buckets(start_time, end_time)
      current = start_time.change(min: (start_time.min / BUCKET_MINUTES) * BUCKET_MINUTES)

      result = []

      while current <= end_time
        result << current
        current += BUCKET_MINUTES.minutes
      end

      result
    end
  end
end
