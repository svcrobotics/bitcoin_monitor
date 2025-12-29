# app/services/brc20_indexer.rb
class Brc20Indexer
  BATCH_SIZE = 1000

  def initialize(rpc:, from_height:, to_height:, full_rescan: false)
    @rpc         = rpc
    @from_height = from_height
    @to_height   = to_height
    @full_rescan = full_rescan

    @inscription_extractor = Brc20InscriptionExtractor.new(rpc: @rpc)
    @events_buffer         = []
  end

  def run
    total_blocks  = @to_height - @from_height + 1
    @events_count = 0

    @progress = ProgressBar.create(
      title:   "Scanning BRC-20 blocks",
      total:   total_blocks,
      format:  "%t |%B| %p%% (%c/%C) | %a écoulé, %e restant",
      progress_mark: "#",
      remainder_mark: "-",
      projector: {
        type:     "smoothing",
        strength: 0.3
      }
    )

    actual_from = nil
    actual_to   = nil

    (@from_height..@to_height).each do |height|
      index_block(height)
      actual_from ||= height
      actual_to     = height
      @progress.increment
    end

    flush_events!

    @progress.finish
    puts "\n📊 Scan terminé."
    puts "Total events: #{@events_count}"

    # 💾 Enregistre la plage scannée (même s'il n'y a eu aucun event BRC-20)
    if actual_from && actual_to
      Brc20ScanRange.create!(
        from_height: actual_from,
        to_height:   actual_to,
        scanned_at:  Time.current
      )
    end
  end

  private

  # =======================
  #  Scan d’un bloc
  # =======================

  def index_block(height)
    block_hash = @rpc.get_block_hash(height)
    block      = @rpc.get_block(block_hash, 2)
    block_time = Time.at(block["time"])

    ActiveRecord::Base.transaction do
      block["tx"].each do |tx|
        process_tx(tx, block, block_time)
      end
    end

  rescue Net::ReadTimeout
    Rails.logger.warn "BRC20Indexer: timeout RPC sur le bloc #{height}, on passe au suivant."
  end

  def process_tx(tx, block, block_time)
    brc20_inscriptions_for(tx).each do |ins|
      process_inscription(ins, tx, block, block_time)
    end
  end

  def brc20_inscriptions_for(tx)
    @inscription_extractor.for_tx(tx)
  end

  # =======================
  #  Traitement inscription
  # =======================

  def process_inscription(ins, tx, block, block_time)
    unless @full_rescan
      if Brc20Event.exists?(inscription_id: ins["inscription_id"])
        Rails.logger.debug "BRC20Indexer: inscription déjà indexée #{ins["inscription_id"]}, skip."
        return
      end
    end

    payload = JSON.parse(ins["content"]) rescue nil
    return if payload.nil?
    return unless payload["p"] == "brc-20"

    op   = payload["op"]
    tick = payload["tick"].to_s.downcase
    amt  = (payload["amt"] || payload["max"] || "0").to_s

    token =
      case op
      when "deploy"
        find_or_create_token_from_deploy(payload, tick, ins, block, block_time)
      when "mint", "transfer"
        Brc20Token.find_by(tick: tick)
      else
        nil
      end

    return if token.nil?

    from_address = nil
    to_address   = ins["address"]

    # ======= Validation BRC-20 =======
    is_valid       = true
    invalid_reason = nil

    if op == "mint"
      unless mint_valid?(token, amt)
        is_valid       = false
        invalid_reason = "mint would exceed max_supply"
        Rails.logger.warn "BRC20Indexer: mint invalide pour #{tick} (amt=#{amt}), dépasse max_supply."
      end
    end
    # (plus tard tu pourras ajouter d'autres règles pour transfer, etc.)

    # ======= Enregistrement de l'event =======
    buffer_event!(
      brc20_token_id: token.id,
      tick:           tick,
      txid:           tx["txid"],
      inscription_id: ins["inscription_id"],
      block_height:   block["height"],
      block_hash:     block["hash"],
      block_time:     block_time,
      op:             op,
      amount:         amt,
      from_address:   from_address,
      to_address:     to_address,
      payload:        payload,
      is_valid:       is_valid,
      invalid_reason: invalid_reason,
      created_at:     Time.current,
      updated_at:     Time.current
    )

    @events_count += 1

    # ⚠️ On ne met à jour les stats QUE si l'event est valide
    return unless is_valid

    update_stats_for(
      token:        token,
      tick:         tick,
      op:           op,
      amount:       amt,
      block_height: block["height"],
      block_hash:   block["hash"],
      block_time:   block_time,
      from_address: from_address,
      to_address:   to_address
    )
  end

  # =======================
  #  Bulk insert des events
  # =======================

  def buffer_event!(attrs)
    @events_buffer << attrs
    flush_events! if @events_buffer.size >= BATCH_SIZE
  end

  def flush_events!
    return if @events_buffer.empty?

    Brc20Event.insert_all(@events_buffer)
    @events_buffer.clear
  end

  # =======================
  #  Création du token
  # =======================

  def find_or_create_token_from_deploy(payload, tick, ins, block, block_time)
    max = payload["max"]
    lim = payload["lim"]

    if max.nil? || max.to_s.strip.empty?
      Rails.logger.debug "BRC20Indexer: deploy sans 'max' pour tick=#{tick}, inscription=#{ins["inscription_id"]}, ignoré."
      return nil
    end

    Brc20Token.find_or_create_by!(tick: tick) do |t|
      t.deploy_inscription_id = ins["inscription_id"]
      t.deploy_txid           = block["tx"].first["txid"]
      t.deploy_block_height   = block["height"]
      t.deploy_block_hash     = block["hash"]
      t.deploy_block_time     = block_time
      t.max_supply            = max
      t.mint_limit            = lim
    end
  end

  # =======================
  #  Stats globales
  # =======================

  def update_stats_for(token:, tick:, op:, amount:, block_height:, block_hash:, block_time:, from_address:, to_address:)
    case op
    when "deploy"
      update_token_deploy_stats(token)
    when "mint"
      apply_mint(token, to_address, amount, block_time)
    when "transfer"
      apply_transfer(token, from_address, to_address, amount, block_time)
    end

    update_block_stats(tick, op, amount, block_height, block_hash)
    update_daily_stats(token, op, amount, block_time) unless @full_rescan
  end

  def update_token_deploy_stats(token)
    return unless token
    token.events_count = token.events_count.to_i + 1
    token.save!
  end

  def apply_mint(token, to_address, amount, block_time)
    return unless token
    amt = amount.to_i
    return if amt <= 0

    update_balance(token, to_address, :mint, amt, block_time)

    # On maintient aussi un total_minted cohérent au niveau du token
    token.total_minted = big_add(token.total_minted, amt)
    token.events_count = token.events_count.to_i + 1
    token.save!
  end

  def apply_transfer(token, from_address, to_address, amount, block_time)
    return unless token

    if from_address.present?
      update_balance(token, from_address, :debit, amount, block_time)
    end

    if to_address.present?
      update_balance(token, to_address, :credit, amount, block_time)
    end
  end

  def update_balance(token, address, kind, amount, seen_at)
    return if address.blank?

    amt = amount.to_i

    balance = Brc20Balance.find_or_initialize_by(
      brc20_token: token,
      address:     address
    ) do |b|
      b.tick            = token.tick
      b.balance         = "0"
      b.minted          = "0"
      b.transferred_in  = "0"
      b.transferred_out = "0"
      b.first_seen_at   = seen_at
    end

    balance.first_seen_at ||= seen_at
    balance.last_seen_at   = [balance.last_seen_at, seen_at].compact.max || seen_at

    prev_balance = balance.balance.to_i

    case kind
    when :mint
      balance.minted  = (balance.minted.to_i + amt).to_s
      balance.balance = (balance.balance.to_i + amt).to_s
    when :credit
      balance.transferred_in = (balance.transferred_in.to_i + amt).to_s
      balance.balance        = (balance.balance.to_i + amt).to_s
    when :debit
      balance.transferred_out = (balance.transferred_out.to_i + amt).to_s
      balance.balance         = (balance.balance.to_i - amt).to_s
    end

    new_balance = balance.balance.to_i
    if new_balance < 0
      new_balance     = 0
      balance.balance = "0"
    end

    balance.save!

    return if @full_rescan

    if prev_balance == 0 && new_balance > 0
      token.increment!(:holders_count)
    elsif prev_balance > 0 && new_balance == 0
      token.decrement!(:holders_count) if token.holders_count > 0
    end
  end

  def big_add(a, b)
    (a.to_i + b.to_i).to_s
  end

  def big_sub(a, b)
    (a.to_i - b.to_i).to_s
  end

  def update_block_stats(tick, op, amount, block_height, block_hash)
    stat = Brc20BlockStat.find_or_initialize_by(
      block_height: block_height,
      tick:         tick
    )

    stat.block_hash ||= block_hash

    case op
    when "deploy"
      stat.deploy_count += 1
      stat.deploy_max   ||= amount
    when "mint"
      stat.mint_count   += 1
      stat.mint_volume  = big_add(stat.mint_volume, amount)
    when "transfer"
      stat.transfer_count  += 1
      stat.transfer_volume = big_add(stat.transfer_volume, amount)
    end

    stat.save!
  end

  def update_daily_stats(token, op, amount, block_time)
    return unless token

    day   = block_time.to_date
    daily = Brc20TokenDailyStat.find_or_create_by!(brc20_token: token, day: day)

    case op
    when "mint"
      daily.mint_count   += 1
      daily.mint_volume  = big_add(daily.mint_volume, amount)
    when "transfer"
      daily.transfer_count  += 1
      daily.transfer_volume = big_add(daily.transfer_volume, amount)
    end

    daily.active_addresses_count = Brc20Balance
      .where(brc20_token: token)
      .where("last_seen_at >= ? AND last_seen_at < ?", day.beginning_of_day, day.end_of_day)
      .count

    daily.save!
  end

  # =======================
  #  Validation BRC-20
  # =======================

  # Vérifie qu'un mint ne dépasse pas la max_supply du token
  def mint_valid?(token, amount)
    return false unless token

    max_supply = token.max_supply.to_i
    return false if max_supply <= 0

    current_total = token.total_minted.to_i
    amt          = amount.to_i

    return false if amt <= 0

    (current_total + amt) <= max_supply
  end
end