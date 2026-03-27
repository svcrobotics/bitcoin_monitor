# frozen_string_literal: true

class ModuleSpecsLoader
  BASE_PATH = Rails.root.join("spec/modules")

  TYPE_ORDER = {
    "services" => 0,
    "requests" => 1,
    "tasks"    => 2,
    "system"   => 3
  }.freeze

  def self.for(module_slug, version)
    module_name = module_slug.to_s.tr("-", "_")
    version_name = version.to_s

    path = BASE_PATH.join(module_name, version_name)
    return nil unless Dir.exist?(path)

    groups = Dir.children(path)
      .select { |name| File.directory?(path.join(name)) }
      .sort_by { |name| TYPE_ORDER[name] || 99 }
      .map do |group_name|
        files = Dir.glob(path.join(group_name, "**/*_spec.rb")).sort

        {
          group: group_name,
          files_count: files.size,
          files: files.map do |file|
            {
              path: file.sub("#{Rails.root}/", ""),
              name: File.basename(file),
              command: "bundle exec rspec #{file.sub("#{Rails.root}/", "./")}"
            }
          end
        }
      end

    {
      module: module_name,
      version: version_name,
      groups: groups,
      total_files: groups.sum { |g| g[:files_count] },
      status: compute_status(groups)
    }
  end

  def self.compute_status(groups)
    total = groups.sum { |g| g[:files_count] }
    return :missing if total.zero?
    :ok
  end
end