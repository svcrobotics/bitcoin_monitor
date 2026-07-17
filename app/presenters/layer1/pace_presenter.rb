# frozen_string_literal: true

module Layer1
  class PacePresenter
    MIN_CATCHUP_RATE_BLOCKS_PER_HOUR = 0.5
    NEUTRAL_DELTA_SECONDS = 10

    def initialize(snapshot)
      @snapshot =
        (snapshot || {}).with_indifferent_access
    end

    def trend
      comparison[:trend].to_s.presence || "insufficient_data"
    end

    def trend_label
      case trend
      when "catching_up"
        "RATTRAPAGE"
      when "falling_behind"
        "RETARD EN HAUSSE"
      when "stable"
        "RETARD STABLE"
      else
        "DONNÉES INSUFFISANTES"
      end
    end

    def trend_classes
      case trend
      when "catching_up"
        "border-emerald-500/40 bg-emerald-950/30 text-emerald-200"
      when "falling_behind"
        "border-amber-500/40 bg-amber-950/30 text-amber-200"
      when "stable"
        "border-sky-500/40 bg-sky-950/30 text-sky-200"
      else
        "border-slate-700 bg-slate-900 text-slate-300"
      end
    end

    def backlog_card_title
      case trend
      when "catching_up"
        "Rattrapage"
      when "falling_behind"
        "Accumulation"
      else
        "Écart de cadence"
      end
    end

    def backlog_rate_label
      value =
        backlog_change_per_hour_abs

      return "—" if value.nil?

      if trend == "stable" && value < 0.1
        "< 0,10 bloc / heure"
      else
        "#{format_decimal(value, precision: 2)} #{bloc_unit(value)} / heure"
      end
    end

    def backlog_subtext
      case trend
      when "catching_up"
        "Le retard diminue actuellement."
      when "falling_behind"
        "Le retard augmente actuellement."
      when "stable"
        "Le retard devrait rester relativement stable."
      else
        "Données insuffisantes pour qualifier l’écart."
      end
    end

    def signed_backlog_rate_label
      value =
        comparison[:backlog_change_per_hour]

      return "—" if value.blank?

      numeric = value.to_f
      sign = numeric.positive? ? "+" : ""

      "#{sign}#{format_decimal(numeric, precision: 2)} blocs / heure"
    end

    def synthesis
      ratio =
        comparison[:pace_ratio]

      rate =
        backlog_change_per_hour_abs

      return insufficient_synthesis if ratio.blank? || rate.nil?

      percent =
        format_percent_difference(ratio)

      case trend
      when "catching_up"
        "Layer1 est environ #{percent} plus rapide que le réseau sur la fenêtre observée. " \
          "Le retard diminue actuellement d’environ #{format_decimal(rate, precision: 2)} " \
          "#{bloc_unit(rate)} par heure."
      when "falling_behind"
        "Layer1 est environ #{percent} plus lent que le réseau sur la fenêtre observée. " \
          "Le retard augmente mécaniquement d’environ #{format_decimal(rate, precision: 2)} " \
          "#{bloc_unit(rate)} par heure."
      when "stable"
        "Les cadences de Layer1 et du réseau sont presque équilibrées. " \
          "La tendance du retard reste incertaine."
      else
        insufficient_synthesis
      end
    end

    def catchup_sentence
      return nil unless trend == "catching_up"

      rate =
        backlog_change_per_hour_abs

      return nil if rate.nil?

      if rate < MIN_CATCHUP_RATE_BLOCKS_PER_HOUR
        return "Cadences presque équilibrées. Estimation de rattrapage trop instable."
      end

      hours =
        comparison[:estimated_catchup_hours]

      return nil if hours.blank?

      "Rattrapage estimé : environ #{human_hours(hours)}. " \
        "Cette estimation reste sensible à la cadence des prochains blocs."
    end

    def network_seconds
      network[:median_interval_seconds]
    end

    def layer1_seconds
      processing[:median_30_seconds] ||
        processing[:median_10_seconds] ||
        processing[:last_duration_seconds]
    end

    def max_bar_seconds
      [
        network_seconds,
        layer1_seconds
      ].compact.map(&:to_f).max
    end

    def bar_width(seconds)
      width_for(
        seconds: seconds,
        max: max_bar_seconds,
        minimum: 6
      )
    end

    def component_values
      {
        rpc: components[:rpc_average_seconds],
        parsing: components[:parse_average_seconds],
        db: components[:db_average_seconds],
        flush: components[:flush_average_seconds],
        autre: components[:unattributed_average_seconds]
      }
    end

    def component_width(seconds)
      width_for(
        seconds: seconds,
        max: component_values.values.compact.map(&:to_f).max,
        minimum: 4
      )
    end

    def history_width(seconds)
      width_for(
        seconds: seconds,
        max: history_max,
        minimum: 5
      )
    end

    def component_label(stage, seconds)
      return "non instrumenté" if seconds.blank?

      format_duration(seconds)
    end

    def dominant_stage
      components[:dominant_stage].to_s.presence || "indisponible"
    end

    def delta_label(delta_seconds)
      return ["Cadence équilibrée", nil] if delta_seconds.blank?

      delta =
        delta_seconds.to_f

      if delta.abs <= NEUTRAL_DELTA_SECONDS
        ["Cadence équilibrée", nil]
      elsif delta.negative?
        [
          "Gain de rattrapage",
          format_duration(delta.abs)
        ]
      else
        [
          "Retard ajouté",
          format_duration(delta)
        ]
      end
    end

    def delta_classes(delta_seconds)
      return "text-slate-400" if delta_seconds.blank?

      delta =
        delta_seconds.to_f

      if delta.abs <= NEUTRAL_DELTA_SECONDS
        "text-slate-400"
      elsif delta.negative?
        "text-emerald-200"
      else
        "text-amber-200"
      end
    end

    def format_duration(seconds)
      return "—" if seconds.blank?

      value =
        seconds.to_f.abs

      total_seconds =
        value.round

      return "< 1 s" if total_seconds.zero? && value.positive?

      minutes =
        total_seconds / 60

      remaining =
        total_seconds % 60

      if minutes.positive?
        "#{minutes} min #{remaining.to_s.rjust(2, '0')} s"
      else
        "#{remaining} s"
      end
    end

    def human_hours(hours)
      total_minutes =
        (hours.to_f * 60).round

      return "#{total_minutes} min" if total_minutes < 60

      total_hours =
        total_minutes / 60

      if total_hours < 24
        minutes =
          total_minutes % 60

        return "#{total_hours} h" if minutes.zero?

        "#{total_hours} h #{minutes} min"
      else
        days =
          total_minutes / 1_440

        remaining_hours =
          ((total_minutes % 1_440) / 60.0).round

        if remaining_hours == 24
          days += 1
          remaining_hours = 0
        end

        return "#{days} jour" if days == 1 && remaining_hours.zero?
        return "#{days} jours" if remaining_hours.zero?

        "#{days} #{days == 1 ? 'jour' : 'jours'} #{remaining_hours} h"
      end
    end

    def format_percent(value)
      value.present? ? "#{format_decimal(value.to_f, precision: 1)} %" : "—"
    end

    private

    attr_reader :snapshot

    def network
      @network ||= (snapshot[:network] || {}).with_indifferent_access
    end

    def processing
      @processing ||= (snapshot[:processing] || {}).with_indifferent_access
    end

    def components
      @components ||= (snapshot[:components] || {}).with_indifferent_access
    end

    def comparison
      @comparison ||= (snapshot[:comparison] || {}).with_indifferent_access
    end

    def recent_blocks
      Array(snapshot[:recent_blocks]).map(&:with_indifferent_access)
    end

    def history_max
      @history_max ||=
        recent_blocks
          .flat_map do |entry|
            [
              entry[:network_interval_seconds],
              entry[:processing_duration_seconds]
            ]
          end
          .compact
          .map(&:to_f)
          .max
    end

    def backlog_change_per_hour_abs
      value =
        comparison[:backlog_change_per_hour]

      return nil if value.blank?

      value.to_f.abs
    end

    def width_for(seconds:, max:, minimum:)
      return 0 if seconds.blank? || max.blank? || max.to_f <= 0

      [
        (seconds.to_f / max.to_f * 100).round,
        minimum
      ].max
    end

    def format_decimal(value, precision:)
      format("%.#{precision}f", value.to_f).tr(".", ",")
    end

    def bloc_unit(value)
      value.to_f.abs < 1.5 ? "bloc" : "blocs"
    end

    def format_percent_difference(ratio)
      percent =
        ((ratio.to_f - 1.0).abs * 100.0)

      rounded =
        percent >= 10 ? percent.round : percent.round(1)

      "#{format_decimal(rounded, precision: rounded.to_i == rounded ? 0 : 1)} %"
    end

    def insufficient_synthesis
      "Les données récentes ne suffisent pas encore à comparer proprement " \
        "la cadence Bitcoin et la certification Layer1."
    end
  end
end
