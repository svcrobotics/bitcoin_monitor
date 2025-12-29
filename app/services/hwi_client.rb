# app/services/hwi_client.rb
require "open3"
require "json"
require "base64"

class HwiClient
  class Error < StandardError; end

  def self.enumerate(chain: "main")
    stdout, stderr, st = Open3.capture3("hwi", "--chain", chain.to_s, "enumerate")
    raise Error, "HWI enumerate failed: #{stderr.presence || stdout}" unless st.success?
    JSON.parse(stdout)
  rescue JSON::ParserError => e
    raise Error, "HWI enumerate returned non-JSON: #{e.message} / stdout=#{stdout.to_s[0,200].inspect}"
  end

  def initialize(fingerprint: nil, device_path: nil, chain: "main", logger: Rails.logger)
    @fingerprint = fingerprint&.to_s&.downcase
    @device_path = device_path&.to_s
    @chain       = chain.to_s
    @logger      = logger
  end

  def get_xpub(path)
    out = run_json!("getxpub", path.to_s)
    out.fetch("xpub")
  end

  # Signe une PSBT avec le device ciblé (fingerprint ou device_path).
  # - normalise base64
  # - vérifie magic bytes
  # - tente signpsbt puis signtx (fallback)
  # - valide que la PSBT a changé (ou que analyzepsbt progresse)
  def sign_psbt(psbt_input)
    psbt = normalize_psbt(psbt_input)
    assert_psbt_magic!(psbt)

    rpc = BitcoinRpc.new

    before_decoded = rpc.decodepsbt(psbt)
    before_analyze = safe_analyze(rpc, psbt)

    signed =
      begin
        out = run_json!("signpsbt", psbt)
        extract_psbt(out)
      rescue Error => e
        @logger&.warn("[HwiClient] signpsbt failed, fallback to signtx: #{e.message}")
        out = run_json!("signtx", psbt)
        extract_psbt(out)
      end

    signed = normalize_psbt(signed)
    assert_psbt_magic!(signed)

    # 1) Si la PSBT est strictement identique -> clairement pas signé
    if signed == psbt
      raise Error, "Ledger n'a pas modifié la PSBT (identique). Vérifie que tu as branché le bon Ledger et que l'app Bitcoin est ouverte."
    end

    # 2) Sinon, on check qu'on a avancé (analyzepsbt)
    after_analyze = safe_analyze(rpc, signed)
    if before_analyze && after_analyze
      # si "next" reste identique et missing identique -> suspect
      if before_analyze == after_analyze
        @logger&.warn("[HwiClient] PSBT changed but analyzepsbt unchanged; continuing (may still be ok).")
      end
    end

    signed
  end

  private

  def extract_psbt(out)
    s = out["psbt"] || out["signed_psbt"] || out["result"] || out["raw"]
    raise Error, "HWI n'a pas renvoyé de PSBT signée: #{out.inspect}" if s.blank?
    s
  end

  def safe_analyze(rpc, psbt)
    rpc.analyzepsbt(psbt)
  rescue
    nil
  end

  # --- Normalisation ---
  def normalize_psbt(input)
    s = input.to_s.strip
    s = s.gsub(/\r?\n/, "")
    s = s.gsub(/\s+/, "")

    if s.start_with?("{") && s.end_with?("}")
      begin
        h = JSON.parse(s)
        s = (h["psbt"] || h["signed_psbt"] || h["result"] || h["raw"] || "").to_s.strip
        s = s.gsub(/\r?\n/, "").gsub(/\s+/, "")
      rescue JSON::ParserError
        # ignore
      end
    end

    raise Error, "PSBT vide" if s.empty?
    s
  end

  # Magic bytes d’une PSBT: "psbt\xff"
  def assert_psbt_magic!(psbt_b64)
    raw = Base64.decode64(psbt_b64)
    magic = raw.bytes.first(5)
    ok = (magic == [0x70, 0x73, 0x62, 0x74, 0xff])
    raise Error, "PSBT invalide (invalid magic) : magic != psbt\\xff" unless ok
    true
  rescue ArgumentError => e
    raise Error, "PSBT invalide (base64): #{e.message}"
  end

  # --- Runner HWI ---
  def run_json!(command, *args)
    cmd = ["hwi", "--chain", @chain]
    cmd += ["--device-path", @device_path] if @device_path.present?
    cmd += ["--fingerprint", @fingerprint] if @device_path.blank? && @fingerprint.present?
    cmd += [command, *args.map(&:to_s)]

    stdout, stderr, status = Open3.capture3(*cmd)
    stdout_s = stdout.to_s.strip
    stderr_s = stderr.to_s.strip

    parsed =
      begin
        JSON.parse(stdout_s)
      rescue JSON::ParserError
        nil
      end

    if parsed.is_a?(Hash) && parsed["error"].present?
      raise Error, "HWI error: #{parsed.inspect}"
    end

    unless status.success?
      raise Error, "HWI failed: #{stderr_s.presence || stdout_s.presence || "(empty)"}"
    end

    parsed.is_a?(Hash) ? parsed : { "raw" => stdout_s }
  end
end
