class GuidesController < ApplicationController
  before_action :set_guide_public, only: [:show]

  helper_method :admin_ok?

  def index
    scope = Guide.order(:position, :title)
    scope = scope.where(status: "published") unless admin_ok?
    @guides = scope
    @docs_index = ModuleDocsIndex.all
  end

  def show
    @module_health = GuideHealth.for(@guide)
    @module_docs   = ModuleDocsLoader.for(@guide.slug)

    if @module_docs.present?
      @available_versions = @module_docs[:versions].sort_by { |v| v[:version].delete_prefix("v").to_i }.reverse
      requested_version = params[:doc_version].presence
      @selected_version = @available_versions.find { |v| v[:version] == requested_version } || @available_versions.first

      @available_sections = Array(@selected_version[:sections])
      requested_section = params[:doc_section].presence
      @selected_section = @available_sections.find { |s| s[:name] == requested_section } || @available_sections.first
    else
      @available_versions = []
      @selected_version = nil
      @available_sections = []
      @selected_section = nil
    end

    @spec_results = if @guide.slug.present? && @selected_version.present?
      ModuleSpecResultsLoader.for(@guide.slug, @selected_version[:version])
    end
  end

  private

  def admin_ok?
    false
  end

  def set_guide_public
    @guide = find_guide_from_params

    return if @guide.status == "published"

    raise ActiveRecord::RecordNotFound unless admin_ok?
  end

  def find_guide_from_params
    key = (params[:slug] || params[:id]).to_s

    candidates = [
      key,
      key.tr("_", "-"),
      key.tr("-", "_")
    ].uniq

    candidates.each do |candidate|
      guide = Guide.find_by(slug: candidate)
      return guide if guide
    end

    return Guide.find_by(id: key) if key.match?(/\A\d+\z/)

    raise ActiveRecord::RecordNotFound, "Guide introuvable pour key=#{key.inspect}"
  end
end