# frozen_string_literal: true

require "bigdecimal"

module Layer1
  class AuditBlockInputs
    def self.call(height:)
      new(height: height).call
    end

    def initialize(height:)
      @height = height.to_i
      @issues = []
      @warnings = []
      @checks = {}
    end

    def call
      block_buffer = BlockBufferModel.find_by(height: @height)
      raise "BlockBufferModel missing for height #{@height}" unless block_buffer

      block = BitcoinRpc.new.getblock(block_buffer.block_hash, 3)

      all_node_inputs = extract_node_inputs(block)

      node_inputs =
        all_node_inputs.select do |input|
          input[:address].present?
        end

      unclusterable_node_inputs =
        all_node_inputs.reject do |input|
          input[:address].present?
        end

      db_inputs = ClusterInput.where(spent_block_height: @height)

      node_inputs_count = node_inputs.size
      db_inputs_count = db_inputs.count

      node_inputs_value =
        node_inputs.sum(BigDecimal("0")) do |input|
          BigDecimal(input[:amount_btc].to_s)
        end

      db_inputs_value = BigDecimal(db_inputs.sum(:amount_btc).to_s)

      check!(
        "cluster_inputs_count_matches",
        db_inputs_count == node_inputs_count,
        bitcoin_core: node_inputs_count,
        postgresql: db_inputs_count
      )

      check!(
        "cluster_inputs_value_matches",
        db_inputs_value == node_inputs_value,
        bitcoin_core: "#{btc_s(node_inputs_value)} BTC",
        postgresql: "#{btc_s(db_inputs_value)} BTC"
      )

      missing_address_count = db_inputs.where(address: [nil, ""]).count

      address_coverage_percent =
        if db_inputs_count.zero?
          100.0
        else
          (((db_inputs_count - missing_address_count).to_f / db_inputs_count) * 100).round(4)
        end

      warning!(
        "cluster_inputs_have_addresses",
        missing_address_count.zero?,
        bitcoin_core: "some Bitcoin scripts may not expose a standard address",
        postgresql: missing_address_count,
        coverage_percent: address_coverage_percent
      )

      {
        ok: @issues.empty?,
        height: @height,
        block_hash: block_buffer.block_hash,
        all_node_inputs_count: all_node_inputs.size,
        unclusterable_node_inputs_count: unclusterable_node_inputs.size,
        node_inputs_count: node_inputs_count,
        db_inputs_count: db_inputs_count,
        node_inputs_value_btc: btc_s(node_inputs_value),
        db_inputs_value_btc: btc_s(db_inputs_value),
        missing_address_count: missing_address_count,
        address_coverage_percent: address_coverage_percent,
        checks: @checks,
        warnings: @warnings,
        issues: @issues
      }
    end

    private

    def extract_node_inputs(block)
      rows = []

      block.fetch("tx").each do |tx|
        tx.fetch("vin", []).each do |vin|
          next if vin["coinbase"].present?

          prevout = vin["prevout"]

          unless prevout
            @issues << {
              check: "bitcoin_core_prevout_missing",
              txid: tx["txid"],
              prev_txid: vin["txid"],
              prev_vout: vin["vout"]
            }

            next
          end

          rows << {
            spent_txid: tx["txid"],
            txid: vin["txid"],
            vout: vin["vout"],
            amount_btc: prevout["value"],
            address: extract_address(prevout),
            prevout_height: prevout["height"]
          }
        end
      end

      rows
    end

    def extract_address(prevout)
      script = prevout["scriptPubKey"] || {}

      return script["address"] if script["address"].present?
      return script["addresses"].first if script["addresses"].present?

      nil
    end

    def btc_s(value)
      BigDecimal(value.to_s).to_s("F")
    end

    def check!(name, passed, bitcoin_core:, postgresql:)
      @checks[name] = {
        passed: passed,
        severity: "error",
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

    def warning!(name, passed, bitcoin_core:, postgresql:, coverage_percent:)
      @checks[name] = {
        passed: passed,
        severity: "warning",
        bitcoin_core: bitcoin_core,
        postgresql: postgresql,
        coverage_percent: coverage_percent
      }

      return if passed

      @warnings << {
        check: name,
        bitcoin_core: bitcoin_core,
        postgresql: postgresql,
        coverage_percent: coverage_percent
      }
    end
  end
end
