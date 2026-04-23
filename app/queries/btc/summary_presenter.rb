# app/presenters/btc/summary_presenter.rb
# frozen_string_literal: true

module Btc
  class SummaryPresenter
    class << self
      def call(summary)
        new(summary).call
      end
    end

    def initialize(summary)
      @summary = summary || {}
    end

    def call
      {
        price_now_label: format_price(@summary[:price_now_usd]),
        daily_change_label: format_percent(@summary[:daily_change_pct]),
        ma200_label: format_price(@summary[:ma200_usd]),
        ath_label: format_price(@summary[:ath_usd]),
        drawdown_label: format_percent(@summary[:drawdown_pct]),
        amplitude_30d_label: format_percent(@summary[:amplitude_30d_pct]),
        price_vs_ma200_label: format_percent(@summary[:price_vs_ma200_pct]),
        market_bias_label: humanize_value(@summary[:market_bias]),
        cycle_zone_label: humanize_value(@summary[:cycle_zone]),
        risk_level_label: humanize_value(@summary[:risk_level]),
        source_label: @summary[:source].presence || "Unknown",
        updated_at_label: format_datetime(@summary[:updated_at])
      }
    end

    private

    def format_price(value)
      return "—" if value.blank?

      "$#{format('%.2f', value.to_f).reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
    end

    def format_percent(value)
      return "—" if value.blank?

      "#{format('%.2f', value.to_f)}%"
    end

    def humanize_value(value)
      return "—" if value.blank?

      value.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    end

    def format_datetime(value)
      return "—" if value.blank?

      I18n.l(value, format: :short)
    rescue
      value.to_s
    end
  end
end