# app/services/guide_sections_parser.rb
class GuideSectionsParser
  def self.call(raw)
    text = raw.to_s

    # strip YAML frontmatter
    text = strip_frontmatter(text)

    # normalize newlines (CRLF -> LF)
    text = text.gsub("\r\n", "\n")

    {
      fun:      section(text, header: /##\s*(?:🧠\s*)?Fun\b/i,        stops: [/##\s*(?:🧭\s*)?Didactique\b/i, /##\s*(?:🧪\s*)?Technique\b/i]),
      didactic: section(text, header: /##\s*(?:🧭\s*)?Didactique\b/i, stops: [/##\s*(?:🧪\s*)?Technique\b/i]),
      tech:     section(text, header: /##\s*(?:🧪\s*)?Technique\b/i,  stops: [])
    }
  end

  def self.strip_frontmatter(text)
    t = text.lstrip
    return text unless t.start_with?("---\n") || t.start_with?("---\r\n")

    # matches:
    # ---\n ... \n---\n
    text.sub(/\A---\s*\n.*?\n---\s*\n/m, "")
  end

  def self.section(text, header:, stops:)
    start = text.index(header)
    return "" unless start

    # content starts after the header line
    from = text.index("\n", start) || start
    rest = text[from..].to_s

    stop_positions = stops.map { |r| rest.index(r) }.compact
    cut = stop_positions.min
    body = cut ? rest[0...cut] : rest

    body.strip
  end

  private_class_method :strip_frontmatter, :section
end
