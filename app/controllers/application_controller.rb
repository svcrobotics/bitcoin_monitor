class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
  include DebugTrace

  helper_method :vaults_signed_in?

  def vaults_signed_in?
    session[:vaults_user_id].present?
  end
end
