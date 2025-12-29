# app/controllers/vaults_controller.rb
#
# ✅ Politique “Sparrow-first” (wallet complet)
# -------------------------------------------
# - Sparrow est la source de vérité
# - On stocke 2 descriptors "Bitcoin Core" :
#     - receive_descriptor : .../0/*))#checksum
#     - change_descriptor  : .../1/*))#checksum
# - On importe les 2 dans Bitcoin Core (watch-only)
# - On scanne les UTXOs (VaultUtxoScanner)
# - PSBT: build côté app, signature dans Sparrow, finalize/broadcast côté Core
#
class VaultsController < ApplicationController
  include VaultsAuthentication
  before_action :require_vaults_auth!

  WATCH_WALLET_NAME = "vault_watch3".freeze

  before_action :set_vault, only: %i[
    show edit update destroy
    import_watch_only
    psbt broadcast
    derive_addresses
  ]

  def index
    @vaults = Vault.order(created_at: :desc)
  end

  def show
    @balance_sats = @vault.balance_sats.to_i
    @balance_btc  = @vault.balance_btc
    @utxos        = []
    @scanned_now  = false
    @btc_eur = PriceTicker.btc_eur # <= à créer (service)
    @balance_eur = (@balance_btc.to_f * @btc_eur.to_f) if @btc_eur.present?

    # --- Watch-only status (best effort) ---
    @watch_info = nil
    if @vault.address.present?
      begin
        wallet      = ensure_watch_wallet_loaded!
        @watch_info = wallet.getaddressinfo(@vault.address)
      rescue => e
        Rails.logger.warn("[VaultsController#show] getaddressinfo failed vault=#{@vault.id}: #{e.class} #{e.message}")
        @watch_info = { "error" => e.message.to_s.byteslice(0, 220) }
      end
    end

    # --- Scan UTXO (à la demande ou si balance 0) ---
    if params[:rescan] == "1" || @vault.balance_sats.to_i.zero?
      begin
        scanner     = VaultUtxoScanner.new(@vault)
        scan_result = scanner.scan_and_persist!

        @utxos        = scan_result.utxos
        @balance_sats = scan_result.total_sats
        @balance_btc  = scan_result.total_btc
        @scanned_now  = true
      rescue => e
        Rails.logger.error("[VaultsController#show] Scan UTXO vault=#{@vault.id} #{e.class}: #{e.message}")
        flash.now[:alert] = "Erreur scan UTXO : #{e.message.to_s.byteslice(0, 220)}"
      end
    end

    return unless @vault.first_seen_block.present?

    @first_seen_block = @vault.first_seen_block

    begin
      rpc        = BitcoinRpc.new
      block_hash = rpc.get_block_hash(@first_seen_block)
      block      = rpc.get_block(block_hash)
      ts         = block["time"].to_i

      @first_seen_timestamp = Time.at(ts).utc
      @vault_age_days       = ((Time.current - @first_seen_timestamp) / 1.day).round(1)
    rescue => e
      Rails.logger.warn("[VaultsController#show] first_seen_block=#{@first_seen_block} #{e.class}: #{e.message}")
      @first_seen_timestamp = nil
      @vault_age_days       = nil
    end
  end

  def new
    @vault = Vault.new(
      network:    "mainnet",
      status:     "draft",
      scan_range: 200
    )
  end

  def create
    @vault = Vault.new(vault_params)

    if @vault.save
      redirect_to @vault, notice: "Wallet importé. Étape suivante : Import watch-only puis Rescanner."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @vault.update(vault_params)
      redirect_to @vault, notice: "Wallet mis à jour."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @vault.destroy
    redirect_to vaults_path, notice: "Wallet supprimé."
  end

  # POST /vaults/:id/derive_addresses
  def derive_addresses
    deriver = VaultAddressDeriver.new(@vault)
    n = deriver.derive_and_persist!(start_index: 0, stop_index: @vault.scan_range.to_i)

    redirect_to @vault, notice: "Adresses dérivées ✅ receive=#{n[:receive]} change=#{n[:change]}"
  rescue => e
    Rails.logger.error("[VaultsController#derive_addresses] vault=#{@vault.id} #{e.class}: #{e.message}")
    redirect_to @vault, alert: "Échec dérivation adresses : #{e.message.to_s.byteslice(0, 220)}"
  end

  # POST /vaults/:id/import_watch_only
  def import_watch_only
    wallet = ensure_watch_wallet_loaded!
    importer = VaultWatchOnlyImporter.new(@vault, wallet_rpc: wallet)

    range = range_from_vault

    raise "receive_descriptor manquant" if @vault.receive_descriptor.blank?
    raise "change_descriptor manquant"  if @vault.change_descriptor.blank?

    # receive (external)
    importer.import!(
      descriptor:       @vault.receive_descriptor,
      descriptor_kind:  "receive",
      timestamp:        params[:timestamp].presence || "now",
      active:           false,
      range:            range,
      internal:         false,
      persist_address:  true,   # ⚠️ "adresse de référence UI"
      enforce_match:    false
    )

    # change (internal)
    importer.import!(
      descriptor:       @vault.change_descriptor,
      descriptor_kind:  "change",
      timestamp:        params[:timestamp].presence || "now",
      active:           false,
      range:            range,
      internal:         true,
      persist_address:  false,
      enforce_match:    false
    )

    redirect_to @vault, notice: "Import watch-only OK ✅ (receive + change)"
  rescue => e
    Rails.logger.error("[VaultsController#import_watch_only] vault=#{@vault.id} #{e.class}: #{e.message}")
    redirect_to @vault, alert: "Import watch-only échoué : #{e.message.to_s.byteslice(0, 220)}"
  end

  def psbt
    if @vault.receive_descriptor.blank? && @vault.change_descriptor.blank?
      redirect_to(@vault, alert: "Descriptors manquants : impossible de générer une PSBT.") and return
    end

    destination = params[:destination_address].to_s.strip
    redirect_to(@vault, alert: "Adresse de destination requise.") and return if destination.blank?

    scanner     = VaultUtxoScanner.new(@vault)
    scan_result = scanner.scan
    utxos       = scan_result.utxos
    redirect_to(@vault, alert: "Aucun UTXO sur ce wallet, rien à dépenser.") and return if utxos.blank?

    balance_sats = scan_result.total_sats.to_i

    vsize_estimate     = 200
    feerate_sats_vb    = 5
    estimated_fee_sats = vsize_estimate * feerate_sats_vb

    max_fee_sats = (balance_sats * 0.25).to_i
    fee_sats     = [estimated_fee_sats, max_fee_sats].min

    min_output_sats = 500
    fee_sats = [balance_sats - min_output_sats, 0].max if (balance_sats - fee_sats) < min_output_sats
    redirect_to(@vault, alert: "Montant insuffisant pour couvrir les frais.") and return if (balance_sats - fee_sats) <= 0

    send_sats = balance_sats - fee_sats

    builder = VaultPsbtBuilder.new(
      @vault,
      utxos:               utxos,
      destination_address: destination,
      fee_sats:            fee_sats,
      rbf:                 true
    )

    result = builder.build

    debug_payload = {
      mode:          "normal",
      destination:   destination,
      balance_sats:  balance_sats,
      fee_sats:      fee_sats,
      send_sats:     send_sats,
      inputs_count:  result.inputs&.size,
      outputs_count: result.outputs&.size
    }

    @vault.update!(
      psbt_last_generated: result.psbt,
      psbt_last_mode:      "normal",
      psbt_last_debug:     JSON.pretty_generate(debug_payload),
      psbt_signed_by_a:    nil,
      psbt_signed_by_b:    nil
    )

    flash.now[:notice] = "PSBT générée. Signe dans Sparrow (A puis B) puis colle la PSBT signée."
    @psbt = result.psbt
    render :psbt
  rescue => e
    Rails.logger.error("[VaultsController#psbt] vault=#{@vault.id} #{e.class}: #{e.message}")
    redirect_to @vault, alert: "Erreur PSBT : #{e.message.to_s.byteslice(0, 220)}"
  end

  def broadcast
    node   = BitcoinRpc.new
    wallet = ensure_watch_wallet_loaded!

    psbts = []
    psbts << @vault.psbt_last_generated if @vault.psbt_last_generated.present?
    psbts << @vault.psbt_signed_by_a    if @vault.psbt_signed_by_a.present?
    psbts << @vault.psbt_signed_by_b    if @vault.psbt_signed_by_b.present?

    base_psbts = psbts.compact.uniq
    redirect_to(@vault, alert: "Aucune PSBT disponible à diffuser.") and return if base_psbts.empty?

    combined = base_psbts.size > 1 ? node.combinepsbt(base_psbts) : base_psbts.first

    processed = wallet.walletprocesspsbt(combined, false)
    combined  = processed["psbt"] if processed.is_a?(Hash) && processed["psbt"].present?

    final    = node.finalizepsbt(combined)
    tx_hex   = final["hex"]
    complete = final.key?("complete") ? final["complete"] : true

    if !complete || tx_hex.blank?
      redirect_to @vault, alert: "PSBT incomplète (signatures ou données manquantes)." and return
    end

    txid = node.sendrawtransaction(tx_hex)
    @vault.update(status: "closed") rescue nil

    redirect_to @vault, notice: "Transaction diffusée ✅ TXID : #{txid}"
  rescue => e
    Rails.logger.error("[VaultsController#broadcast] vault=#{@vault.id} #{e.class}: #{e.message}")
    redirect_to @vault, alert: "Erreur broadcast : #{e.message.to_s.byteslice(0, 220)}"
  end

  private

  def set_vault
    @vault = Vault.find(params[:id])
  end

  def vault_params
    params.require(:vault).permit(
      :label, :network, :status,
      :receive_descriptor, :change_descriptor,
      :scan_range,
      :address,
      :psbt_signed_by_a, :psbt_signed_by_b
    )
  end

  def range_from_vault
    n = @vault.scan_range.to_i
    n = 200 if n <= 0
    [0, n]
  end

  def ensure_watch_wallet_loaded!
    node = BitcoinRpc.new

    begin
      loaded = node.listwallets
      node.loadwallet(WATCH_WALLET_NAME) unless loaded.include?(WATCH_WALLET_NAME)
    rescue => e
      Rails.logger.warn("[VaultsController] loadwallet failed name=#{WATCH_WALLET_NAME}: #{e.class} #{e.message}")
    end

    BitcoinRpc.wallet(WATCH_WALLET_NAME)
  end

  def require_vaults_auth!
    return if session[:vaults_user_id].present?

    session[:vaults_return_to] = request.fullpath
    redirect_to "/vaults/login", alert: "Accès aux vaults protégé. Merci de signer un message via Sparrow."
  end
end
