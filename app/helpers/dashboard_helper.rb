module DashboardHelper

  # LABEL : texte affiché dans le badge
  def token_label(score)
    case score
    when 80..100 then "Top"        # tokens très vivants, bien distribués, actifs
    when 70..79  then "Sérieux"
    when 50..69  then "Moyen"
    else              "Faible"
    end
  end

  # BADGE : classes Tailwind du fond + texte
  def seriousness_badge_classes(score)
    case score
    when 80..100 then "bg-blue-600 text-white"
    when 70..79  then "bg-emerald-600 text-white"
    when 50..69  then "bg-amber-400 text-gray-900"
    else              "bg-red-600 text-white"
    end
  end

  # 🆕 ICÔNE : renvoie 🔵 🟢 🟡 🔴 selon la catégorie
  def seriousness_icon(score)
    case score
    when 80..100 then "🔵"
    when 70..79  then "🟢"
    when 50..69  then "🟡"
    else              "🔴"
    end.html_safe
  end

  # TENDANCE : ▲ ▼ •
  def trend_icon(current, previous)
    # Si on n'a pas de référence précédente, on affiche un point neutre
    return "<span class='text-gray-500 text-xs'>•</span>".html_safe if previous.nil?

    if current > previous
      "<span class='text-green-400 text-xs font-bold'>▲</span>".html_safe
    elsif current < previous
      "<span class='text-red-400 text-xs font-bold'>▼</span>".html_safe
    else
      "<span class='text-gray-400 text-xs font-bold'>■</span>".html_safe
    end
  end

  def variation_number(current, previous)
    return "" if previous.nil?

    diff = current - previous

    if diff > 0
      "<span class='text-green-400 text-xs font-semibold'>+#{diff}</span>".html_safe
    elsif diff < 0
      "<span class='text-red-400 text-xs font-semibold'>#{diff}</span>".html_safe
    else
      "<span class='text-gray-400 text-xs font-semibold'>0</span>".html_safe
    end
  end

  def variation_badge(current, previous)
    return "".html_safe if previous.nil?

    diff = current.to_i - previous.to_i
    return "".html_safe if diff.zero?

    if diff > 0
      "<span class='text-green-400 text-xs font-semibold'>+#{diff}</span>".html_safe
    else
      "<span class='text-red-400 text-xs font-semibold'>#{diff}</span>".html_safe
    end
  end

end
