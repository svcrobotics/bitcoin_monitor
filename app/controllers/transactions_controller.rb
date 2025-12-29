class TransactionsController < ApplicationController
  before_action :init_rpc

  def show
    @txid          = params[:id].to_s
    @block_height  = params[:block_height].presence&.to_i
    @block_hash    = params[:block_hash].presence
    @tx            = nil
    @error         = nil

    # 1) Charger la transaction
    if @block_height.present?
      load_tx_with_block_height(@txid, @block_height)
    elsif @block_hash.present?
      load_tx_with_block_hash(@txid, @block_hash)
    else
      load_tx_without_block(@txid)
    end

    unless @tx
      @inscriptions  = []
      @confirmations = 0
      @confirmed     = false
      return
    end

    # 2) Confirmations & statut
    if @block_height.present?
      tip            = @rpc.get_block_count.to_i
      @confirmations = [tip - @block_height + 1, 0].max
      @confirmed     = @confirmations.positive?
    else
      @confirmations = 0
      @confirmed     = false
    end

    # 3) Stats fees / montants
    @total_in_btc,
      @total_out_btc,
      @fee_btc,
      @fee_sats,
      @feerate_sat_vb = compute_fee_stats(@tx)

    # 4) Events BRC-20 liés à cette transaction
    @inscriptions = Brc20Event.where(txid: @txid).order(:id)

  rescue => e
    Rails.logger.error "[TransactionsController] Erreur show(#{@txid}): #{e.class} - #{e.message}"
    @error         = "Erreur lors de la récupération de la transaction : #{e.message}"
    @tx            = nil
    @inscriptions  = []
    @confirmations = 0
    @confirmed     = false
  end

  private

  def init_rpc
    @rpc = BitcoinRpc.new # chain
  end

  # Cas 1 : on connaît la hauteur → on dérive le block_hash
  def load_tx_with_block_height(txid, height)
    @block_hash = @rpc.getblockhash(height)

    # verbose=2 => on obtient "prevout" dans vin (utile pour fees)
    @tx = @rpc.getrawtransaction(txid, 2, @block_hash)
  rescue => e
    Rails.logger.error "[TransactionsController] load_tx_with_block_height(#{txid}, #{height}) : #{e.class} - #{e.message}"
    @error = "Impossible de récupérer la transaction #{txid} dans le bloc #{height} : #{e.message}"
    @tx    = nil
  end

  # Cas 2 : on connaît directement le block_hash
  def load_tx_with_block_hash(txid, block_hash)
    @block_hash = block_hash

    # verbose=2 => inclut prevout pour fees
    @tx = @rpc.getrawtransaction(txid, 2, @block_hash)

    # On récupère aussi la hauteur pour les confirmations
    block         = @rpc.getblock(@block_hash, 1)
    @block_height = block["height"]
  rescue => e
    Rails.logger.error "[TransactionsController] load_tx_with_block_hash(#{txid}, #{block_hash}) : #{e.class} - #{e.message}"
    @error        = "Impossible de récupérer la transaction #{txid} dans le bloc #{block_hash} : #{e.message}"
    @tx           = nil
    @block_height = nil
  end

  # Cas 3 : on ne connaît ni height ni hash (nécessite txindex=1 pour une tx confirmée)
  def load_tx_without_block(txid)
    # verbose=2 ou true (2 donne prevout si dispo)
    @tx = @rpc.getrawtransaction(txid, 2, nil)

    if @tx.is_a?(Hash) && @tx["blockhash"].present?
      @block_hash   = @tx["blockhash"]
      block         = @rpc.getblock(@block_hash, 1)
      @block_height = block["height"]
    end
  rescue => e
    Rails.logger.error "[TransactionsController] load_tx_without_block(#{txid}) : #{e.class} - #{e.message}"
    @error = "Impossible de récupérer cette transaction sans bloc (txindex requis). " \
             "Utilise un lien avec block_height ou block_hash. Détail: #{e.message}"
    @tx    = nil
  end

  # Calcule total_in, total_out, fee et feerate
  def compute_fee_stats(tx)
    return [nil, nil, nil, nil, nil] unless tx.is_a?(Hash)

    vouts         = tx["vout"] || []
    total_out_btc = vouts.sum { |vo| vo["value"].to_f }

    vins         = tx["vin"] || []
    total_in_btc = 0.0

    vins.each do |vin|
      prevout = vin["prevout"]
      next unless prevout && prevout["value"]
      total_in_btc += prevout["value"].to_f
    end

    fee_btc        = nil
    fee_sats       = nil
    feerate_sat_vb = nil

    if total_in_btc.positive? && total_out_btc >= 0 && total_in_btc >= total_out_btc
      fee_btc  = total_in_btc - total_out_btc
      fee_sats = (fee_btc * 100_000_000).round

      vsize = tx["vsize"].to_i
      feerate_sat_vb = (fee_sats.to_f / vsize).round(1) if vsize.positive?
    end

    [total_in_btc, total_out_btc, fee_btc, fee_sats, feerate_sat_vb]
  end
end
