# frozen_string_literal: true

# app/controllers/application_controller.rb
#
# 🧱 Contrôleur racine de l’application
#
# Centralise :
# - gestion navigateur
# - gestion I18n
# - helpers globaux
# - mode UI
#
class ApplicationController < ActionController::Base

  # 🔐 Autorise uniquement les navigateurs modernes
  allow_browser versions: :modern

  # 🧩 Debug transverse
  include DebugTrace

  # 🌍 Gestion multilingue
  before_action :set_locale

  # Expose aux vues
  helper_method :vaults_signed_in?,
                :simple_mode?,
                :trader_mode?

  # ============================================================
  # 🌍 I18N — Gestion de la langue
  # ============================================================

  private

  # Définit la langue utilisée par l'application.
  #
  # Priorité :
  # 1. paramètre URL (?locale=es)
  # 2. session utilisateur
  # 3. langue navigateur (Accept-Language)
  # 4. langue par défaut
  #
  def set_locale
    requested =
      params[:locale].presence ||
      session[:locale].presence ||
      extract_locale_from_accept_language_header

    locale = normalize_locale(requested)

    if available_locale?(locale)
      I18n.locale = locale
      session[:locale] = locale
    else
      I18n.locale = I18n.default_locale
    end
  end

  # Normalise la locale :
  # - "en-US" → "en"
  # - "zh-CN" → "zh-CN"
  # - "fr" → "fr"
  #
  def normalize_locale(loc)
    return nil if loc.blank?

    loc = loc.to_s

    # Si locale exacte existe (ex: zh-CN)
    return loc if available_locale?(loc)

    # Sinon fallback sur les 2 premières lettres (ex: en-US → en)
    short = loc.split("-").first
    return short if available_locale?(short)

    nil
  end

  def available_locale?(loc)
    I18n.available_locales.map(&:to_s).include?(loc.to_s)
  end

  # Extrait la première langue du header navigateur
  #
  # Exemple :
  # "en-US,en;q=0.9,fr;q=0.8"
  # → "en-US"
  #
  def extract_locale_from_accept_language_header
    header = request.env["HTTP_ACCEPT_LANGUAGE"].to_s
    header.scan(/[a-z]{2}(?:-[A-Z]{2})?/).first
  end

  # Conserve automatiquement la locale dans toutes les URLs
  def default_url_options
    { locale: I18n.locale }
  end

  # ============================================================
  # 👤 AUTH VAULTS
  # ============================================================

  def vaults_signed_in?
    session[:vaults_user_id].present?
  end

  # ============================================================
  # 🎛️ MODE UI
  # ============================================================

  def simple_mode?
    session[:ui_mode] != "trader"
  end

  def trader_mode?
    session[:ui_mode] == "trader"
  end
end
