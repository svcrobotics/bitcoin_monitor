# frozen_string_literal: true

require "json"
require "bigdecimal"
require "open3"

module Layer1
  class AuditBlock
    DEFAULT_DATADIR = "/var/lib/bitcoind"

    def self.call(height: nil)
      new(height: height).call
    end

    def initialize(height: nil)
      @height = height || BlockBufferModel.where(status: "processed").maximum(:height)
      @checks = {}
      @issues = []
    end

    def call
      run = Layer1AuditRun.create!(
        audited_height: @height,
        status: "running",
        started_at: Time.current,
        checks: {},
        issues: []
      )

      node_block_hash = bitcoin_cli("getblockhash", @height.to_s).strip
      node_block = JSON.parse(bitcoin_cli("getblock", node_block_hash, "2"))

      db_block = BlockBufferModel.find_by(height: @height)

      check!(
        "block_exists_in_db",
        db_block.present?,
        bitcoin_core: @height,
        postgresql: db_block&.height
      )

      if db_block.present?
        check!(
          "block_hash_matches",
          db_block.block_hash == node_block_hash,
          bitcoin_core: node_block_hash,
          postgresql: db_block.block_hash
        )

        check!(
          "tx_count_matches",
          db_block.tx_count.to_i == node_block["tx"].size,
          bitcoin_core: node_block["tx"].size,
          postgresql: db_block.tx_count.to_i
        )
      end

      node_outputs_count = node_block["tx"].sum { |tx| tx["vout"].size }
      db_outputs_count = UtxoOutput.where(block_height: @height).count

      check!(
        "outputs_count_matches",
        db_outputs_count == node_outputs_count,
        bitcoin_core: node_outputs_count,
        postgresql: db_outputs_count
      )

      node_outputs_value = node_block["tx"].sum do |tx|
        tx["vout"].sum { |vout| BigDecimal(vout["value"].to_s) }
      end

      db_outputs_value = BigDecimal(
        UtxoOutput.where(block_height: @height).sum(:amount_btc).to_s
      )

      check!(
        "outputs_value_matches",
        db_outputs_value == node_outputs_value,
        bitcoin_core: "#{node_outputs_value.to_s("F")} BTC",
        postgresql: "#{db_outputs_value.to_s("F")} BTC"
      )

      final_status = @issues.empty? ? "healthy" : "failed"

      run.update!(
        block_hash: node_block_hash,
        status: final_status,
        checks: @checks,
        issues: @issues,
        finished_at: Time.current
      )

      run
    rescue StandardError => e
      run&.update!(
        status: "error",
        issues: [{ class: e.class.name, message: e.message }],
        finished_at: Time.current
      )

      raise
    end

    private

    def bitcoin_cli(*args)
      datadir = ENV.fetch("BITCOIN_DATADIR", DEFAULT_DATADIR)

      command = ["bitcoin-cli", "-datadir=#{datadir}", *args]

      stdout, stderr, status = Open3.capture3(*command)

      unless status.success?
        raise "bitcoin-cli failed: #{stderr.presence || stdout}"
      end

      stdout
    end

    def check!(name, passed, bitcoin_core:, postgresql:)
      @checks[name] = {
        passed: passed,
        bitcoin_core: bitcoin_core,
        postgresql: postgresql
      }

      return if passed

      @issues << {
        check: name,
        bitcoin_core: bitcoin_core,
        postgresql: postgresql
      }
    end
  end
end