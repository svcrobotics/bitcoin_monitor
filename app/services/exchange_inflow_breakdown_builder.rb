# frozen_string_literal: true

# =========================================================
# ExchangeInflowBreakdownBuilder
#
# But
# ---
# Pré-calculer (daily) le breakdown "inflow" et "custody diagnostics"
# à partir de ExchangeObservedUtxo.
#
# - inflow  : basé sur seen_day  (UTXO reçus par exchange-like addresses)
# - custody : basé sur spent_day (UTXO dépensés par ces wallets) -> diagnostic seulement
#
# Pourquoi c'est "pro"
# --------------------
# - La vue ne fait plus de grosses agrégations SQL (plus de pluck Arel)
# - Les chiffres sont reproductibles et auditables (table daily)
# - On stocke aussi : counts + concentration top1/top10
#
# Hypothèses
# ----------
# - ExchangeObservedUtxo contient : seen_day, spent_day, address, value_btc
# - ExchangeAddress occ>=min_occ a déjà été construit (ExchangeAddressBuilder)
# =========================================================
class ExchangeInflowBreakdownBuilder
  require "set"

  class Error < StandardError; end

  DEFAULT_DAYS_BACK = Integer(ENV.fetch("TF_BREAKDOWN_DAYS_BACK", "30")) rescue 30
  DEFAULT_MIN_OCC   = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "8")) rescue 8

  def self.call(days_back: DEFAULT_DAYS_BACK, min_occ: DEFAULT_MIN_OCC, scopes: %w[inflow custody])
    new(days_back: days_back, min_occ: min_occ, scopes: scopes).call
  end

  def initialize(days_back:, min_occ:, scopes:)
    @days_back = days_back.to_i
    @min_occ   = min_occ.to_i
    @scopes    = Array(scopes).map(&:to_s)
  end

  def call
    raise Error, "days_back invalid" if @days_back <= 0
    raise Error, "min_occ invalid" if @min_occ <= 0

    days = (@days_back.days.ago.to_date)..Date.current

    # Set d'adresses exchange-like (limite le bruit si ExchangeObservedUtxo contient d'autres adresses)
    exchange_set = ExchangeAddress.where("occurrences >= ?", @min_occ).pluck(:address).to_set
    return { ok: true, note: "no exchange addresses for min_occ=#{@min_occ}" } if exchange_set.empty?

    out = {}

    if @scopes.include?("inflow")
      out[:inflow] = build_scope!(scope: "inflow", day_field: :seen_day, days: days, exchange_set: exchange_set)
    end

    if @scopes.include?("custody")
      out[:custody] = build_scope!(scope: "custody", day_field: :spent_day, days: days, exchange_set: exchange_set)
    end

    { ok: true, min_occ: @min_occ, days_back: @days_back, result: out }
  end

  private

  def build_scope!(scope:, day_field:, days:, exchange_set:)
    # Filtre de base
    base = ExchangeObservedUtxo
      .where(day_field => days)
      .where(address: exchange_set.to_a)

    # 1) Buckets + total + utxos_count
    rows = base
      .group(day_field)
      .pluck(
        day_field,
        Arel.sql("COALESCE(SUM(CASE WHEN value_btc < 10 THEN value_btc ELSE 0 END),0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN value_btc >= 10 AND value_btc < 100 THEN value_btc ELSE 0 END),0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN value_btc >= 100 AND value_btc < 500 THEN value_btc ELSE 0 END),0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN value_btc >= 500 THEN value_btc ELSE 0 END),0)"),
        Arel.sql("COALESCE(SUM(value_btc),0)"),
        Arel.sql("COUNT(*)")
      )

    # 2) addresses_count par jour (utile UI + sanity)
    addr_counts = base.group(day_field).distinct.count(:address)

    # 3) concentration top1/top10 par jour (pro)
    #    On fait une requête par jour (simple & fiable). Vu que c'est daily + days_back raisonnable, ça passe.
    #    Si un jour tu veux optimiser: faire une requête SQL window function.
    result_days = 0

    rows.each do |day, lt10, b10_99, b100_499, b500p, total, utxos_count|
      day = day.to_date
      total_d = total.to_d
      next if total_d <= 0

      # top addresses
      top = base.where(day_field => day).group(:address).sum(:value_btc).sort_by { |_a, v| -v.to_d }.first(10)
      top1_btc  = top.first ? top.first[1].to_d : 0.to_d
      top10_btc = top.sum { |_a, v| v.to_d }

      top1_pct  = total_d > 0 ? (top1_btc / total_d * 100.0) : nil
      top10_pct = total_d > 0 ? (top10_btc / total_d * 100.0) : nil

      row = ExchangeInflowBreakdown.find_or_initialize_by(day: day, scope: scope, min_occ: @min_occ)

      row.lt10_btc     = lt10.to_d
      row.b10_99_btc   = b10_99.to_d
      row.b100_499_btc = b100_499.to_d
      row.b500p_btc    = b500p.to_d
      row.total_btc    = total_d
      row.utxos_count  = utxos_count.to_i
      row.addresses_count = addr_counts[day] || 0

      row.top1_btc  = top1_btc
      row.top10_btc = top10_btc
      row.top1_pct  = top1_pct&.round(4)
      row.top10_pct = top10_pct&.round(4)

      # meta minimal (tu peux enrichir plus tard)
      row.meta = (row.meta || {}).merge(
        "top_addresses" => top.first(5).map { |addr, btc| [addr, btc.to_d.to_s("F")] } # top5 seulement
      )

      row.save!
      result_days += 1
    end

    { scope: scope, days_written: result_days }
  end
end