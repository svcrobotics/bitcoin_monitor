module QuestionsHelper
  def format_duration(seconds)
    return "—" if seconds.nil?

    h = seconds / 3600
    m = (seconds % 3600) / 60
    s = seconds % 60

    if h.positive?
      format("%02dh %02dm %02ds", h, m, s)
    elsif m.positive?
      format("%02dm %02ds", m, s)
    else
      format("%02ds", s)
    end
  end
end