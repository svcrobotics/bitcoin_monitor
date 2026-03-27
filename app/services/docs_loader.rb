class DocsLoader
  BASE_PATH = Rails.root.join("docs/modules")

  def self.all
    Dir.glob(BASE_PATH.join("*.md")).map do |file|
      {
        name: File.basename(file, ".md"),
        title: extract_title(file),
        content: File.read(file)
      }
    end
  end

  def self.find(name)
    file = BASE_PATH.join("#{name}.md")
    return nil unless File.exist?(file)

    {
      name: name,
      title: extract_title(file),
      content: File.read(file)
    }
  end

  def self.extract_title(file)
    first_line = File.readlines(file).first
    first_line&.gsub("#", "")&.strip
  end
end