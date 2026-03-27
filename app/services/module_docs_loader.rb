# frozen_string_literal: true

class ModuleDocsLoader
  BASE_PATH = Rails.root.join("docs/modules")

  SECTION_ORDER = {
    "readme" => 0,
    "architecture" => 1,
    "decisions" => 2,
    "tasks" => 3,
    "tests" => 4,
    "amelioration" => 5,
    "improvements" => 5
  }.freeze

  def self.for(slug)
    module_name = extract_module_name(slug)
    module_path = BASE_PATH.join(module_name)
    return nil unless Dir.exist?(module_path)

    version_dirs = Dir.children(module_path)
      .select { |name| name.match?(/\Av\d+\z/) }
      .sort_by { |name| version_number(name) }

    versions = version_dirs.map do |version|
      version_path = module_path.join(version)
      files = Dir.glob(version_path.join("*.md"))

      sections = files.map do |file|
        name = File.basename(file, ".md")

        {
          name: name,
          title: extract_title(file),
          content: File.read(file)
        }
      end.sort_by { |section| SECTION_ORDER[section[:name]] || 99 }

      {
        version: version,
        sections: sections
      }
    end

    return nil if versions.empty?

    {
      module: module_name,
      versions: versions
    }
  end

  def self.extract_module_name(slug)
    slug.to_s.tr("-", "_")
  end

  def self.version_number(version_name)
    version_name.delete_prefix("v").to_i
  end

  def self.extract_title(file)
    first_line = File.readlines(file).first
    first_line&.sub(/\A#+\s*/, "")&.strip.presence || File.basename(file, ".md").humanize
  end
end