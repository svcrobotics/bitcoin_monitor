# app/services/system/graph_builder.rb
class System::GraphBuilder
  EDGE_TYPES = [
    :job_enqueue,
    :service_call,
    :direct_call
  ]

  def self.call
    new.call
  end

  def call
    {
      edges: build_edges
    }
  end

  private

  def build_edges
    edges = []

    ruby_files.each do |file|
      from = extract_class_name(file)
      next unless from

      content = File.read(file)

      edges += detect_job_enqueues(from, content)
      edges += detect_service_calls(from, content)
      edges += detect_direct_calls(from, content)
    end

    edges.uniq
  end

  def ruby_files
    Dir.glob("app/**/*.rb")
  end

  # 🔥 1. Jobs (très important pour ton système)
  def detect_job_enqueues(from, content)
    content.scan(/([A-Z]\w+Job)\.(perform_later|perform_now)/).map do |job, _|
      { from: from, to: job, type: :job_enqueue }
    end
  end

  # 🔥 2. Services (.call pattern)
  def detect_service_calls(from, content)
    content.scan(/([A-Z]\w+(::[A-Z]\w+)*)\.call/).map do |match|
      to = match.first
      next if to == from

      { from: from, to: to, type: :service_call }
    end.compact
  end

  # 🔥 3. Appels directs (optionnel mais utile)
  def detect_direct_calls(from, content)
    content.scan(/([A-Z]\w+(::[A-Z]\w+)*)\.new/).map do |match|
      to = match.first
      next if to == from

      { from: from, to: to, type: :direct_call }
    end.compact
  end

  def extract_class_name(file)
    content = File.read(file)
    content[/class\s+([A-Za-z0-9:]+)/, 1]
  end
end