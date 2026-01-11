# frozen_string_literal: true

class DailyReadingEngine
  # seuils cohérents avec ton status_from_ratio
  FLOW_GREEN_MAX = 1.3
  FLOW_AMBER_MAX = 2.0

  def self.call(price_live:, price_close:, flow:, zones:, market_snapshot: nil)
    new(price_live:, price_close:, flow:, zones:, market_snapshot:).call
  end

  def initialize(price_live:, price_close:, flow:, zones:, market_snapshot:)
    @price_live = price_live&.to_d
    @price_close = price_close&.to_d
    @flow = flow
    @zones = zones || {}
    @market_snapshot = market_snapshot
  end

  def call
    return empty_result("Données insuffisantes") if @flow.blank? || @price_close.blank?

    support = @zones[:support]
    resist  = @zones[:resistance]

    price_ref = (@price_live.presence || @price_close)
    ratio30   = @flow.ratio30&.to_d

    flow_state = flow_state_from(@flow.status, ratio30)
    zone_state = zone_state_from(price_ref, support, resist)

    scenario = scenario_from(flow_state, zone_state)
    weekly   = weekly_score

    {
      headline: headline(flow_state, zone_state, scenario),
      bullets: bullets(flow_state, zone_state, support, resist, price_ref),
      decision: decision(flow_state, zone_state, support, resist, price_ref),
      invalidation: invalidation(flow_state, zone_state, support, resist),
      weekly: weekly
    }
  end

  private

  def empty_result(msg)
    { headline: msg, bullets: [], decision: [], invalidation: [], weekly: nil }
  end

  # --- FLOW ---
  def flow_state_from(status, ratio30)
    st = status.to_s
    return :red   if st == "red"   || (ratio30 && ratio30 >= FLOW_AMBER_MAX)
    return :amber if st == "amber" || (ratio30 && ratio30 >= FLOW_GREEN_MAX)
    :green
  end

  # --- ZONES ---
  # On veut un truc simple : proche support / proche résistance / au milieu
  def zone_state_from(price, support, resist)
    # distances en % du mid de zone
    ds = support ? dist_pct(price, mid_of(support)) : nil
    dr = resist  ? dist_pct(price, mid_of(resist))  : nil

    # “proche” = à ajuster (1.2% colle bien à ton clustering ±1.2)
    near = 1.2.to_d

    return :near_support     if ds && ds.abs <= near && ds < 0
    return :near_resistance  if dr && dr.abs <= near && dr > 0

    # si on est sous support (break) / au-dessus résistance (break)
    if support && price < support.low_usd.to_d
      return :below_support
    end
    if resist && price > resist.high_usd.to_d
      return :above_resistance
    end

    :mid_range
  end

  def mid_of(zone)
    (zone.low_usd.to_d + zone.high_usd.to_d) / 2
  end

  def dist_pct(price, level)
    ((level - price) / price * 100).to_d # + = au-dessus du prix, - = en dessous
  end

  # --- SCENARIO (flow x zones) ---
  def scenario_from(flow_state, zone_state)
    # logique volontairement conservative (risque > signal)
    if flow_state == :red && (zone_state == :near_resistance || zone_state == :below_support)
      :sell_pressure
    elsif flow_state == :red && zone_state == :near_support
      :absorption_test
    elsif (flow_state == :green) && (zone_state == :near_support || zone_state == :above_resistance)
      :accumulation
    else
      :neutral
    end
  end

  # --- COPY / DECISION ---
  def headline(flow_state, zone_state, scenario)
    fs = { green: "🟢 Flow normal", amber: "🟡 Flow tendu", red: "🔴 Flow en excès" }[flow_state]
    zs = {
      near_support: "près du support",
      near_resistance: "près de la résistance",
      mid_range: "entre zones",
      below_support: "sous le support (break)",
      above_resistance: "au-dessus de la résistance (break)"
    }[zone_state]

    case scenario
    when :sell_pressure
      "#{fs} + prix #{zs} → risque de vente actif"
    when :absorption_test
      "#{fs} + test support → absorption ou cassure"
    when :accumulation
      "#{fs} + structure favorable → contexte plus sain"
    else
      "#{fs} + prix #{zs} → lecture neutre (attendre confirmation)"
    end
  end

  def bullets(flow_state, zone_state, support, resist, price)
    b = []
    b << flow_bullet(flow_state)
    b << zone_bullet(zone_state, support, resist, price)
    b << market_bullet if @market_snapshot.present?
    b.compact
  end

  def flow_bullet(flow_state)
    ratio = @flow.ratio30 ? @flow.ratio30.to_d.round(2) : nil
    inflow = @flow.inflow_btc.to_d.round(2)
    outflow = @flow.outflow_btc.to_d.round(2)
    net = @flow.netflow_btc.to_d.round(2)

    base = "TrueFlow 24h: inflow #{inflow} • outflow #{outflow} • net #{net} BTC"
    base += " • ratio30 x#{ratio}" if ratio
    base += " (#{flow_state})"
    base
  end

  def zone_bullet(zone_state, support, resist, price)
    case zone_state
    when :near_support
      "Prix près du support #{fmt_zone(support)}"
    when :near_resistance
      "Prix près de la résistance #{fmt_zone(resist)}"
    when :below_support
      "Prix sous le support #{fmt_zone(support)} (cassure)"
    when :above_resistance
      "Prix au-dessus de la résistance #{fmt_zone(resist)} (breakout)"
    else
      # mid_range
      s = support ? fmt_zone(support) : "—"
      r = resist  ? fmt_zone(resist)  : "—"
      "Prix entre zones • support #{s} • résistance #{r}"
    end
  end

  def market_bullet
    bias = @market_snapshot.market_bias.to_s
    risk = @market_snapshot.risk_level.to_s
    "Contexte: bias #{bias} • risk #{risk}"
  end

  def decision(flow_state, zone_state, support, resist, _price)
    d = []

    # décision = quoi faire / ne pas faire (sans promettre un trade)
    if flow_state == :red && zone_state == :near_resistance
      d << "✅ Réduire le risque (éviter les entrées FOMO près résistance)"
      d << "✅ Attendre confirmation: rejection / cassure / retest"
    elsif flow_state == :red && zone_state == :near_support
      d << "✅ Mode prudence: laisser le support 'parler' (rebound vs break)"
      d << "✅ Si cassure: éviter d’anticiper, attendre un retest"
    elsif flow_state == :green && zone_state == :near_support
      d << "✅ Contexte plutôt sain: surveiller un rebond propre sur support"
    else
      d << "✅ Ne rien forcer: attendre un signal prix clair sur une zone"
    end

    d
  end

  def invalidation(flow_state, zone_state, support, resist)
    inv = []
    if support.present?
      inv << "Inval. support: clôture sous #{support.low_usd.to_i}$ (ou cassure confirmée + retest raté)"
    end
    if resist.present?
      inv << "Inval. résistance: clôture au-dessus #{resist.high_usd.to_i}$ (ou breakout + retest OK)"
    end
    inv << "Flow: retour sous x#{FLOW_GREEN_MAX} (tension qui disparaît)" if flow_state != :green
    inv
  end

  def fmt_zone(z)
    return "—" if z.blank?
    "#{z.low_usd.to_i}$–#{z.high_usd.to_i}$"
  end

  # --- WEEKLY SCORE (lecture de la semaine) ---
  # Score 0..100 = "pression vendeuse potentielle" (pas un signal)
  def weekly_score
    last7 = ExchangeTrueFlow.order(day: :desc).limit(7).to_a
    return nil if last7.empty?

    # composantes simples, robustes :
    # - ratio30 moyen
    # - nb de jours red/amber
    # - netflow cumul positif
    ratios = last7.map { |f| f.ratio30.to_d rescue 0.to_d }.select { |x| x > 0 }
    ratio_avg = ratios.any? ? (ratios.sum / ratios.size) : 0.to_d

    reds   = last7.count { |f| f.status.to_s == "red" }
    ambers = last7.count { |f| f.status.to_s == "amber" }

    net_sum = last7.sum { |f| f.netflow_btc.to_d rescue 0.to_d } # >0 = exchanges reçoivent net

    # normalisation "à la main" (facile à ajuster)
    score = 0
    score += [(ratio_avg - 1).to_f * 35, 0].max # ratio au-dessus de 1 pèse
    score += reds * 12
    score += ambers * 6
    score += [net_sum.to_f / 200.0 * 15, 0].max # 200 BTC net sur 7j -> +15

    score = [[score.round, 0].max, 100].min

    label =
      if score >= 70 then "🔴 Semaine à risque"
      elsif score >= 45 then "🟡 Semaine tendue"
      else "🟢 Semaine normale"
      end

    {
      score: score,
      label: label,
      ratio_avg: ratio_avg.round(2).to_f,
      net_sum_btc: net_sum.round(2).to_f,
      days_red: reds,
      days_amber: ambers
    }
  end
end
