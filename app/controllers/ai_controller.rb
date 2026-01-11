# frozen_string_literal: true

# app/controllers/ai_controller.rb
#
# 🤖 Contrôleur lié aux analyses IA du dashboard
#
# OBJECTIF
# --------
# Ce contrôleur gère des actions simples autour des analyses générées par l'IA
# (stockées dans le modèle AiInsight).
#
# Dans l'état actuel, il sert principalement à :
# - forcer la suppression d'une analyse IA existante
# - déclencher implicitement son recalcul lors du prochain affichage du dashboard
#
# IMPORTANT
# ---------
# Ce contrôleur NE calcule PAS l'analyse IA lui-même.
# Il se contente de :
# - supprimer les données existantes
# - laisser le système les régénérer à la demande (lazy recompute)
#
class AiController < ApplicationController

  # Supprime l'analyse IA du dashboard marché afin de forcer son recalcul.
  #
  # Fonctionnement :
  # - supprime toutes les entrées AiInsight ayant la clé "dashboard_market"
  # - redirige ensuite vers la page d'accueil (dashboard)
  #
  # Effet attendu :
  # - lors du prochain chargement du dashboard,
  #   l'analyse IA sera recalculée automatiquement (si le code le prévoit)
  #
  # Cas d'usage typiques :
  # - données on-chain mises à jour (flows, snapshot, etc.)
  # - incohérence détectée dans l'analyse affichée
  # - volonté de "rafraîchir" manuellement la lecture IA
  #
  # ⚠️ ATTENTION
  # - delete_all est volontairement brutal :
  #   - pas de callbacks
  #   - pas de validations
  # - acceptable ici car AiInsight est une table de cache / dérivée
  #
  def dashboard_insight
    AiInsight.where(key: "dashboard_market").delete_all

    redirect_to root_path, notice: "Analyse IA recalculée"
  end
end
