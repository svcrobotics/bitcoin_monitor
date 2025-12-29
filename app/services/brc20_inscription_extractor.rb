# app/services/brc20_inscription_extractor.rb
class Brc20InscriptionExtractor
  def initialize(rpc:)
    @rpc = rpc
  end

  # Retourne un Array de hashes :
  # [
  #   {
  #     "inscription_id" => "txid:vin_index:witness_index",
  #     "address"        => "bc1q....",   # adresse réelle devinée depuis les vout
  #     "content"        => "{ ...json brc-20... }"
  #   },
  #   ...
  # ]
  def for_tx(tx)
    results = []

    # 🔍 On essaie de récupérer une vraie adresse de sortie pour cette tx
    guessed_address = first_output_address(tx)

    vins = tx["vin"] || []
    vins.each_with_index do |vin, vin_idx|
      witnesses = vin["txinwitness"] || []
      witnesses.each_with_index do |whex, wit_idx|
        json = extract_brc20_json_from_witness(whex)
        next unless json

        raw_tick = json["tick"] || json["symbol"] || json["ticker"]
        tick     = safe_utf8_strip(raw_tick).downcase
        next if tick.empty?

        op = safe_utf8_strip(json["op"]).downcase
        next unless %w[deploy mint transfer].include?(op)

        inscription_id = "#{tx["txid"]}:#{vin_idx}:#{wit_idx}"

        results << {
          "inscription_id" => inscription_id,
          "address"        => guessed_address,   # ✅ on met une vraie adresse si possible
          "content"        => json.to_json
        }
      end
    end

    results
  end

  private

  # =========================
  # Helpers de sécurité UTF-8
  # =========================

  # Force UTF-8 et strip sans exploser sur des octets invalides
  def safe_utf8_strip(raw)
    return "" if raw.nil?

    str = raw.to_s.dup
    str.force_encoding(Encoding::UTF_8)

    # Remplace les séquences invalides / indéfinies par rien (ou "�" si tu préfères)
    str = str.encode(
      Encoding::UTF_8,
      invalid: :replace,
      undef: :replace,
      replace: ""
    )

    str.strip
  end

  # Essaie de trouver une adresse standard dans les sorties de la tx
  def first_output_address(tx)
    vouts = tx["vout"] || []
    vouts.each do |vout|
      spk = vout["scriptPubKey"] || {}

      # Selon la version de bitcoind, on peut avoir "addresses" ou "address"
      addr =
        if spk["addresses"].is_a?(Array)
          spk["addresses"].first
        else
          spk["address"]
        end

      return addr if addr.present?
    end

    nil
  end

  # Extraction robuste du JSON BRC-20 depuis le witness
  def extract_brc20_json_from_witness(whex)
    # hex -> binaire
    data = [whex].pack("H*")

    # On force en UTF-8 "tolérant" AVANT de chercher le JSON
    utf8 = data.dup
    utf8.force_encoding(Encoding::UTF_8)
    utf8 = utf8.encode(
      Encoding::UTF_8,
      invalid: :replace,
      undef: :replace,
      replace: ""
    )

    idx = utf8.index('"p":"brc-20"')
    return nil unless idx

    start_idx = utf8.rindex("{", idx) || 0
    end_idx   = utf8.index("}", idx) || (utf8.length - 1)
    json_str  = utf8[start_idx..end_idx]

    json = JSON.parse(json_str) rescue nil
    return nil unless json.is_a?(Hash)
    return nil unless safe_utf8_strip(json["p"]).downcase == "brc-20"

    json
  rescue StandardError => e
    Rails.logger.debug(
      "[Brc20InscriptionExtractor] Witness parse error: #{e.class} - #{e.message}"
    )
    nil
  end
end
