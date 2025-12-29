module MarkdownHandler
  def self.call(template, source = nil)
    markdown = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML,
      autolink: true,
      tables: true,
      fenced_code_blocks: true
    )
    "markdown.render(begin;#{template.source};end).html_safe"
  end
end

ActionView::Template.register_template_handler :md, MarkdownHandler
