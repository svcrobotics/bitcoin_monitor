# frozen_string_literal: true

class InflowOutflowPipelineBuilder
  def self.call(day: nil, days_back: nil)
    new(day: day, days_back: days_back).call
  end

  def initialize(day:, days_back:)
    @day = day
    @days_back = days_back
  end

  def call
    result_flow = InflowOutflowBuilder.call(day: @day, days_back: @days_back)
    result_details = InflowOutflowDetailsBuilder.call(day: @day, days_back: @days_back)
    result_behavior = InflowOutflowBehaviorBuilder.call(day: @day, days_back: @days_back)
    result_capital = InflowOutflowCapitalBehaviorBuilder.call(day: @day, days_back: @days_back)

    {
      ok: true,
      flow: result_flow,
      details: result_details,
      behavior: result_behavior,
      capital_behavior: result_capital
    }
  end
end
