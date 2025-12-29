# app/services/psbt_sanity_checker.rb
class PsbtSanityChecker
  def self.check!(rpc:, psbt:)
    decoded = rpc.decodepsbt(psbt)
    inputs  = decoded.fetch("inputs", [])

    issues = []

    if inputs.empty?
      issues << "psbt: no inputs (builder bug or empty utxos?)"
    end

    sigs_per_input = inputs.map { |i| (i["partial_signatures"] || {}).size }

    inputs.each_with_index do |inp, idx|
      # 1) UTXO info : witness_utxo OR non_witness_utxo
      has_witness_utxo = inp["witness_utxo"].present?
      has_non_witness  = inp["non_witness_utxo"].present?

      unless has_witness_utxo || has_non_witness
        issues << "input##{idx}: missing witness_utxo/non_witness_utxo"
      end

      # 2) scriptPubKey context (surtout important si witness_utxo)
      if has_witness_utxo && inp.dig("witness_utxo", "scriptPubKey").blank?
        issues << "input##{idx}: witness_utxo present but scriptPubKey missing"
      end

      # 3) Derivations pour Ledger/HWI
      issues << "input##{idx}: missing bip32_derivs" if inp["bip32_derivs"].blank?

      # 4) P2WSH : witness_script attendu
      issues << "input##{idx}: missing witness_script (expected for P2WSH)" if inp["witness_script"].blank?
    end

    missing_sigs_inputs = sigs_per_input.each_with_index.select { |n, _i| n.to_i == 0 }.map(&:last)

    {
      ok: issues.empty?,
      issues: issues,
      inputs_count: inputs.size,
      sigs_per_input: sigs_per_input,
      sigs_total: sigs_per_input.sum,
      missing_sigs_inputs: missing_sigs_inputs,
      decoded_tx_vsize: decoded.dig("tx", "vsize") # utile si présent
    }
  end
end
