# frozen_string_literal: true

class BtcPriceDaysCatchup
  def self.call(target_day: Date.yesterday, start_day: nil)
    new(target_day: target_day, start_day: start_day).call
  end

  def initialize(target_day:, start_day: nil)
    @target_day = target_day.to_date
    @start_day = start_day&.to_date
  end

  def call
    last_day = BtcPriceDay.maximum(:day)

    from_day =
      if @start_day.present?
        @start_day
      elsif last_day.present?
        last_day + 1.day
      else
        @target_day
      end

    if from_day > @target_day
      return {
        ok: true,
        note: "nothing_to_catch_up",
        from: from_day,
        to: @target_day,
        built: 0
      }
    end

    built = 0
    errors = []

    (from_day..@target_day).each do |day|
      begin
        BtcPriceDayBuilder.call(day: day)
        built += 1
      rescue => e
        errors << { day: day, error: "#{e.class}: #{e.message}" }
      end
    end

    {
      ok: errors.empty?,
      from: from_day,
      to: @target_day,
      built: built,
      errors: errors
    }
  end
end