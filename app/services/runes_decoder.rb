class RunesDecoder
  def self.decode_tx(tx:, block_height:, block_time:, tx_index: 0)
    vout, vout_index = find_runestone_output(tx)
    return [] unless vout

    script_asm = vout.dig("scriptPubKey", "asm").to_s
    script_hex = vout.dig("scriptPubKey", "hex").to_s

    [{
      rune_name:       nil,
      rune_id_block:   block_height,
      rune_id_tx:      tx_index,
      op:              "unknown",
      amount:          0,
      from_address:    nil,
      to_address:      nil,
      vout:            vout_index,
      block_height:    block_height,
      block_time:      block_time,
      raw_payload: {
        "script_asm" => script_asm,
        "script_hex" => script_hex
      }
    }]
  end

  def self.find_runestone_output(tx)
    (tx["vout"] || []).each_with_index do |vout, idx|
      asm    = vout.dig("scriptPubKey", "asm").to_s
      tokens = asm.split(" ")
      next if tokens.empty?

      # 1er opcode : OP_RETURN obligatoire
      next unless tokens[0] == "OP_RETURN"

      # 2e "opcode" : chez toi c’est "13"
      second = tokens[1]
      if %w[13 OP_13 OP_PUSHNUM_13 0x0d].include?(second)
        return [vout, idx]
      end
    end

    [nil, nil]
  end
end
