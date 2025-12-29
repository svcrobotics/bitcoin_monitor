# app/services/psbt_tools.rb
require "base64"
require "stringio"

class PsbtTools
  PSBT_MAGIC = "psbt\xff".b

  class Error < StandardError; end

  # ----------------------------
  # Public API
  # ----------------------------

  # Injecte PSBT_IN_WITNESS_SCRIPT (0x05) sur tous les inputs (si absent)
  def self.inject_witness_script(psbt_base64, witness_script_hex)
    raise Error, "PSBT vide" if psbt_base64.to_s.strip.empty?
    raise Error, "witness_script_hex manquant" if witness_script_hex.to_s.strip.empty?

    ws = [witness_script_hex.to_s.strip].pack("H*").b

    psbt = parse_psbt(psbt_base64)

    witness_key = "\x05".b # PSBT_IN_WITNESS_SCRIPT (keydata empty)
    psbt[:inputs].each do |imap|
      imap << [witness_key, ws] unless imap.any? { |(k, _)| k == witness_key }
    end

    build_psbt(psbt)
  end

  # Injecte PSBT_IN_BIP32_DERIVATION (0x06 + pubkey) sur tous les inputs
  #
  # Format PSBT:
  #   key   = 0x06 || pubkey(33 bytes)
  #   value = master_fingerprint(4 bytes) || path(uint32le...)
  #
  def self.inject_bip32_derivs(psbt_base64, pubkeys:, fingerprints:, derivation_path:, derivation_index:)
    raise Error, "PSBT vide" if psbt_base64.to_s.strip.empty?

    a_fp_hex = fingerprints.fetch(:a).to_s.downcase
    b_fp_hex = fingerprints.fetch(:b).to_s.downcase
    a_pk_hex = pubkeys.fetch(:a).to_s.downcase
    b_pk_hex = pubkeys.fetch(:b).to_s.downcase

    unless a_fp_hex.match?(/\A[0-9a-f]{8}\z/) && b_fp_hex.match?(/\A[0-9a-f]{8}\z/)
      raise Error, "Fingerprints invalides: a=#{a_fp_hex.inspect} b=#{b_fp_hex.inspect} (attendu 8 hex)"
    end

    # pubkey hex 33 bytes compressé => 66 hex chars
    unless a_pk_hex.match?(/\A[0-9a-f]{66}\z/) && b_pk_hex.match?(/\A[0-9a-f]{66}\z/)
      raise Error, "Pubkeys invalides (attendu pubkey compressée hex 66): a=#{a_pk_hex[0,10]}.. b=#{b_pk_hex[0,10]}.."
    end

    a_fp = [a_fp_hex].pack("H*").b
    b_fp = [b_fp_hex].pack("H*").b
    a_pk = [a_pk_hex].pack("H*").b
    b_pk = [b_pk_hex].pack("H*").b

    base = derivation_path.to_s
    base = "m/#{base}" unless base.start_with?("m/")
    full_path = "#{base}/0/#{derivation_index.to_i}"
    path_bin  = pack_bip32_path(full_path)

    psbt = parse_psbt(psbt_base64)

    # Key type 0x06 + pubkey
    key_a = "\x06".b + a_pk
    key_b = "\x06".b + b_pk

    val_a = a_fp + path_bin
    val_b = b_fp + path_bin

    psbt[:inputs].each do |imap|
      # On supprime si déjà présent (pour forcer les bons fingerprints / paths)
      imap.reject! { |(k, _)| k == key_a || k == key_b }

      imap << [key_a, val_a]
      imap << [key_b, val_b]
    end

    build_psbt(psbt)
  end

  # ----------------------------
  # Internal PSBT parsing/build
  # ----------------------------

  def self.parse_psbt(psbt_base64)
    raw = Base64.decode64(psbt_base64.to_s).b
    raise Error, "PSBT invalide (magic)" unless raw.start_with?(PSBT_MAGIC)

    io = StringIO.new(raw)
    io.read(5) # magic

    global_pairs = read_kv_map(io)

    unsigned_tx = global_pairs.find { |(k, _)| k.getbyte(0) == 0x00 }&.last
    raise Error, "PSBT sans unsigned tx" if unsigned_tx.nil?

    vin_n, vout_n = count_vin_vout_from_unsigned_tx(unsigned_tx)

    inputs  = Array.new(vin_n)  { read_kv_map(io) }
    outputs = Array.new(vout_n) { read_kv_map(io) }

    { global: global_pairs, inputs: inputs, outputs: outputs }
  end
  private_class_method :parse_psbt

  def self.build_psbt(psbt_hash)
    out = +"".b
    out << PSBT_MAGIC
    out << write_kv_map(psbt_hash[:global])
    psbt_hash[:inputs].each  { |pairs| out << write_kv_map(pairs) }
    psbt_hash[:outputs].each { |pairs| out << write_kv_map(pairs) }
    Base64.strict_encode64(out)
  end
  private_class_method :build_psbt

  # kv map = array de pairs [key, val], terminée par klen=0
  def self.read_kv_map(io)
    pairs = []
    loop do
      klen = read_varint(io)
      break if klen == 0
      key  = io.read(klen).b
      vlen = read_varint(io)
      val  = io.read(vlen).b
      pairs << [key, val]
    end
    pairs
  end
  private_class_method :read_kv_map

  def self.write_kv_map(pairs)
    out = +"".b
    pairs.each do |(k, v)|
      k = k.b
      v = v.b
      out << write_varint(k.bytesize) << k
      out << write_varint(v.bytesize) << v
    end
    out << "\x00".b
    out
  end
  private_class_method :write_kv_map

  def self.read_varint(io)
    ch = io.read(1)
    raise Error, "EOF varint" if ch.nil?
    v = ch.getbyte(0)
    if v < 0xfd
      v
    elsif v == 0xfd
      io.read(2).unpack1("v")
    elsif v == 0xfe
      io.read(4).unpack1("V")
    else
      io.read(8).unpack1("Q<")
    end
  end
  private_class_method :read_varint

  def self.write_varint(n)
    if n < 0xfd
      [n].pack("C").b
    elsif n <= 0xffff
      [0xfd, n].pack("Cv").b
    elsif n <= 0xffffffff
      [0xfe, n].pack("CV").b
    else
      [0xff, n].pack("CQ<").b
    end
  end
  private_class_method :write_varint

  # Compte vin/vout depuis la TX unsigned (non-segwit, car unsigned tx en PSBT)
  def self.count_vin_vout_from_unsigned_tx(unsigned_tx)
    tx_io = StringIO.new(unsigned_tx.b)
    tx_io.read(4) # version

    vin_n = read_varint(tx_io)
    vin_n.times do
      tx_io.read(32) # prev txid
      tx_io.read(4)  # vout
      script_len = read_varint(tx_io)
      tx_io.read(script_len)
      tx_io.read(4)  # sequence
    end

    vout_n = read_varint(tx_io)
    vout_n.times do
      tx_io.read(8) # value
      spk_len = read_varint(tx_io)
      tx_io.read(spk_len)
    end

    [vin_n, vout_n]
  end
  private_class_method :count_vin_vout_from_unsigned_tx

  # Encode "m/84'/0'/0'/0/12" => binary path (uint32 LE * n)
  def self.pack_bip32_path(path)
    p = path.to_s.strip
    p = p.delete_prefix("m/")
    parts = p.split("/")

    parts.map do |seg|
      hardened = seg.end_with?("'") || seg.end_with?("h") || seg.end_with?("H")
      n = seg.gsub(/['hH]/, "").to_i
      n |= 0x8000_0000 if hardened
      [n].pack("V").b
    end.join
  end
  private_class_method :pack_bip32_path
end
