# app/services/derive_pubkey_runner.rb
require "open3"

class DerivePubkeyRunner
  BIN_PATH = Rails.root.join("..", "derive_pubkey", "target", "release", "derive_pubkey").to_s

  # debug: true => renvoie aussi stdin/stdout/stderr (masqués)
  def self.call(xpub_a, xpub_b, debug: false)
    raise "xpub_a manquant" if xpub_a.blank?
    raise "xpub_b manquant" if xpub_b.blank?
    raise "Binaire derive_pubkey introuvable: #{BIN_PATH}" unless File.exist?(BIN_PATH)

    stdin_data = "#{xpub_a}\n#{xpub_b}\n"
    stdout, stderr, status = Open3.capture3(BIN_PATH, stdin_data: stdin_data)

    unless status.success?
      # En debug, on garde un payload masqué pour diagnostiquer
      if debug
        raise build_error(
          "derive_pubkey a échoué",
          status: status,
          stdin_data: stdin_data,
          stdout: stdout,
          stderr: stderr
        )
      end

      raise "derive_pubkey a échoué (status=#{status.exitstatus}) : #{stderr.presence || stdout}"
    end

    result = parse(stdout)

    payload = {
      pubkey_a:  result[:pubkey_a],
      address_a: result[:address_a],
      pubkey_b:  result[:pubkey_b],
      address_b: result[:address_b]
    }

    validate_payload!(payload, stdout)

    if debug
      payload[:_debug] = {
        bin: BIN_PATH,
        exitstatus: status.exitstatus,
        stdin_preview: mask_xpubs(stdin_data),
        stdout_preview: mask_xpubs(stdout),
        stderr_preview: mask_xpubs(stderr)
      }
    end

    payload
  end

  # ---- internal helpers ----
  def self.parse(stdout)
    lines = stdout.to_s.lines.map(&:strip)

    {
      pubkey_a:  lines.find { |l| l.start_with?("PUBKEY_A=") }&.split("=", 2)&.last,
      address_a: lines.find { |l| l.start_with?("ADRESSE_A=") }&.split("=", 2)&.last,
      pubkey_b:  lines.find { |l| l.start_with?("PUBKEY_B=") }&.split("=", 2)&.last,
      address_b: lines.find { |l| l.start_with?("ADRESSE_B=") }&.split("=", 2)&.last
    }
  end
  private_class_method :parse

  def self.validate_payload!(payload, stdout)
    if payload.values.any?(&:blank?)
      raise "Impossible d'extraire PUBKEY_/ADRESSE_ depuis derive_pubkey. stdout=\n#{stdout}"
    end

    # Pubkeys compressed: 02/03 + 64 hex = 66 chars
    [:pubkey_a, :pubkey_b].each do |k|
      pk = payload[k].to_s.downcase
      unless pk.match?(/\A(02|03)[0-9a-f]{64}\z/)
        raise "Pubkey invalide (#{k}) : #{payload[k]}"
      end
    end

    # Adresse : check minimal (tu peux renforcer selon mainnet/testnet)
    [:address_a, :address_b].each do |k|
      addr = payload[k].to_s
      unless addr.size >= 14 # règle grossière pour éviter vide/1 char
        raise "Adresse invalide (#{k}) : #{addr.inspect}"
      end
    end
  end
  private_class_method :validate_payload!

  # Evite d'afficher l'xpub complet en clair dans le debug UI/log
  def self.mask_xpubs(str)
    str.to_s.lines.map do |l|
      s = l.strip
      next "" if s.blank?
      if s.start_with?("xpub", "zpub", "tpub", "vpub")
        s[0, 12] + "…" + s[-8, 8].to_s
      else
        s
      end
    end.join("\n")
  end
  private_class_method :mask_xpubs

  def self.build_error(prefix, status:, stdin_data:, stdout:, stderr:)
    dbg = {
      bin: BIN_PATH,
      exitstatus: status.exitstatus,
      stdin_preview: mask_xpubs(stdin_data),
      stdout_preview: mask_xpubs(stdout),
      stderr_preview: mask_xpubs(stderr)
    }
    "#{prefix} (status=#{status.exitstatus}). debug=#{dbg.to_json}"
  end
  private_class_method :build_error
end
