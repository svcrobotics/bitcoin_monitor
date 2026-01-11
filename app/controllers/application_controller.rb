# frozen_string_literal: true

# app/controllers/application_controller.rb
#
# 🧱 Contrôleur de base de l'application
#
# RÔLE
# ----
# ApplicationController est la classe parente de tous les contrôleurs Rails
# de l'application. Tout ce qui est défini ici est :
# - hérité par l'ensemble des contrôleurs
# - disponible dans toutes les vues (via helper_method)
#
# Il centralise :
# - des règles globales (navigateur autorisé)
# - des helpers d'état utilisateur
# - des helpers liés au mode d'affichage de l'interface (UX)
#
class ApplicationController < ActionController::Base

  # Autorise uniquement les navigateurs "modernes".
  #
  # Cette directive bloque volontairement les navigateurs trop anciens
  # qui ne supportent pas certaines fonctionnalités clés utilisées par l'app :
  # - images WebP
  # - Web Push / Badges
  # - Import Maps
  # - CSS nesting
  # - sélecteur CSS :has()
  #
  # Objectif :
  # - simplifier le code front
  # - éviter des fallbacks complexes
  # - garantir une UX cohérente et moderne
  #
  allow_browser versions: :modern

  # Inclusion d'un module de debug transverse.
  #
  # DebugTrace est supposé fournir :
  # - des helpers de log
  # - des traces d'exécution
  # - ou des outils d'inspection pendant le développement
  #
  include DebugTrace

  # Expose la méthode vaults_signed_in? aux vues.
  #
  # Cette méthode permet de savoir si un utilisateur est connecté
  # à la partie "Vaults" de l'application (système distinct du user principal).
  #
  helper_method :vaults_signed_in?

  # Indique si un utilisateur "Vaults" est connecté.
  #
  # Logique :
  # - on se base sur la présence de session[:vaults_user_id]
  #
  # Utilisation typique :
  # - afficher / masquer certaines parties de l'UI
  # - protéger l'accès à des écrans sensibles
  #
  # @return [Boolean]
  #
  def vaults_signed_in?
    session[:vaults_user_id].present?
  end

  # Expose les helpers de mode UI aux vues.
  #
  # Ces méthodes permettent de basculer entre :
  # - un mode "simple" (grand public)
  # - un mode "trader" (utilisateur avancé)
  #
  helper_method :simple_mode?, :trader_mode?

  # Indique si l'interface est en mode "simple".
  #
  # Règle :
  # - par défaut, l'interface est en mode simple
  # - si session[:ui_mode] == "trader", alors simple_mode? devient false
  #
  # Objectif UX :
  # - réduire la complexité visuelle
  # - masquer les indicateurs avancés au grand public
  #
  # @return [Boolean]
  #
  def simple_mode?
    session[:ui_mode] != "trader"
  end

  # Indique si l'interface est en mode "trader".
  #
  # Règle :
  # - trader_mode? est true uniquement si session[:ui_mode] == "trader"
  #
  # Objectif UX :
  # - afficher des indicateurs techniques
  # - fournir une lecture plus dense / experte du marché
  #
  # @return [Boolean]
  #
  def trader_mode?
    session[:ui_mode] == "trader"
  end
end
