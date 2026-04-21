module ExchangeLikeHelper
  def health_badge(status)
    label, classes =
      case status.to_s
      when "ok"
        ["OK", "bg-green-500/15 text-green-300 border border-green-500/30"]
      when "late"
        ["LATE", "bg-yellow-500/15 text-yellow-300 border border-yellow-500/30"]
      when "stale"
        ["STALE", "bg-red-500/15 text-red-300 border border-red-500/30"]
      else
        ["UNKNOWN", "bg-gray-500/15 text-gray-300 border border-gray-500/30"]
      end

    content_tag(:span, label, class: "px-2 py-1 rounded-full text-[10px] font-semibold #{classes}")
  end
end
