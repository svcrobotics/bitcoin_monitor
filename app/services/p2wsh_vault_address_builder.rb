# app/services/p2wsh_vault_address_builder.rb
require "digest"
require "bech32"

class P2wshVaultAddressBuilder
  # Builder A+B uniquement (P2WSH multisig standard 2-of-2)
  #
  # witnessScript:
  #   2 <pub1> <pub2> 2 OP_CHECKMULTISIG
  #
  def initialize(vault)
    @vault = vault
  end

  def build!
    pub_a = @vault.pubkey_a_child.presence || @vault.pubkey_a
    pub_b = @vault.pubkey_b_child.presence || @vault.pubkey_b

    raise "pubkey_a manquante" if pub_a.blank?
    raise "pubkey_b manquante" if pub_b.blank?

    pub_a = pub_a.to_s.strip.downcase
    pub_b = pub_b.to_s.strip.downcase

    validate_pubkey!(pub_a, "A")
    validate_pubkey!(pub_b, "B")

    # Ordre stable (BIP67-like) : IMPORTANT => le script dépend de cet ordre
    pub1, pub2 = [pub_a, pub_b].sort

    witness_script_bin = build_2of2_multisig_witness_script(pub1, pub2) # binaire
    witness_script_hex = witness_script_bin.unpack1("H*")

    script_hash = Digest::SHA256.digest(witness_script_bin)

    hrp     = human_readable_part(@vault.network)
    witprog = convert_bits(script_hash.bytes, 8, 5, true)
    data    = [0] + witprog # v0

    address = Bech32.encode(hrp, data, :bech32)

    # ✅ Champs existants dans ton modèle:
    # - redeem_script_hex (nom historique, contient en réalité le witness_script hex)
    # - witness_script (tu l'as dans ton modèle; on y met aussi le hex pour debug)
    @vault.update!(
      address:           address,
      redeem_script_hex: witness_script_hex,
      witness_script:    witness_script_hex
    )

    address
  end

  private

  def validate_pubkey!(hex, label)
    unless hex.match?(/\A(02|03)[0-9a-f]{64}\z/)
      raise "pubkey #{label} invalide (compressed 33 bytes) : #{hex.inspect}"
    end
  end

  def build_2of2_multisig_witness_script(pubkey1_hex, pubkey2_hex)
    pk1 = [pubkey1_hex].pack("H*").b
    pk2 = [pubkey2_hex].pack("H*").b

    script = +"".b
    script << op_int(2)
    script << push_data(pk1)
    script << push_data(pk2)
    script << op_int(2)
    script << op(:checkmultisig)
    script
  end

  def human_readable_part(network)
    case network.to_s
    when "mainnet", "", nil
      "bc"
    when "testnet", "signet"
      "tb"
    when "regtest"
      "bcrt"
    else
      "tb"
    end
  end

  OP_CODES = { checkmultisig: 0xAE }.freeze

  def op(name)
    [OP_CODES.fetch(name)].pack("C").b
  end

  def op_int(n)
    raise "int out of range 1..16" unless (1..16).include?(n)
    [0x50 + n].pack("C").b
  end

  def push_data(bytes)
    size = bytes.bytesize
    raise "data too long for simple PUSHDATA" if size > 75
    [size].pack("C").b + bytes
  end

  def convert_bits(data, from_bits, to_bits, pad = true)
    acc = 0
    bits = 0
    ret  = []
    maxv = (1 << to_bits) - 1

    data.each do |value|
      acc  = (acc << from_bits) | value
      bits += from_bits
      while bits >= to_bits
        bits -= to_bits
        ret << ((acc >> bits) & maxv)
      end
    end

    ret << ((acc << (to_bits - bits)) & maxv) if pad && bits > 0
    ret
  end
end
