# frozen_string_literal: true

module UiBadgesHelper
  def risk_badge_classes(risk_level)
    case risk_level.to_s
    when "high"   then "bg-rose-500/10 border-rose-700/50 text-rose-200"
    when "medium" then "bg-amber-500/10 border-amber-700/50 text-amber-200"
    else               "bg-emerald-500/10 border-emerald-700/50 text-emerald-200"
    end
  end

  def level_badge_classes(level)
    case level&.to_sym
    when :critical then "bg-rose-500/10 border-rose-700/50 text-rose-200"
    when :warning  then "bg-amber-500/10 border-amber-700/50 text-amber-200"
    else                "bg-emerald-500/10 border-emerald-700/50 text-emerald-200"
    end
  end

  def mood_from_level(level)
    case level&.to_sym
    when :critical then "red"
    when :warning  then "amber"
    else                "green"
    end
  end

  def mood_from_alerts(alerts)
    return "green" unless alerts.present?
    return "red"   if alerts.any? { |a| a.level == :critical }
    return "amber" if alerts.any? { |a| a.level == :warning }
    "green"
  end
end
