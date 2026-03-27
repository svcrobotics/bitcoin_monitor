# frozen_string_literal: true

class ModuleDocsIndex
  BASE_PATH = Rails.root.join("docs/modules")

  def self.all
    return [] unless Dir.exist?(BASE_PATH)

    Dir.children(BASE_PATH).sort.map do |module_dir|
      module_path = BASE_PATH.join(module_dir)
      next unless File.directory?(module_path)

      version_dirs = Dir.children(module_path)
        .select { |name| name.match?(/\Av\d+\z/) && File.directory?(module_path.join(name)) }
        .sort_by { |name| name.delete_prefix("v").to_i }

      versions = version_dirs.map do |version|
        files = Dir.glob(module_path.join(version, "*.md"))

        {
          version: version,
          docs_count: files.size,
          docs: files.map { |file| File.basename(file, ".md") }.sort
        }
      end

      {
        module_name: module_dir,
        slug: module_dir.tr("_", "-"),
        versions_count: versions.size,
        docs_count: versions.sum { |v| v[:docs_count] },
        versions: versions
      }
    end.compact
  end
end