# app/services/brc20_scanner.rb
class Brc20Scanner
  def initialize(rpc)
    @rpc = rpc
  end

  # Top tokens BRC-20 les plus actifs sur les X derniers blocs (scan direct RPC)
  # Utile surtout au début, une fois la base remplie on préférera lire Brc20BlockStat.
  def top_tokens(last_blocks: 2016, limit: 10)
    tip_height  = @rpc.get_block_count
    from_height = [tip_height - last_blocks + 1, 0].max

    stats = empty_stats_hash

    (from_height..tip_height).each do |hgt|
      block_hash = @rpc.get_block_hash(hgt)
      block      = @rpc.get_block(block_hash, 2) # tx complètes

      (block["tx"] || []).each do |tx|
        scan_tx_for_brc20(tx, stats)
      end
    end

    stats_to_array(stats, limit)
  rescue StandardError => e
    Rails.logger.error("[Brc20Scanner] Erreur: #{e.class} - #{e.message}")
    []
  end

  # ==========
  #  MODE STATIQUE POUR LA TÂCHE RAKE
  # ==========

  # Analyse un bloc (JSON getblock verbosity=2) et retourne :
  # { "sats" => { deploy_count: X, ... }, "ordi" => { ... }, ... }
  def self.extract_from_block(block)
    stats = empty_stats_hash

    (block["tx"] || []).each do |tx|
      vins = tx["vin"] || []
      vins.each do |vin|
        witnesses = vin["txinwitness"] || []
        witnesses.each do |whex|
          parse_witness_hex_for_brc20(whex, stats)
        end
      end
    end

    stats
  end

  # ==========
  #  PARTIE INSTANCE
  # ==========

  private

  def scan_tx_for_brc20(tx, stats)
    vins = tx["vin"] || []
    vins.each do |vin|
      witnesses = vin["txinwitness"] || []
      witnesses.each do |whex|
        self.class.parse_witness_hex_for_brc20(whex, stats)
      end
    end
  end

  # ==========
  #  LOGIQUE COMMUNE
  # ==========

  def self.empty_stats_hash
    Hash.new do |h, k|
      h[k] = {
        total_ops:       0,
        deploy_count:    0,
        deploy_max:      nil,
        mint_count:      0,
        mint_volume:     0,
        transfer_count:  0,
        transfer_volume: 0
      }
    end
  end

  def empty_stats_hash
    self.class.empty_stats_hash
  end

  def self.parse_witness_hex_for_brc20(whex, stats)
    data = [whex].pack("H*")

    idx = data.index('"p":"brc-20"')
    return unless idx

    start_idx = data.rindex("{", idx) || 0
    end_idx   = data.index("}", idx) || (data.length - 1)
    json_str  = data[start_idx..end_idx]

    json = JSON.parse(json_str) rescue nil
    return unless json.is_a?(Hash)
    return unless json["p"] == "brc-20"

    tick = json["tick"] || json["symbol"] || json["ticker"]
    return if tick.nil? || tick.empty?

    tick = tick.to_s.strip.downcase

    op  = json["op"].to_s.downcase
    amt = json["amt"]&.to_i || 0

    stats[tick][:total_ops] += 1

    case op
    when "deploy"
      stats[tick][:deploy_count] += 1
      max_supply = json["max"]&.to_i
      stats[tick][:deploy_max] ||= max_supply if max_supply && max_supply > 0
    when "mint"
      stats[tick][:mint_count]  += 1
      stats[tick][:mint_volume] += amt if amt > 0
    when "transfer"
      stats[tick][:transfer_count]  += 1
      stats[tick][:transfer_volume] += amt if amt > 0
    else
      # autres op éventuelles → juste comptées dans total_ops
    end
  rescue StandardError => e
    Rails.logger.debug("[Brc20Scanner] Witness parse error: #{e.class} - #{e.message}")
  end

  def stats_to_array(stats, limit)
    stats.map do |tick, data|
      {
        tick:             tick,
        total_ops:        data[:total_ops],
        deploy_count:     data[:deploy_count],
        deploy_max:       data[:deploy_max],
        mint_count:       data[:mint_count],
        mint_volume:      data[:mint_volume],
        transfer_count:   data[:transfer_count],
        transfer_volume:  data[:transfer_volume]
      }
    end.sort_by { |e| -e[:total_ops] }
       .first(limit)
  end
end
