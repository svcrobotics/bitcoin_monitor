# app/services/markdown_renderer.rb
require "commonmarker"

class MarkdownRenderer
  def self.to_html(markdown)
    return "" if markdown.blank?

    md = markdown.to_s.dup

    # :::cmd ... :::  -> ```bash ... ```
    md.gsub!(/^:::cmd\s*$\n(.*?)\n^:::\s*$/m) do
      inner = Regexp.last_match(1).strip
      "\n```bash\n#{inner}\n```\n"
    end

    # :::tip / :::warn / :::app -> blockquote + label
    md.gsub!(/^:::(tip|warn|app)\s*$\n(.*?)\n^:::\s*$/m) do
      kind  = Regexp.last_match(1)
      inner = Regexp.last_match(2).strip

      label =
        case kind
        when "tip"  then "💡 Tip"
        when "warn" then "⚠️ Warning"
        when "app"  then "🧩 Dans l’app"
        end

      quoted = inner.lines.map { |l| "> #{l.rstrip}\n" }.join
      "\n> **#{label}**\n>\n#{quoted}\n"
    end

    Commonmarker.to_html(
      md,
      options: {
        extension: {
          table: true,
          strikethrough: true,
          autolink: true,
          tasklist: true,
          tagfilter: true
        },
        render: { unsafe: false }
      }
    )
  end
end
