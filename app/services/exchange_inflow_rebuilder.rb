# frozen_string_literal: true

# app/services/exchange_inflow_rebuilder.rb
#
# 🔁 Recalcul de la série temporelle "Exchange Inflow"
#
# OBJECTIF
# --------
# Ce service reconstruit, jour par jour, une estimation simplifiée des
# dépôts de BTC vers les exchanges ("inflow").
#
# ⚠️ IMPORTANT
# Ce n'est PAS le "True Exchange Flow".
# Ici, on utilise une APPROXIMATION basée uniquement sur les données WhaleAlert,
# sans analyse des transactions brutes via Bitcoin RPC.
#
# Cet indicateur sert :
# - de version legacy / simplifiée
# - de point de comparaison
# - ou de fallback si le moteur RPC est indisponible
#
# PRINCIPE DE CALCUL
# ------------------
# Pour chaque jour :
# - on sélectionne les WhaleAlerts jugées "probablement liées à un exchange"
# - on additionne leur volume (total_out_btc)
# - on stocke ce total comme inflow journalier
#
# Ensuite :
# - on calcule des moyennes glissantes (7j / 30j / 200j)
# - on calcule un ratio inflow vs moyenne 30j
# - on attribue un statut (green / amber / red)
#
class ExchangeInflowRebuilder
  # Seuil minimum pour considérer qu'une WhaleAlert est liée à un exchange
  #
  # Priorité :
  # - exchange_likelihood >= 70
  #
  # Fallback :
  # - exchange_likelihood NULL
  # - score >= 70
  #
  EXCHANGE_LIKELIHOOD_MIN = 70

  # Fenêtres utilisées pour les moyennes glissantes
  WINDOWS = [7, 30, 200].freeze

  # Point d'entrée principal (convention Rails)
  #
  # @param days_back [Integer] nombre de jours à recalculer dans le passé
  #
  # Exemple :
  #   ExchangeInflowRebuilder.call(days_back: 220)
  #
  def self.call(days_back: 220)
    new(days_back: days_back).call
  end

  # Initialisation du service
  #
  # @param days_back [Integer] nombre de jours à recalculer
  #
  def initialize(days_back:)
    @days_back = days_back
  end

  # Méthode principale d'exécution
  #
  # Étapes :
  # 1. Parcourt chaque jour sur la période demandée
  # 2. Calcule l'inflow qualifié pour ce jour
  # 3. Sauvegarde le résultat dans ExchangeFlow
  # 4. Recalcule les moyennes et statuts
  #
  def call
    range = (@days_back.days.ago.to_date)..Date.current

    range.each do |day|
      inflow = qualified_inflow_for_day(day)

      row = ExchangeFlow.find_or_initialize_by(day: day)
      row.inflow_btc = inflow
      row.save!
    end

    compute_baselines_and_status!
  end

  private

  # Scope de base des WhaleAlerts considérées comme "exchange-like"
  #
  # Logique :
  # - On privilégie exchange_likelihood (plus précis)
  # - Si exchange_likelihood est NULL (cas historiques ou incomplets),
  #   on utilise le champ score comme approximation
  #
  # Pourquoi ?
  # - Éviter de perdre des données
  # - Accepter un peu de bruit plutôt qu'un trou statistique
  #
  # @return [ActiveRecord::Relation]
  #
  def qualified_scope
    scope = WhaleAlert.where(
      "exchange_likelihood >= ?", EXCHANGE_LIKELIHOOD_MIN
    )

    scope = scope.or(
      WhaleAlert
        .where(exchange_likelihood: nil)
        .where("score >= ?", EXCHANGE_LIKELIHOOD_MIN)
    )

    scope
  end

  # Calcule l'inflow qualifié pour une journée donnée
  #
  # Étapes :
  # 1. Définition de la fenêtre temporelle (00:00 → 23:59)
  # 2. Tentative avec block_time (temps réel blockchain)
  # 3. Fallback avec created_at si aucune donnée trouvée
  # 4. Somme de total_out_btc comme proxy de volume
  #
  # ⚠️ LIMITES IMPORTANTES
  # - total_out_btc représente le volume total sorti d'une transaction,
  #   PAS forcément uniquement ce qui va vers un exchange
  # - Il peut y avoir :
  #   - du double comptage
  #   - des faux positifs
  #
  # 👉 C'est un INDICATEUR DE TENSION, pas un flux exact.
  #
  # @param day [Date]
  # @return [BigDecimal] inflow estimé en BTC
  #
  def qualified_inflow_for_day(day)
    start_t = day.beginning_of_day
    end_t   = day.end_of_day

    # Priorité au temps blockchain
    scope = qualified_scope.where(block_time: start_t..end_t)

    # Fallback si block_time absent ou vide
    if scope.none?
      scope = qualified_scope.where(created_at: start_t..end_t)
    end

    scope.sum(:total_out_btc).to_d
  end

  # Recalcule les moyennes glissantes et le statut pour chaque jour
  #
  # Champs calculés :
  # - avg7, avg30, avg200 : moyennes des inflows passés
  # - ratio30 : inflow / moyenne 30j
  # - status : green / amber / red
  #
  # ⚠️ Ici, la moyenne INCLUT le jour courant
  # (contrairement au True Exchange Flow, plus strict)
  #
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

  # Calcule une moyenne glissante sur une fenêtre donnée
  #
  # ⚠️ Comportement actuel :
  # - la moyenne inclut le jour courant
  #
  # Conséquence :
  # - le ratio est légèrement atténué
  # - acceptable pour un indicateur "macro"
  #
  # @param flows [Array<ExchangeFlow>]
  # @param idx [Integer] index courant
  # @param window [Integer] taille de la fenêtre
  # @return [BigDecimal, nil]
  #
  def avg_over(flows, idx, window)
    from  = [0, idx - (window - 1)].max
    slice = flows[from..idx]
    return nil if slice.empty?

    sum = slice.sum { |x| x.inflow_btc.to_d }
    (sum / slice.size).to_d
  end

  # Calcule le ratio inflow / moyenne
  #
  # Utilisé pour détecter les anomalies
  #
  # @param value [Numeric]
  # @param baseline [Numeric]
  # @return [BigDecimal, nil]
  #
  def ratio(value, baseline)
    return nil if baseline.blank? || baseline.to_d <= 0
    (value.to_d / baseline.to_d).round(4)
  end

  # Détermine le statut de marché à partir du ratio
  #
  # Seuils :
  # - green  : ratio < 1.3 → normal
  # - amber  : ratio < 2.0 → tension
  # - red    : ratio ≥ 2.0 → excès / anomalie
  #
  # @param ratio [Numeric]
  # @return [String, nil]
  #
  def status_from_ratio(ratio)
    return nil if ratio.blank?
    r = ratio.to_d
    return "green" if r < 1.3
    return "amber" if r < 2.0
    "red"
  end
end
