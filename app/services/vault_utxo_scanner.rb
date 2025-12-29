# app/services/vault_utxo_scanner.rb
require "bigdecimal"
require "bigdecimal/util"

class VaultUtxoScanResult
  SATS_PER_BTC = 100_000_000
  attr_reader :vault, :utxos, :total_sats, :total_btc

  def initialize(vault:, utxos:)
    @vault = vault
    @utxos = Array(utxos)

    @total_sats = @utxos.sum { |u| (u.fetch("amount").to_d * SATS_PER_BTC).to_i }
    @total_btc  = @total_sats.to_d / SATS_PER_BTC
  end
end

class VaultUtxoScanner
  DEFAULT_BATCH_SIZE = 100

  # Retry court pour absorber le "Wallet already loading" (loadwallet async)
  WALLET_LOAD_RETRIES = 5
  WALLET_LOAD_SLEEP_S = 0.2

  def initialize(vault, wallet_rpc: BitcoinRpc.vault_watch, chain_rpc: BitcoinRpc.new, logger: Rails.logger)
    @vault      = vault
    @wallet_rpc = wallet_rpc
    @chain_rpc  = chain_rpc
    @logger     = logger
  end

  def scan(min_confirmations: 1, include_unsafe: false, batch_size: DEFAULT_BATCH_SIZE)
    addresses, addr_meta = fetch_addresses_and_meta
    @logger.info "[VaultUtxoScanner] Scan(read-only) vault=#{@vault.id} addrs=#{addresses.size} minconf=#{min_confirmations}"

    return VaultUtxoScanResult.new(vault: @vault, utxos: []) if addresses.empty?

    raw_utxos  = with_wallet_ready { listunspent_for_addresses(addresses, minconf: min_confirmations, include_unsafe: include_unsafe, batch_size: batch_size) }
    tip_height = safe_best_block_height
    utxos      = enrich_utxos(raw_utxos, tip_height, addr_meta)

    VaultUtxoScanResult.new(vault: @vault, utxos: utxos)
  end

  def scan_and_persist!(min_confirmations: 0, include_unsafe: true, batch_size: DEFAULT_BATCH_SIZE, persist_last_seen: true)
    addresses, addr_meta = fetch_addresses_and_meta
    @logger.info "[VaultUtxoScanner] Scan(persist) vault=#{@vault.id} addrs=#{addresses.size} minconf=#{min_confirmations}"

    return persist_empty_result!("Aucune adresse (VaultAddress vide)") if addresses.empty?

    raw_utxos  = with_wallet_ready { listunspent_for_addresses(addresses, minconf: min_confirmations, include_unsafe: include_unsafe, batch_size: batch_size) }
    tip_height = safe_best_block_height
    utxos      = enrich_utxos(raw_utxos, tip_height, addr_meta)

    scan_result      = VaultUtxoScanResult.new(vault: @vault, utxos: utxos)
    first_seen_block = compute_first_seen_block(utxos, tip_height)

    @vault.update!(
      balance_sats:            scan_result.total_sats,
      utxos_count:             utxos.size,
      utxos_unconfirmed_count: utxos.count { |u| (u["confirmations"] || 0).to_i == 0 },
      last_scanned_at:         Time.current,
      last_scan_status:        "ok",
      last_scan_error:         nil,
      first_seen_block:        choose_first_seen(first_seen_block)
    )

    persist_last_seen_blocks!(utxos, addr_meta) if persist_last_seen

    scan_result
  rescue => e
    @logger.error "[VaultUtxoScanner] Error vault=#{@vault.id}: #{e.class} - #{e.message}"
    @vault.update(last_scanned_at: Time.current, last_scan_status: "error", last_scan_error: e.message) rescue nil
    raise
  end

  private

  # === Wallet loading guard ===================================================

  def with_wallet_ready(&block)
    ensure_wallet_loaded!
    yield
  end

  def ensure_wallet_loaded!
    name = wallet_name_for_scan

    # déjà chargé -> OK
    return if wallet_loaded?(name)

    WALLET_LOAD_RETRIES.times do |attempt|
      begin
        @logger.info "[VaultUtxoScanner] loadwallet name=#{name} attempt=#{attempt + 1}/#{WALLET_LOAD_RETRIES}"
        @chain_rpc.loadwallet(name)

        # loadwallet peut être async : on re-check immédiatement
        return if wallet_loaded?(name)

        # si pas encore visible, petit sleep puis recheck
        sleep WALLET_LOAD_SLEEP_S
        return if wallet_loaded?(name)

      rescue => e
        msg = e.message.to_s

        # cas exact de ton erreur
        if msg.include?("Wallet already loading") || msg.include?("already loading")
          @logger.warn "[VaultUtxoScanner] wallet already loading name=#{name} (attempt #{attempt + 1})"
          sleep WALLET_LOAD_SLEEP_S
          return if wallet_loaded?(name)
          next
        end

        # parfois : "Wallet file verification failed" / autres -> on remonte
        raise
      end
    end

    # dernière chance : si finalement chargé, ça passe
    return if wallet_loaded?(name)

    raise "Wallet '#{name}' non chargé après #{WALLET_LOAD_RETRIES} tentatives"
  end

  def wallet_loaded?(wallet_name)
    Array(@chain_rpc.listwallets).include?(wallet_name)
  rescue => e
    @logger.warn "[VaultUtxoScanner] listwallets failed: #{e.class} - #{e.message}"
    false
  end

  # ⚠️ adapte ici si ton nom est ailleurs (ex: @vault.watch_wallet_name)
  def wallet_name_for_scan
    # si tu as un champ: @vault.wallet_name || @vault.watch_wallet_name, mets-le ici.
    # par défaut, je colle à ton message d'erreur :
    "vault_watch3"
  end

  # === Address list ===========================================================

  def fetch_addresses_and_meta
    rows = VaultAddress
      .where(vault_id: @vault.id)
      .order(:kind, :index)
      .pluck(:address, :kind, :index)

    addr_meta = {}
    addresses = []

    rows.each do |address, kind, index|
      next if address.blank?
      addresses << address
      addr_meta[address] = { kind: kind, index: index }
    end

    # fallback : adresse de référence UI si jamais
    if @vault.address.present? && !addr_meta.key?(@vault.address)
      addresses << @vault.address
      addr_meta[@vault.address] ||= { kind: "reference", index: nil }
    end

    # Option: limiter aux branches dérivées par scan_range (2 branches)
    max = (@vault.scan_range.to_i * 2) + 10
    addresses = addresses.first(max)

    [addresses.uniq, addr_meta]
  end

  # === RPC / UTXOs ============================================================

  def listunspent_for_addresses(addresses, minconf:, include_unsafe:, batch_size:)
    utxos = []
    addresses.each_slice(batch_size) do |slice|
      part = @wallet_rpc.listunspent(
        minconf: minconf,
        maxconf: 9_999_999,
        addresses: slice,
        include_unsafe: include_unsafe
      )
      utxos.concat(Array(part))
    end
    utxos
  end

  def safe_best_block_height
    @chain_rpc.best_block_height
  rescue => e
    @logger.warn "[VaultUtxoScanner] best_block_height failed: #{e.class} - #{e.message}"
    nil
  end

  def enrich_utxos(raw_utxos, tip_height, addr_meta)
    Array(raw_utxos).map do |u|
      conf   = u["confirmations"].to_i
      height = (tip_height && conf > 0) ? (tip_height - conf + 1) : nil

      addr = u["address"].presence
      meta = addr ? addr_meta[addr] : nil

      u.merge(
        "height" => height,
        "kind"   => meta&.dig(:kind),
        "index"  => meta&.dig(:index)
      )
    end
  end

  def compute_first_seen_block(utxos, tip_height)
    heights = Array(utxos).map { |u| u["height"] }.compact
    return heights.min if heights.any?
    tip_height
  end

  def choose_first_seen(new_first_seen)
    return @vault.first_seen_block if new_first_seen.nil?
    return new_first_seen if @vault.first_seen_block.nil?
    [@vault.first_seen_block, new_first_seen].min
  end

  def persist_empty_result!(reason)
    @logger.warn "[VaultUtxoScanner] Empty scan vault=#{@vault.id}: #{reason}"
    @vault.update!(
      balance_sats: 0,
      utxos_count: 0,
      utxos_unconfirmed_count: 0,
      last_scanned_at: Time.current,
      last_scan_status: "ok",
      last_scan_error: nil
    )
    VaultUtxoScanResult.new(vault: @vault, utxos: [])
  end

  def persist_last_seen_blocks!(utxos, addr_meta)
    updates = {}

    utxos.each do |u|
      addr   = u["address"].to_s
      height = u["height"]
      next if addr.blank? || height.nil?
      next unless addr_meta.key?(addr)

      updates[addr] = [updates[addr], height].compact.max
    end

    return if updates.empty?

    updates.each_slice(200) do |slice|
      slice.each do |addr, h|
        VaultAddress.where(vault_id: @vault.id, address: addr)
          .where("last_seen_block IS NULL OR last_seen_block < ?", h)
          .update_all(last_seen_block: h, updated_at: Time.current)
      end
    end
  end
end
