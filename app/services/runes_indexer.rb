# app/services/runes_indexer.rb
require "set"
require "bigdecimal"

class RunesIndexer
  def initialize(rpc: BitcoinRpc.new, logger: Rails.logger)
    @rpc    = rpc
    @logger = logger
  end

  #
  # Scan un bloc précis et indexe les événements Runes détectés.
  # Retourne le nombre d'événements créés.
  #
  def scan_block(height)
    height      = height.to_i
    block_hash  = @rpc.get_block_hash(height)
    block       = @rpc.get_block(block_hash, 2) # 2 = tx décodées
    block_time  = Time.at(block["time"]).utc
    txs         = block["tx"] || []

    rune_tx_count        = 0
    rune_events_count    = 0
    distinct_runes_ids   = Set.new
    total_runes_volume   = BigDecimal("0")
    total_runes_bytes    = 0

    ActiveRecord::Base.transaction do
      # Nettoyage du bloc avant réindexation
      RuneEvent.where(block_height: height).delete_all
      RuneBlockStat.where(block_height: height).delete_all

      txs.each_with_index do |tx, tx_index|
        events = RunesDecoder.decode_tx(
          tx:           tx,
          block_height: height,
          block_time:   block_time,
          tx_index:     tx_index
        )

        next if events.blank?

        rune_tx_count += 1

        events.each do |e|
          token = resolve_rune_token(e)

          amount = e[:amount].present? ? BigDecimal(e[:amount].to_s) : nil
          rune_events_count += 1
          total_runes_volume += (amount || 0)

          # Taille brute du payload si dispo
          if e[:raw_payload].is_a?(Hash)
            hex = e[:raw_payload]["script_hex"].to_s
            total_runes_bytes += (hex.size / 2) if hex.present?
          end

          distinct_runes_ids << token.id if token

          RuneEvent.create!(
            rune_token:   token,                         # peut être nil en V1
            rune_name:    e[:rune_name],                 # nullable dans le schéma
            op:           (e[:op].presence || "unknown"),# NOT NULL
            txid:         tx["txid"],
            vout:         e[:vout],
            vin:          e[:vin],
            block_height: e[:block_height] || height,
            block_time:   e[:block_time]  || block_time,
            amount:       amount,
            from_address: e[:from_address],
            to_address:   e[:to_address],
            is_valid:     e.key?(:is_valid) ? !!e[:is_valid] : true,
            raw_payload:  e[:raw_payload]
          )
        end
      end

      # Statistiques par bloc
      RuneBlockStat.create!(
        block_height:        height,
        block_time:          block_time,
        rune_tx_count:       rune_tx_count,
        rune_events_count:   rune_events_count,
        distinct_runes_count: distinct_runes_ids.size,
        total_runes_volume:  total_runes_volume,
        total_runes_bytes:   total_runes_bytes
      )
    end

    @logger.info "[RunesIndexer] Bloc #{height} → #{rune_events_count} événement(s) Runes"
    rune_events_count
  rescue => e
    @logger.error "[RunesIndexer] Erreur sur bloc #{height} : #{e.class} - #{e.message}"
    0
  end

  #
  # Scan une plage de blocs [from_height..to_height]
  #
  def scan_range(from_height, to_height)
    from = [from_height.to_i, 0].max
    to   = [to_height.to_i, from].max

    (from..to).each do |h|
      n = scan_block(h)
      @logger.info "[RunesIndexer] Terminé bloc #{h}, #{n} event(s) Runes."
    end
  end

  #
  # Méthode de classe pratique :
  #   RunesIndexer.scan_range(864_330, 864_360)
  #
  def self.scan_range(from_height, to_height)
    new.scan_range(from_height, to_height)
  end

  private

  # V1 : on ne crée un RuneToken que si le decoder fournit un rune_name + rune_id_block + rune_id_tx.
  # Sinon on laisse rune_token_id à nil (autorisé dans ton schéma).
  def resolve_rune_token(e)
    rune_name     = e[:rune_name].presence
    rune_id_block = e[:rune_id_block]
    rune_id_tx    = e[:rune_id_tx]

    return nil unless rune_name && rune_id_block && rune_id_tx

    normalized = rune_name.downcase

    RuneToken.find_or_create_by!(
      rune_id_block: rune_id_block,
      rune_id_tx:    rune_id_tx
    ) do |t|
      t.rune_name       = rune_name
      t.normalized_name = normalized
      t.etching_txid    = e[:txid] if e[:txid].present?
      t.etching_vout    = e[:vout] if e[:vout].present?
      t.etching_block_height = e[:block_height]
      t.etching_block_time   = e[:block_time]
    end
  end
end
