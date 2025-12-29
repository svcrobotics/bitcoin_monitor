class GuidesController < ApplicationController
  def index
    @guides = Guide
      .where(status: "published")
      .order(:position, :title)
  end

  def show
    @guide = Guide.find_by!(slug: params[:id], status: "published")
  end
end
