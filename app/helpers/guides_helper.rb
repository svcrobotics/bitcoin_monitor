module GuidesHelper
  def render_markdown(text)
    @md_renderer ||= begin
      renderer = Redcarpet::Render::HTML.new(
        filter_html: true,
        hard_wrap: true
      )

      Redcarpet::Markdown.new(renderer,
        fenced_code_blocks: true,
        tables: true,
        autolink: true,
        strikethrough: true
      )
    end

    html = @md_renderer.render(text.to_s)
    html.html_safe
  end
end
