# frozen_string_literal: true

# app/services/exchange_inflow_rebuilder.rb
#
# 🔁 Rebuild "Exchange Inflow" (proxy / legacy)
#
# OBJECTIF
# --------
# Reconstruit une série journalière d'inflow vers exchanges à partir des WhaleAlerts,
# sans RPC. C’est une approximation utile comme :
# - indicateur "tension / risque" macro
# - comparaison avec le True Flow
# - fallback si le moteur RPC est indisponible
#
# COUVERTURE (TRÈS IMPORTANT)
# --------------------------
# On distingue :
# - Avant le début réel de collecte : pas de données => inflow = nil
# - Après le début de collecte :
#   - si aucune WhaleAlert ce jour-là ET scan considéré "actif" => inflow = 0.0 (mesure = zéro)
#   - si scan probablement inactif => inflow = nil (jour manquant)
#
# Heuristique de couverture (sans table dédiée) :
# - un jour est "couvert" si au moins 1 WhaleAlert existe dans les N derniers jours
#   (incluant le jour courant). Sinon => on considère que le scan n’a pas tourné.
#
class ExchangeInflowRebuilder
  EXCHANGE_LIKELIHOOD_MIN  = 70
  WINDOWS                 = [7, 30, 200].freeze
  COVERAGE_LOOKBACK_DAYS  = 3

  def self.call(days_back: 220, only_missing: false)
    new(days_back: days_back, only_missing: only_missing).call
  end

  def initialize(days_back:, only_missing: false)
    @days_back    = days_back
    @only_missing = only_missing
  end

  def call
    # ✅ début réel de collecte (première WhaleAlert connue)
    first_bt = WhaleAlert.minimum(:block_time) || WhaleAlert.minimum(:created_at)
    @coverage_start_day = first_bt&.to_date

    range = (@days_back.days.ago.to_date)..Date.current

    range.each do |day|
      row = ExchangeFlow.find_or_initialize_by(day: day)

      if @only_missing
        # "calculé" = pas nil (0.0 compte)
        next unless row.inflow_btc.nil?
      end

      inflow = qualified_inflow_for_day(day)
      row.inflow_btc = inflow
      row.save!
    end

    compute_baselines_and_status!
  end

  private

  # Scope WhaleAlerts "exchange-like"
  #
  # - Priorité: exchange_likelihood >= 70
  # - Fallback: exchange_likelihood NULL + score >= 70 (historique)
  def qualified_scope
    WhaleAlert
      .where("exchange_likelihood >= ?", EXCHANGE_LIKELIHOOD_MIN)
      .or(
        WhaleAlert
          .where(exchange_likelihood: nil)
          .where("score >= ?", EXCHANGE_LIKELIHOOD_MIN)
      )
  end

  # Jour "couvert" si au moins 1 WhaleAlert existe dans les N derniers jours.
  # (Sans table de scan, c'est un garde-fou pour éviter de créer des faux "0.0".)
  def day_covered?(day)
    return false if @coverage_start_day.present? && day < @coverage_start_day

    from = (day - COVERAGE_LOOKBACK_DAYS).beginning_of_day
    to   = day.end_of_day

    WhaleAlert.where(block_time: from..to).exists? ||
      WhaleAlert.where(block_time: nil).where(created_at: from..to).exists?
  end

  # Inflow journalier estimé (proxy) :
  # - somme total_out_btc des WhaleAlerts qualifiées du jour
  #
  # Couverture :
  # - avant coverage_start => nil
  # - jour non couvert => nil
  # - jour couvert mais aucune alerte qualifiée => 0.0
  def qualified_inflow_for_day(day)
    return nil if @coverage_start_day.present? && day < @coverage_start_day
    return nil unless day_covered?(day)

    start_t = day.beginning_of_day
    end_t   = day.end_of_day

    # Priorité au temps blockchain
    scope = qualified_scope.where(block_time: start_t..end_t)

    # Fallback si block_time absent ou vide
    if scope.none?
      scope = qualified_scope.where(block_time: nil).where(created_at: start_t..end_t)
    end

    # ✅ jour couvert mais aucune alerte qualifiée => 0.0 (mesure = zéro)
    return 0.to_d if scope.none?

    scope.sum(:total_out_btc).to_d
  end

  # Recalcule les moyennes glissantes et le statut.
  #
  # ⚠️ Moyennes calculées sur les jours précédents (idx-1..),
  # et en ignorant les jours "nil" (pas de données).
  def compute_baselines_and_status!
    flows = ExchangeFlow.order(:day).to_a

    flows.each_with_index do |f, idx|
      f.avg7   = avg_over(flows, idx, 7)
      f.avg30  = avg_over(flows, idx, 30)
      f.avg200 = avg_over(flows, idx, 200)

      f.ratio30 = ratio(f.inflow_btc, f.avg30)
      f.status  = status_from_ratio(f.ratio30)

      f.save! if f.changed?
    end
  end

  # ✅ Moyenne glissante sur les jours précédents, en ignorant nil (pas de données).
  # Les vrais 0.0 comptent.
  def avg_over(flows, idx, window)
    to = idx - 1
    return nil if to < 0

    from  = [0, to - (window - 1)].max
    slice = flows[from..to]
    return nil if slice.blank?

    slice = slice.reject { |x| x.inflow_btc.nil? }
    return nil if slice.empty?

    sum = slice.sum { |x| x.inflow_btc.to_d }
    (sum / slice.size).to_d
  end

  def ratio(value, baseline)
    return nil if value.nil?
    return nil if baseline.blank? || baseline.to_d <= 0
    (value.to_d / baseline.to_d).round(4)
  end

  def status_from_ratio(ratio)
    return nil if ratio.blank?
    r = ratio.to_d
    return "green" if r < 1.3
    return "amber" if r < 2.0
    "red"
  end
end
