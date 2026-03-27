module GuidesHelper
  def health_pill_classes(status)
    case status.to_sym
    when :ok
      "text-emerald-300 bg-emerald-500/10 border-emerald-500/20"
    when :warn, :missing, :unknown
      "text-amber-300 bg-amber-500/10 border-amber-500/20"
    when :fail
      "text-rose-300 bg-rose-500/10 border-rose-500/20"
    else
      "text-gray-300 bg-gray-500/10 border-gray-500/20"
    end
  end

  def health_label(status)
    case status.to_sym
    when :ok then "OK"
    when :warn then "WARN"
    when :fail then "FAIL"
    when :missing then "MISSING"
    else "UNKNOWN"
    end
  end
end