# app/services/system/mermaid_exporter.rb
class System::MermaidExporter
  def self.call
    new.call
  end

  def call
    data = System::GraphBuilder.call

    lines = []
    lines << "graph TD"

    data[:edges].each do |edge|
      from = sanitize(edge[:from])
      to   = sanitize(edge[:to])

      arrow = case edge[:type]
              when :job_enqueue then "-->|job|"
              when :service_call then "-->|call|"
              when :direct_call then "-->|new|"
              end

      lines << "  #{from} #{arrow} #{to}"
    end

    lines.join("\n")
  end

  private

  def sanitize(name)
    name.gsub("::", "_")
  end
end