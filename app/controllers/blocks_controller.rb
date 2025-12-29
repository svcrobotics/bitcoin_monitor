# app/controllers/blocks_controller.rb
require "set"

class BlocksController < ApplicationController
  before_action :init_rpc

  # GET /blocks
  def index
    tip_height = @rpc.get_block_count.to_i

    @per_page = 50
    @page     = params[:page].to_i
    @page     = 1 if @page < 1

    @search_height = params[:height].presence
    @search_day    = params[:day].presence

    # 1️⃣ Recherche par numéro de bloc
    if @search_height
      height = @search_height.to_i

      if height < 0 || height > tip_height
        @error         = "Bloc #{height} en dehors de la plage 0..#{tip_height}"
        @blocks        = []
        @has_next_page = false
        return
      end

      heights = [height]
      stats_by_height, scanned_heights = load_brc20_block_stats(heights)

      @blocks = heights.map do |h|
        build_block_row(h, stats_by_height, scanned_heights)
      end

      @has_next_page = false
      return
    end

    # 2️⃣ Recherche par date (JJ/MM/AAAA ou AAAA-MM-JJ)
    if @search_day
      begin
        day = Date.parse(@search_day)
      rescue ArgumentError
        @error         = "Date invalide"
        @blocks        = []
        @has_next_page = false
        return
      end

      from_h, to_h = find_block_range_for_day(day, tip_height)

      if from_h.nil? || to_h.nil?
        @error         = "Aucun bloc trouvé pour le #{day.strftime('%d/%m/%Y')}."
        @blocks        = []
        @has_next_page = false
        return
      end

      heights = (from_h..to_h).to_a.reverse
      stats_by_height, scanned_heights = load_brc20_block_stats(heights)

      @blocks = heights.map do |h|
        build_block_row(h, stats_by_height, scanned_heights)
      end

      @has_next_page = false
      return
    end

    # 3️⃣ Mode normal : pagination (les blocs les plus récents)
    start_height = tip_height - (@page - 1) * @per_page
    end_height   = [start_height - @per_page + 1, 0].max

    heights = (end_height..start_height).to_a.reverse

    stats_by_height, scanned_heights = load_brc20_block_stats(heights)

    @blocks = heights.map do |h|
      build_block_row(h, stats_by_height, scanned_heights)
    end

    @has_next_page = end_height > 0
  rescue => e
    @error         = e.message
    @blocks        = []
    @has_next_page = false
  end

  # GET /blocks/:id
  def show
    height       = params[:id].to_i

    # 1) Hash du bloc
    block_hash   = @rpc.get_block_hash(height)
    @block_hash  = block_hash
    @block_height = height

    # 2) Bloc complet (niveau 2 pour avoir les tx complètes)
    @block = @rpc.get_block(block_hash, 2)
    txs    = @block["tx"] || []

    # 3) Tous les events BRC-20 de CE bloc
    events         = Brc20Event.where(block_height: height)
    events_by_txid = events.group_by(&:txid)

    # 🔍 paramètres du "moteur de recherche deploy"
    deploy_tick_raw   = params[:deploy_tick]           # ce qui vient du champ texte
    deploy_tick_param = deploy_tick_raw.to_s.strip.downcase
    filter_by_deploy  = params.key?(:deploy_tick)      # vrai seulement si le formulaire a été soumis

    Rails.logger.info "[BRC20 SHOW] params=#{params.to_unsafe_h.inspect}"
    Rails.logger.info "[BRC20 SHOW] filter_by_deploy=#{filter_by_deploy}, deploy_tick_param=#{deploy_tick_param.inspect}"

    @tx_rows = txs.each_with_index.map do |tx, idx|
      txid = tx["txid"]
      evts = events_by_txid[txid] || []

      # tous les ticks
      ticks = evts.map(&:tick).compact.uniq

      # uniquement les events de type "deploy"
      deploy_evts  = evts.select { |e| e.op.to_s.downcase == "deploy" }
      deploy_ticks = deploy_evts.map(&:tick).compact.uniq

      {
        index:              idx,
        tx:                 tx,
        txid:               txid,
        has_brc20:          evts.any?,
        brc20_count:        evts.size,
        brc20_ticks:        ticks,
        brc20_deploy_count: deploy_evts.size,
        brc20_deploy_ticks: deploy_ticks
      }
    end

    # 4) Application du filtre "deploy"
    if filter_by_deploy
      if deploy_tick_param.present?
        # Cas 1 : tick saisi -> seulement les tx avec un deploy pour CE tick
        @tx_rows.select! do |row|
          row[:brc20_deploy_ticks].any? { |t| t.to_s.downcase == deploy_tick_param }
        end
      else
        # Cas 2 : formulaire soumis mais tick vide -> toutes les tx qui ont AU MOINS un deploy
        @tx_rows.select! do |row|
          row[:brc20_deploy_count].to_i > 0
        end
      end
    end
  rescue => e
    @error   = "Bitcoin RPC error: #{e.message}"
    @block   = nil
    @tx_rows = []
  end

  private

  def init_rpc
    @rpc = BitcoinRpc.new
  end

  # ========= Helpers BRC-20 pour l'index =========

  # Charge les stats BRC-20 (ops & blocs scannés) pour un ensemble de hauteurs
  def load_brc20_block_stats(heights)
    return [{}, Set.new] if heights.blank?

    stats = Brc20BlockStat.where(block_height: heights)

    # stats_by_height[height] = { ops: Integer, ticks: [String, ...] }
    stats_by_height = {}

    stats.each do |row|
      h = row.block_height

      stats_by_height[h] ||= { ops: 0, ticks: Set.new }

      # on additionne toutes les ops BRC-20 de ce bloc
      stats_by_height[h][:ops] +=
        row.deploy_count.to_i +
        row.mint_count.to_i +
        row.transfer_count.to_i

      # on stocke le tick si présent
      stats_by_height[h][:ticks] << row.tick if row.respond_to?(:tick) && row.tick.present?
    end

    # on convertit les Set en Array pour la vue
    stats_by_height.each_value do |v|
      v[:ticks] = v[:ticks].to_a
    end

    scanned_heights = stats.map(&:block_height).uniq.to_set

    [stats_by_height, scanned_heights]
  end

  # Construit un "row" pour l'index des blocs
  def build_block_row(height, stats_by_height, scanned_heights)
    hash  = @rpc.get_block_hash(height)
    block = @rpc.get_block(hash, 1)

    stat = stats_by_height[height] || {}

    {
      height:          height,
      hash:            hash,
      time:            Time.at(block["time"]).in_time_zone("Europe/Paris"),
      tx_count:        (block["tx"] || []).size,
      size_bytes:      block["size"],
      weight:          block["weight"],
      brc20_ops_count: stat[:ops]   || 0,
      brc20_ticks:     stat[:ticks] || [],
      brc20_scanned:   scanned_heights.include?(height)
    }
  end

  # ========= Recherche par date =========

  # Retourne [first_height, last_height] pour une journée donnée (heure de Paris)
  def find_block_range_for_day(day, tip_height)
    target_start = day.beginning_of_day.in_time_zone("Europe/Paris").to_i
    target_end   = day.end_of_day.in_time_zone("Europe/Paris").to_i

    # 1) Binary search : premier bloc >= début de journée
    low   = 0
    high  = tip_height
    first = nil

    while low <= high
      mid = (low + high) / 2
      t   = block_time_for_height(mid)

      if t < target_start
        low = mid + 1
      else
        first = mid
        high  = mid - 1
      end
    end

    return [nil, nil] if first.nil?

    # 2) Avance jusqu'au dernier bloc <= fin de journée
    last = first
    while last + 1 <= tip_height
      t = block_time_for_height(last + 1)
      break if t > target_end
      last += 1
    end

    [first, last]
  end

  # Timestamp (Unix) pour un height donné
  def block_time_for_height(height)
    hash  = @rpc.get_block_hash(height)
    block = @rpc.get_block(hash, 1)
    block["time"].to_i
  end

  # ==== 🔧 Helper d’extraction du tick ====
  def extract_tick_from_inscription(ins)
    # Cas 1 : ActiveRecord / PORO avec méthode `tick`
    return ins.tick if ins.respond_to?(:tick)

    return nil unless ins.is_a?(Hash)

    # Cas 2 : directement au premier niveau
    return ins[:tick]  if ins.key?(:tick)  && ins[:tick].present?
    return ins["tick"] if ins.key?("tick") && ins["tick"].present?

    # Cas 3 : dans une clé :op
    if ins.key?(:op)
      op = ins[:op]
      if op.is_a?(Hash)
        return op[:tick]  if op.key?(:tick)  && op[:tick].present?
        return op["tick"] if op.key?("tick") && op["tick"].present?
      end
    end

    if ins.key?("op")
      op = ins["op"]
      if op.is_a?(Hash)
        return op[:tick]  if op.key?(:tick)  && op[:tick].present?
        return op["tick"] if op.key?("tick") && op["tick"].present?
      end
    end

    # Cas 4 : parfois rangé dans :data, :parsed, etc.
    if ins.key?(:data)
      data = ins[:data]
      if data.is_a?(Hash)
        return data[:tick]  if data.key?(:tick)  && data[:tick].present?
        return data["tick"] if data.key?("tick") && data["tick"].present?
      end
    end

    if ins.key?("data")
      data = ins["data"]
      if data.is_a?(Hash)
        return data[:tick]  if data.key?(:tick)  && data[:tick].present?
        return data["tick"] if data.key?("tick") && data["tick"].present?
      end
    end

    nil
  end
end
