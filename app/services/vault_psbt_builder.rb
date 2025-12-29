# app/services/vault_psbt_builder.rb
require "bigdecimal"
require "bigdecimal/util"

class VaultPsbtBuilder
  SATS_PER_BTC = 100_000_000

  Result = Struct.new(
    :psbt,
    :inputs,
    :outputs,
    :fee_sats,
    :total_in_sats,
    :total_out_sats,
    :mode,
    :csv_delay_blocks,
    :debug,
    keyword_init: true
  )

  def initialize(vault, utxos:, destination_address:, fee_sats: 10_000, rbf: true, sanity_check: true)
    @vault               = vault
    @utxos               = Array(utxos)
    @destination_address = destination_address.to_s.strip
    @fee_sats            = fee_sats.to_i
    @rbf                 = !!rbf
    @sanity_check        = !!sanity_check

    @rpc        = BitcoinRpc.new
    @wallet_rpc = BitcoinRpc.vault_watch
  end

  def build
    raise "Aucun UTXO disponible pour ce vault" if @utxos.blank?
    raise "Adresse de destination requise" if @destination_address.blank?
    raise "redeem_script_hex manquant (witness_script)" if @vault.redeem_script_hex.blank?

    # ✅ validation robuste (Core + réseau)
    @rpc.validate_destination_address!(@destination_address, network: @vault.network)
    ensure_destination_valid!

    # Total in sats (sans float)
    total_in_sats = utxos_total_in_sats(@utxos)

    raise "Solde insuffisant (#{total_in_sats} sats)" if total_in_sats <= 0
    raise "Solde insuffisant pour couvrir les frais (in=#{total_in_sats} fee=#{@fee_sats})" if total_in_sats <= @fee_sats

    total_out_sats = total_in_sats - @fee_sats

    # outputs: Core accepte les montants en string (évite float)
    out_btc = sats_to_btc_str(total_out_sats)
    outputs = { @destination_address => out_btc }

    # ✅ A+B uniquement
    mode             = "normal"
    csv_delay_blocks = nil

    # RBF si sequence < 0xfffffffe
    sequence_value = @rbf ? 0xfffffffd : 0xffffffff

    inputs = @utxos.map do |u|
      {
        "txid"     => u.fetch("txid"),
        "vout"     => u.fetch("vout"),
        "sequence" => sequence_value
      }
    end

    # 1) PSBT brute
    psbt = @rpc.create_psbt(inputs, outputs)

    # 2) Ajoute witness_utxo / non_witness_utxo si possible
    psbt = @rpc.utxoupdatepsbt(psbt)

    # 3) Optionnel: laisse le wallet watch-only compléter ce qu'il peut (descriptors, etc.)
    psbt = try_walletprocesspsbt(psbt)

    # 4) Injecte le witness_script (P2WSH)
    psbt = PsbtTools.inject_witness_script(psbt, @vault.redeem_script_hex)

    # 5) Injecte les bip32 derivations (Ledger/HWI)
    base_path = @vault.derivation_path.presence || "m/48'/0'/0'/2'"
    ensure_bip48_path!(base_path)

    psbt = PsbtTools.inject_bip32_derivs(
      psbt,
      pubkeys: {
        a: @vault.pubkey_a_child.presence || @vault.pubkey_a,
        b: @vault.pubkey_b_child.presence || @vault.pubkey_b
      },
      fingerprints: {
        a: @vault.ledger_a_fp,
        b: @vault.ledger_b_fp
      },
      derivation_path:  base_path,
      derivation_index: @vault.derivation_index.to_i
    )

    debug = build_debug(
      psbt,
      inputs_count: inputs.size,
      outputs_count: outputs.size,
      total_in_sats: total_in_sats,
      fee_sats: @fee_sats,
      total_out_sats: total_out_sats
    )

    # 6) Sanity check renforcé (structure + montants + scripts + bip32)
    sanity_check!(
      psbt,
      expected_inputs: inputs,
      expected_destination: @destination_address,
      expected_total_in_sats: total_in_sats,
      expected_total_out_sats: total_out_sats,
      expected_fee_sats: @fee_sats,
      expected_base_path: base_path
    ) if @sanity_check

    Result.new(
      psbt:             psbt,
      inputs:           inputs,
      outputs:          outputs,
      fee_sats:         @fee_sats,
      total_in_sats:    total_in_sats,
      total_out_sats:   total_out_sats,
      mode:             mode,
      csv_delay_blocks: csv_delay_blocks,
      debug:            debug
    )
  end

  private

  def utxos_total_in_sats(utxos)
    utxos.sum do |u|
      # amount est en BTC (float/json), on force BigDecimal
      (u.fetch("amount").to_d * SATS_PER_BTC).to_i
    end
  end

  def sats_to_btc_str(sats)
    (sats.to_d / SATS_PER_BTC).to_s("F")
  end

  def ensure_destination_valid!
    val = @rpc.validateaddress(@destination_address)
    raise "Adresse de destination invalide" unless val.is_a?(Hash) && val["isvalid"]

    # Sécurité anti-erreur réseau (simple et efficace)
    net = @vault.network.to_s
    if net == "mainnet"
      raise "Adresse de destination testnet détectée (tb1)" if @destination_address.start_with?("tb1")
      raise "Adresse de destination regtest détectée (bcrt1)" if @destination_address.start_with?("bcrt1")
    elsif net == "testnet"
      raise "Adresse de destination mainnet détectée (bc1)" if @destination_address.start_with?("bc1")
      raise "Adresse de destination regtest détectée (bcrt1)" if @destination_address.start_with?("bcrt1")
    elsif net == "regtest"
      raise "Adresse de destination mainnet détectée (bc1)" if @destination_address.start_with?("bc1")
      raise "Adresse de destination testnet détectée (tb1)" if @destination_address.start_with?("tb1")
    end
  rescue => e
    raise "Adresse de destination invalide (validateaddress): #{e.message}"
  end

  def ensure_bip48_path!(base_path)
    # Pour P2WSH multisig, on veut BIP48 (m/48'/coin'/account'/2')
    p = base_path.to_s
    raise "derivation_path vide" if p.blank?
    unless p.start_with?("m/48'/") || p.start_with?("m/48h/")
      raise "derivation_path invalide pour multisig P2WSH (attendu BIP48 m/48'/.../2'): #{p}"
    end
    unless p.include?("/2'") || p.include?("/2h/")
      raise "derivation_path invalide: doit contenir /2' (P2WSH multisig): #{p}"
    end
  end

  def try_walletprocesspsbt(psbt)
    res = @wallet_rpc.walletprocesspsbt(psbt, false)
    res.is_a?(Hash) && res["psbt"].present? ? res["psbt"] : psbt
  rescue
    psbt
  end

  def sanity_check!(psbt,
                    expected_inputs:,
                    expected_destination:,
                    expected_total_in_sats:,
                    expected_total_out_sats:,
                    expected_fee_sats:,
                    expected_base_path:)
    decoded = @rpc.decodepsbt(psbt)
    raise "PSBT invalide: decodepsbt vide" unless decoded.is_a?(Hash)

    # --- Vérif inputs/outpoints match ---
    tx  = decoded["tx"] || {}
    vin = tx["vin"] || []
    raise "PSBT invalide: vin vide" if vin.empty?

    exp = expected_inputs.map { |i| [i["txid"].to_s, i["vout"].to_i] }.sort
    got = vin.map { |i| [i["txid"].to_s, i["vout"].to_i] }.sort
    raise "PSBT inputs mismatch: expected=#{exp.inspect} got=#{got.inspect}" if exp != got

    # --- Vérif output destination + montant ---
    vout = tx["vout"] || []
    raise "PSBT invalide: vout vide" if vout.empty?

    out = vout.find { |o| o.dig("scriptPubKey", "address").to_s == expected_destination }
    raise "Destination absente des outputs PSBT: #{expected_destination}" unless out

    expected_out_btc = (expected_total_out_sats.to_d / SATS_PER_BTC)
    actual_out_btc   = out["value"].to_d
    raise "Montant output inattendu: expected=#{expected_out_btc.to_s('F')} got=#{actual_out_btc.to_s('F')}" unless actual_out_btc == expected_out_btc

    # --- Vérif fee ---
    expected_fee_btc = (expected_fee_sats.to_d / SATS_PER_BTC)
    actual_fee_btc   = decoded["fee"].to_d
    raise "Fee inattendue: expected=#{expected_fee_btc.to_s('F')} got=#{actual_fee_btc.to_s('F')}" unless actual_fee_btc == expected_fee_btc

    # --- Vérif champs Ledger/HWI sur chaque input ---
    psbt_inputs = decoded["inputs"] || []
    raise "PSBT invalide: aucun input décodé" if psbt_inputs.empty?

    expected_fps = [@vault.ledger_a_fp, @vault.ledger_b_fp].map { |x| x.to_s.downcase }.uniq
    base = expected_base_path.to_s

    psbt_inputs.each_with_index do |i, idx|
      raise "Input##{idx}: witness_utxo manquant"   if i["witness_utxo"].blank?
      raise "Input##{idx}: witness_script manquant" if i["witness_script"].blank?
      raise "Input##{idx}: bip32_derivs manquant"   if i["bip32_derivs"].blank?

      # fingerprints présents
      fps = (i["bip32_derivs"] || []).map { |d| d["master_fingerprint"].to_s.downcase }.uniq
      missing = expected_fps - fps
      raise "Input##{idx}: mauvais fingerprints. expected=#{expected_fps.inspect} got=#{fps.inspect} missing=#{missing.inspect}" if missing.any?

      # paths BIP48 cohérents
      (i["bip32_derivs"] || []).each do |d|
        p = d["path"].to_s
        # Tolère h ou ' selon
