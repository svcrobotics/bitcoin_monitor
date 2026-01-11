class UiModeController < ApplicationController
  def update
    session[:ui_mode] = (params[:mode] == "trader" ? "trader" : "simple")
    redirect_to(request.referer.presence || dashboard_path)
  end
end
