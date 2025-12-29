# app/helpers/markdown_helper.rb
module MarkdownHelper
  # Rendu Markdown -> HTML (safe-ish) via Commonmarker
  def render_markdown(text)
    return "" if text.blank?

    Commonmarker.to_html(
      text.to_s,
      options: :DEFAULT,
      extensions: %i[
        strikethrough
        table
        autolink
        tasklist
        tagfilter
      ]
    ).html_safe
  end
end
