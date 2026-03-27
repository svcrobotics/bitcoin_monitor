# frozen_string_literal: true

class AiController < ApplicationController
  def dashboard_insight
    AiInsight.where(key: Ai::ComputeDashboardInsight::KEY).delete_all
    redirect_to root_path, notice: "Analyse IA recalculée"
  end
end
