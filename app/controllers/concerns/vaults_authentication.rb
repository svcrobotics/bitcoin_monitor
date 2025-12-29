module VaultsAuthentication
  extend ActiveSupport::Concern

  included do
    helper_method :vaults_signed_in?
  end

  def vaults_signed_in?
    session[:vaults_user_id].present?
  end

  def require_vaults_auth!
    return if vaults_signed_in?

    # on garde l'URL demandée pour revenir après auth
    session[:vaults_return_to] = request.fullpath
    redirect_to "/vaults/login", alert: "Accès aux vaults protégé. Merci de signer un message via Sparrow."
  end

  def vaults_sign_in!(user_id)
    session[:vaults_user_id] = user_id
  end

  def vaults_sign_out!
    session.delete(:vaults_user_id)
  end
end
