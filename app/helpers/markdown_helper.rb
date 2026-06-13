# frozen_string_literal: true

module MarkdownHelper
  def render_markdown(text)
    return "" if text.blank?

    Commonmarker.to_html(text.to_s).html_safe
  end
end