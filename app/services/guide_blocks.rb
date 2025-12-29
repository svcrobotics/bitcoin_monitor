# app/services/guide_blocks.rb
class GuideBlocks
  BLOCKS = {
    "tip"  => { title: "🧠 À retenir",  border: "border-emerald-600/40", bg: "bg-emerald-900/15", text: "text-emerald-200" },
    "warn" => { title: "⚠️ Piège",      border: "border-amber-600/40",   bg: "bg-amber-900/15",   text: "text-amber-200" },
    "cmd"  => { title: "🧰 Commande",   border: "border-sky-600/40",     bg: "bg-sky-900/15",     text: "text-sky-200" },
    "app"  => { title: "🔎 Dans l’app", border: "border-purple-600/40",  bg: "bg-purple-900/15",  text: "text-purple-200" }
  }.freeze

  # Transforme:
  # :::cmd
  # du contenu
  # :::
  # en HTML stylé
  def self.render(markdown)
    s = markdown.to_s.dup

    s.gsub!(/:::(tip|warn|cmd|app)\s*\n(.*?)\n:::/m) do
      kind = Regexp.last_match(1)
      body = Regexp.last_match(2).strip
      conf = BLOCKS[kind]

      # On échappe le body dans <pre> si cmd, sinon on le laisse en markdown
      if kind == "cmd"
        <<~HTML
          <div class="rounded-2xl border #{conf[:border]} #{conf[:bg]} p-4">
            <p class="text-xs font-semibold #{conf[:text]} mb-2">#{conf[:title]}</p>
            <pre class="overflow-x-auto text-xs text-gray-100"><code>#{ERB::Util.html_escape(body)}</code></pre>
          </div>
        HTML
      else
        # On garde le body en markdown, il passera au renderer ensuite
        <<~MD
          <div class="rounded-2xl border #{conf[:border]} #{conf[:bg]} p-4">
            <p class="text-xs font-semibold #{conf[:text]} mb-2">#{conf[:title]}</p>

          #{body}

          </div>
        MD
      end
    end

    s
  end
end
