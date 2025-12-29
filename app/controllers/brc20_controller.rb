class Brc20Controller < ApplicationController
  def index
    rpc = BitcoinRpc.new

    # Petit tip temporel global sur les events
    @events_tip_time = Brc20Event.maximum(:block_time)

    # === Couverture scan BRC-20 (fenêtre fixe) ===
    coverage_from = 920_000   # bloc de départ (à ajuster si besoin)
    coverage_to   = 926_028   # bloc de fin

    coverage_service = Brc20ScanCoverage.new(
      target_from: coverage_from,
      target_to:   coverage_to
    )

    @brc20_scan_stats = coverage_service.stats
    @brc20_scan_done  = (@brc20_scan_stats[:missing_blocks].zero?)

    # === Dernière exécution du cron BRC-20 ===
    load_brc20_cron_status

    # ==== Blocs réellement scannés dans ta DB ====
    first_scanned_block = Brc20BlockStat.minimum(:block_height)
    last_scanned_block  = Brc20BlockStat.maximum(:block_height)

    @brc20_window_from = first_scanned_block
    @brc20_window_to   = last_scanned_block

    if first_scanned_block && last_scanned_block
      @brc20_window_size = last_scanned_block - first_scanned_block + 1

      stats_scope = Brc20BlockStat.where(
        block_height: first_scanned_block..last_scanned_block
      )
    else
      @brc20_window_size = 0
      stats_scope = Brc20BlockStat.none
    end

    # 1) Agrégats par tick
    rows = stats_scope
      .group(:tick)
      .select(
        "tick,
         SUM(deploy_count)    AS deploy_count,
         MAX(deploy_max)      AS deploy_max,
         SUM(mint_count)      AS mint_count,
         SUM(mint_volume::numeric)     AS mint_volume,
         SUM(transfer_count)  AS transfer_count,
         SUM(transfer_volume::numeric) AS transfer_volume,
         SUM(deploy_count + mint_count + transfer_count) AS total_ops"
      )
      .order("total_ops DESC")
      .limit(1_000)

    # 2) Construction des hashes token + lien vers la table brc20_tokens
    @brc20_tokens = rows.map do |r|
      token = Brc20Token.find_by(tick: r.tick.to_s.downcase)

      protocol_max_supply = r.deploy_max&.to_i       # ce qui vient du déploy BRC-20
      db_max_supply       = token&.max_supply&.to_i  # ce que tu as éventuellement en base

      max_supply =
        if protocol_max_supply && protocol_max_supply > 0
          protocol_max_supply
        else
          db_max_supply || 0
        end

      {
        brc20_token_id:  token&.id,
        tick:            r.tick.to_s.downcase,
        deploy_count:    r.deploy_count.to_i,
        deploy_max:      protocol_max_supply,
        mint_count:      r.mint_count.to_i,
        mint_volume:     r.mint_volume.to_f.round,
        transfer_count:  r.transfer_count.to_i,
        transfer_volume: r.transfer_volume.to_f.round,
        total_ops:       r.total_ops.to_i,

        max_supply:      max_supply,
        mint_limit:      token&.mint_limit,
        holders_count:   0,
        events_count:    token&.events_count || 0,
        deploy_block:    token&.deploy_block_height,
        deploy_time:     token&.deploy_block_time
      }
    end

    # 3) Récupération des holders réels depuis brc20_balances
    token_ids = @brc20_tokens.map { |t| t[:brc20_token_id] }.compact

    if token_ids.any?
      holders_by_token_id = Brc20Balance
        .where(brc20_token_id: token_ids)
        .where.not(balance: "0")
        .group(:brc20_token_id)
        .count

      @brc20_tokens.each do |t|
        id = t[:brc20_token_id]
        t[:holders_count] = holders_by_token_id[id] || 0
      end
    end

    # 4) Score /100 pour chaque token
    @brc20_tokens.each do |t|
      t[:score] = token_score(t)
    end

    # 5) Stats d’hier pour les tendances transferts / volume / holders actifs
    if token_ids.any?
      yesterday = Date.current - 1

      stats_yesterday = Brc20TokenDailyStat
        .where(brc20_token_id: token_ids, day: yesterday)

      stats_by_token_id = stats_yesterday.index_by(&:brc20_token_id)

      @brc20_tokens.each do |t|
        id    = t[:brc20_token_id]
        stats = stats_by_token_id[id]

        if stats
          t[:yesterday_transfers]        = stats.transfer_count.to_i
          t[:yesterday_transfer_volume]  = stats.transfer_volume.to_i
          t[:yesterday_holders]          = stats.active_addresses_count.to_i
        else
          t[:yesterday_transfers]        = nil
          t[:yesterday_transfer_volume]  = nil
          t[:yesterday_holders]          = nil
        end
      end
    end

    # 6) Filtre “projets sérieux”
    @brc20_tokens = @brc20_tokens.select { |t| serious_token?(t) }

    # 7) Top 20 des projets sérieux
    @brc20_tokens = @brc20_tokens.sort_by { |t| -t[:total_ops] }.first(20)

    # 8) Ticks déployés sur les 30 derniers jours
    from_time = 30.days.ago.beginning_of_day
    to_time   = Time.current

    recent_deploys_scope = Brc20Event
      .where(op: "deploy")
      .where(block_time: from_time..to_time)

    @brc20_recent_deploys = recent_deploys_scope
      .group(:tick)
      .select(
        "tick,
         MIN(block_time)  AS first_deploy_time,
         MIN(block_height) AS first_deploy_block,
         MIN(txid)         AS first_deploy_txid,
         COUNT(*)          AS deploy_events_count"
      )
      .order("first_deploy_time DESC")
      .limit(10)
  rescue => e
    @error = e.message
    @brc20_tokens        = []
    @brc20_recent_deploys = []
    @brc20_scan_stats    = nil
    @brc20_scan_done     = false
    @brc20_window_from   = nil
    @brc20_window_to     = nil
  end

  private

  def serious_token?(t, now: Time.current)
    tick = t[:tick].to_s

    # 🧱 Brique 1 : tick "propre"
    return false unless tick.size == 4
    return false unless tick.match?(/\A[a-z0-9]{4}\z/)

    # 🧱 Brique 2 : un seul deploy
    return false unless t[:deploy_count].to_i == 1

    # 🧱 Brique 3 : max_supply crédible
    max_supply = t[:max_supply].to_i

    min_max_supply = 10
    max_max_supply = 100_000_000

    return false if max_supply <= 0
    return false if max_supply < min_max_supply
    return false if max_supply > max_max_supply

    # 🧱 Brique 4 : le volume de mint ne peut PAS dépasser max_supply
    minted = t[:mint_volume].to_i

    return false if minted < 0
    return false if minted >= max_supply

    # 🧱 Brique 5 : il faut qu'il y ait VRAIMENT du mint (>= 60%)
    minted_ratio = max_supply.positive? ? minted.to_f / max_supply : 0.0
    return false if minted_ratio < 0.60

    # 🧱 Brique 6 : au moins un transfert
    transfers_cnt = t[:transfer_count].to_i
    return false if transfers_cnt < 1

    # 🧱 Brique 7 : un minimum de holders
    holders     = t[:holders_count].to_i
    min_holders = 3
    return false if holders < min_holders

    # 🧱 Brique 8 : contrôle des whales
    whale_stats = token_whale_stats(t)
    top1_ratio  = max_supply.positive? ? whale_stats[:top1_balance].to_f  / max_supply : 0.0
    top10_ratio = max_supply.positive? ? whale_stats[:top10_balance].to_f / max_supply : 0.0

    return false if top1_ratio  > 0.90
    return false if top10_ratio > 0.99

    # 🧱 Brique 9 : activité récente (token vivant)
    last_transfer_at = token_last_transfer_at(t)
    tip_time         = @events_tip_time

    if tip_time && last_transfer_at
      return false if last_transfer_at < (tip_time - 30.days)
    end

    # 🧱 Brique 10 : score global minimal
    score = t[:score].to_i
    return false if score < 30

    true
  end

  def load_brc20_cron_status
    file = Rails.root.join("tmp/brc20_last_run")

    if File.exist?(file)
      @brc20_last_sync_run = Time.parse(File.read(file)) rescue nil
    else
      @brc20_last_sync_run = nil
    end
  end

  def token_score(t)
    holders    = t[:holders_count].to_i
    ops        = t[:total_ops].to_i
    transfers  = t[:transfer_count].to_i
    max_supply = t[:max_supply].to_i
    minted     = t[:mint_volume].to_i

    # 1️⃣ DISTRIBUTION (0 → 40)
    distribution_score =
      case holders
      when 0..10    then 0
      when 11..30   then 10
      when 31..100  then 20
      when 101..500 then 30
      else                40
      end

    # 2️⃣ ACTIVITÉ (0 → 40)
    ops_score       = [[ops / 10_000.0, 1.0].min * 25, 25].min
    transfers_score = [[transfers / 500.0, 1.0].min * 15, 15].min

    activity_score = ops_score + transfers_score

    # 3️⃣ RATIO MINT (0 → 20)
    mint_ratio = max_supply.positive? ? (minted.to_f / max_supply) : 0.0

    mint_score =
      case mint_ratio
      when 0..0.05   then 0
      when 0.05..0.20 then 5
      when 0.20..0.50 then 10
      when 0.50..0.80 then 15
      else                 20
      end

    (distribution_score + activity_score + mint_score).round
  end

  def token_whale_stats(t)
    token_id = t[:brc20_token_id]
    return { top1_balance: 0, top10_balance: 0 } unless token_id

    rows = Brc20Balance
      .where(brc20_token_id: token_id)
      .where.not(balance: "0")
      .pluck(:balance)

    numeric_balances = rows.map { |b| BigDecimal(b.presence || "0") }
                           .sort
                           .reverse

    top1  = numeric_balances[0] || 0
    top10 = numeric_balances.first(10).sum

    { top1_balance: top1, top10_balance: top10 }
  end

  def token_last_transfer_at(t)
    token_id = t[:brc20_token_id]
    return nil unless token_id

    Brc20Event
      .where(brc20_token_id: token_id, op: "transfer", is_valid: true)
      .maximum(:block_time)
  end
end
