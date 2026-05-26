class MarketSignalsController < ApplicationController
  def index
    @fed_signal = MarketSignal
      .where(source: "fred", indicator: "FEDFUNDS")
      .order(observed_on: :desc)
      .first

    @dxy_signal = MarketSignal
      .where(source: "fred", indicator: "DTWEXBGS")
      .order(observed_on: :desc)
      .first

    @fed_indicators = MacroIndicator
      .where(source: "fred", code: "FEDFUNDS")
      .order(observed_on: :desc)
      .limit(12)

    @signals = MarketSignal
      .order(observed_on: :desc, created_at: :desc)
      .limit(50)

    @fed_predictions = MarketPrediction
      .where(source: "fred", indicator: "FEDFUNDS")
      .order(predicted_on: :desc)
      .limit(12)

    @dxy_predictions = MarketPrediction
      .where(source: "fred", indicator: "DTWEXBGS")
      .order(predicted_on: :desc)
      .limit(12)

    @fed_success_rate = success_rate_for("FEDFUNDS")
    @dxy_success_rate = success_rate_for("DTWEXBGS")

    @exchange_signal = MarketSignal
      .where(source: "tansa", indicator: "EXCHANGE_CORE_FLOW")
      .order(observed_on: :desc)
      .first

    @exchange_predictions = MarketPrediction
      .where(source: "tansa", indicator: "EXCHANGE_CORE_FLOW")
      .order(predicted_on: :desc)
      .limit(12)

    @exchange_success_rate = success_rate_for_exchange

    @selected_indicator = params[:indicator].presence || "all"

    @history_predictions =
      case @selected_indicator
      when "fed"
        MarketPrediction.where(source: "fred", indicator: "FEDFUNDS")
      when "dollar"
        MarketPrediction.where(source: "fred", indicator: "DTWEXBGS")
      when "exchange"
        MarketPrediction.where(source: "tansa", indicator: "EXCHANGE_CORE_FLOW")
      when "whale"
        MarketPrediction.where(source: "tansa", indicator: "WHALE_CORE_FLOW")
      else
        MarketPrediction.where(indicator: [
          "FEDFUNDS",
          "DTWEXBGS",
          "EXCHANGE_CORE_FLOW",
          "WHALE_CORE_FLOW"
        ])
      end.order(predicted_on: :desc).limit(50)

    @whale_signal = MarketSignal
      .where(source: "tansa", indicator: "WHALE_CORE_FLOW")
      .order(observed_on: :desc)
      .first

    @whale_predictions = MarketPrediction
      .where(source: "tansa", indicator: "WHALE_CORE_FLOW")
      .order(predicted_on: :desc)
      .limit(12)

    @whale_success_rate = success_rate_for_tansa("WHALE_CORE_FLOW")
  end

  private

  def success_rate_for(indicator)
    predictions = MarketPrediction.where(source: "fred", indicator: indicator)
    return 0 if predictions.empty?

    ((predictions.where(result: "success").count.to_f / predictions.count) * 100).round(1)
  end

  def success_rate_for_exchange
    predictions = MarketPrediction.where(source: "tansa", indicator: "EXCHANGE_CORE_FLOW")
    return 0 if predictions.empty?

    ((predictions.where(result: "success").count.to_f / predictions.count) * 100).round(1)
  end

  def success_rate_for_tansa(indicator)
    predictions = MarketPrediction.where(source: "tansa", indicator: indicator)
    return 0 if predictions.empty?

    ((predictions.where(result: "success").count.to_f / predictions.count) * 100).round(1)
  end
end