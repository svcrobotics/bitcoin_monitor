# frozen_string_literal: true

require "bigdecimal"
require "active_support/core_ext/object/blank"

module AddressUtxoStats
  class BlockDeltaBuilder
    SATOSHIS_PER_BTC =
      BigDecimal("100000000")

    class AmountConversionError < StandardError; end

    SOURCE_PRIORITY = {
      utxo_outputs: 0,
      cluster_inputs_received: 1,
      cluster_inputs_spent: 2
    }.freeze

    def self.call(**attributes)
      new(**attributes).call
    end

    def self.btc_to_sats(value)
      raise AmountConversionError, "amount is missing" if value.nil?

      decimal =
        BigDecimal(value.to_s)

      sats =
        decimal * SATOSHIS_PER_BTC

      integer_sats =
        sats.to_i

      return integer_sats if
        sats == BigDecimal(integer_sats.to_s)

      raise(
        AmountConversionError,
        "amount has more than 8 decimal places"
      )
    rescue ArgumentError
      raise(
        AmountConversionError,
        "amount is not decimal"
      )
    end

    def initialize(
      height:,
      block_hash: nil,
      utxo_outputs: nil,
      cluster_inputs: nil
    )
      @height =
        Integer(height)

      @block_hash =
        block_hash

      @utxo_outputs_source =
        utxo_outputs

      @cluster_inputs_source =
        cluster_inputs

      @anomalies = []
    end

    def call
      received_outputs =
        deduplicate_outputs(
          received_output_candidates,
          event: :received
        )

      spent_outputs =
        deduplicate_outputs(
          spent_output_candidates,
          event: :spent
        )

      deltas =
        aggregate_deltas(
          received_outputs: received_outputs,
          spent_outputs: spent_outputs
        )

      result =
        result_payload(
          received_outputs: received_outputs,
          spent_outputs: spent_outputs,
          deltas: deltas
        )

      verify_coherence!(result)

      result.merge(
        anomalies:
          sorted_anomalies
      )
    end

    private

    attr_reader(
      :height,
      :block_hash,
      :utxo_outputs_source,
      :cluster_inputs_source,
      :anomalies
    )

    def received_output_candidates
      live_received =
        rows_from(
          source:
            utxo_outputs_relation,
          filters: {
            block_height: height
          }
        ).map do |record|
          output_from_record(
            record,
            source: :utxo_outputs,
            event: :received
          )
        end

      spent_received =
        rows_from(
          source:
            cluster_inputs_relation,
          filters: {
            block_height: height,
            spent: true
          }
        ).map do |record|
          output_from_record(
            record,
            source: :cluster_inputs_received,
            event: :received
          )
        end

      (
        live_received +
        spent_received
      ).compact
    end

    def spent_output_candidates
      rows_from(
        source:
          cluster_inputs_relation,
        filters: {
          spent_block_height: height,
          spent: true
        }
      ).map do |record|
        output_from_record(
          record,
          source: :cluster_inputs_spent,
          event: :spent
        )
      end.compact
    end

    def rows_from(source:, filters:)
      if source.respond_to?(:where)
        relation = source

        filters.each do |column, value|
          relation =
            relation.where(
              column => value
            )
        end

        return relation.to_a
      end

      Array(source).select do |record|
        filters.all? do |column, value|
          record_value(record, column) == value
        end
      end
    end

    def output_from_record(record, source:, event:)
      txid =
        normalized_string(
          record_value(record, :txid)
        )

      vout =
        integer_value(
          record_value(record, :vout)
        )

      address =
        normalized_string(
          record_value(record, :address)
        )

      amount =
        record_value(
          record,
          :amount_btc
        )

      creation_height =
        integer_value(
          record_value(record, :block_height)
        )

      event_height =
        if event == :spent
          integer_value(
            record_value(
              record,
              :spent_block_height
            )
          )
        else
          creation_height
        end

      missing =
        missing_fields(
          txid: txid,
          vout: vout,
          address: address,
          amount: amount,
          creation_height: creation_height,
          event_height: event_height
        )

      if missing.any?
        add_anomaly(
          type: :missing_essential_data,
          source: source,
          event: event,
          key: [txid, vout],
          fields: missing
        )

        return nil
      end

      sats =
        self.class.btc_to_sats(
          amount
        )

      {
        key:
          [txid, vout],
        txid:
          txid,
        vout:
          vout,
        address:
          address,
        sats:
          sats,
        creation_height:
          creation_height,
        event_height:
          event_height,
        source:
          source,
        event:
          event
      }
    rescue AmountConversionError => error
      add_anomaly(
        type: :invalid_amount,
        source: source,
        event: event,
        key: [
          record_value(record, :txid),
          record_value(record, :vout)
        ],
        message: error.message
      )

      nil
    end

    def deduplicate_outputs(outputs, event:)
      outputs
        .group_by do |output|
          output.fetch(:key)
        end
        .sort_by do |key, _group|
          key
        end
        .filter_map do |key, group|
          inspect_duplicate_group(
            key: key,
            group: group,
            event: event
          )

          canonical_output(
            group
          )
        end
    end

    def inspect_duplicate_group(key:, group:, event:)
      return if group.one?

      grouped_by_source =
        group.group_by do |output|
          output.fetch(:source)
        end

      grouped_by_source.each do |source, records|
        next unless records.size > 1

        add_anomaly(
          type: :duplicate_output,
          source: source,
          event: event,
          key: key,
          count: records.size
        )
      end

      if event == :received &&
         grouped_by_source.key?(:utxo_outputs) &&
         grouped_by_source.key?(:cluster_inputs_received)
        add_anomaly(
          type: :output_overlap,
          event: event,
          key: key,
          sources:
            grouped_by_source.keys.sort
        )
      end

      contradictory_fields =
        %i[
          address
          sats
          creation_height
        ].select do |field|
          group
            .map { |output| output.fetch(field) }
            .uniq
            .size > 1
        end

      return if contradictory_fields.empty?

      add_anomaly(
        type: :output_contradiction,
        event: event,
        key: key,
        fields: contradictory_fields
      )
    end

    def canonical_output(group)
      group
        .sort_by do |output|
          [
            SOURCE_PRIORITY.fetch(
              output.fetch(:source)
            ),
            output.fetch(:txid),
            output.fetch(:vout),
            output.fetch(:address),
            output.fetch(:sats)
          ]
        end
        .first
    end

    def aggregate_deltas(
      received_outputs:,
      spent_outputs:
    )
      deltas =
        Hash.new do |hash, address|
          hash[address] =
            empty_delta(address)
        end

      received_outputs.each do |output|
        delta =
          deltas[
            output.fetch(:address)
          ]

        sats =
          output.fetch(:sats)

        delta[:received_sats_delta] += sats
        delta[:balance_sats_delta] += sats
        delta[:live_utxo_count_delta] += 1
        delta[:received_output_count_delta] += 1
        delta[:first_received_height_candidate] =
          min_height(
            delta[:first_received_height_candidate],
            output.fetch(:creation_height)
          )
        delta[:last_received_height_candidate] =
          max_height(
            delta[:last_received_height_candidate],
            output.fetch(:creation_height)
          )
      end

      spent_outputs.each do |output|
        delta =
          deltas[
            output.fetch(:address)
          ]

        sats =
          output.fetch(:sats)

        delta[:spent_sats_delta] += sats
        delta[:balance_sats_delta] -= sats
        delta[:live_utxo_count_delta] -= 1
      end

      deltas
        .values
        .sort_by do |delta|
          delta.fetch(:address)
        end
    end

    def result_payload(
      received_outputs:,
      spent_outputs:,
      deltas:
    )
      total_received_sats =
        received_outputs.sum do |output|
          output.fetch(:sats)
        end

      total_spent_sats =
        spent_outputs.sum do |output|
          output.fetch(:sats)
        end

      {
        height:
          height,
        block_hash:
          block_hash,
        addresses_touched:
          deltas.size,
        received_output_count:
          received_outputs.size,
        spent_output_count:
          spent_outputs.size,
        received_address_count:
          received_outputs
            .map { |output| output.fetch(:address) }
            .uniq
            .size,
        spent_address_count:
          spent_outputs
            .map { |output| output.fetch(:address) }
            .uniq
            .size,
        total_received_sats:
          total_received_sats,
        total_spent_sats:
          total_spent_sats,
        balance_delta_sats:
          total_received_sats - total_spent_sats,
        deltas:
          deltas,
        anomalies:
          []
      }
    end

    def verify_coherence!(result)
      received_sum =
        result
          .fetch(:deltas)
          .sum do |delta|
            delta.fetch(:received_sats_delta)
          end

      unless received_sum ==
             result.fetch(:total_received_sats)
        add_anomaly(
          type: :coherence_mismatch,
          field: :total_received_sats,
          expected: received_sum,
          actual: result.fetch(:total_received_sats)
        )
      end

      balance_sum =
        result
          .fetch(:deltas)
          .sum do |delta|
            delta.fetch(:balance_sats_delta)
          end

      unless balance_sum ==
             result.fetch(:balance_delta_sats)
        add_anomaly(
          type: :coherence_mismatch,
          field: :balance_delta_sats,
          expected: balance_sum,
          actual: result.fetch(:balance_delta_sats)
        )
      end

      spent_sum =
        result
          .fetch(:deltas)
          .sum do |delta|
            delta.fetch(:spent_sats_delta)
          end

      return if spent_sum ==
                result.fetch(:total_spent_sats)

      add_anomaly(
        type: :coherence_mismatch,
        field: :total_spent_sats,
        expected: spent_sum,
        actual: result.fetch(:total_spent_sats)
      )
    end

    def empty_delta(address)
      {
        address:
          address,
        received_sats_delta:
          0,
        spent_sats_delta:
          0,
        balance_sats_delta:
          0,
        live_utxo_count_delta:
          0,
        received_output_count_delta:
          0,
        first_received_height_candidate:
          nil,
        last_received_height_candidate:
          nil,
        last_changed_height:
          height
      }
    end

    def missing_fields(
      txid:,
      vout:,
      address:,
      amount:,
      creation_height:,
      event_height:
    )
      fields = []

      fields << :txid if txid.blank?
      fields << :vout if vout.nil?
      fields << :address if address.blank?
      fields << :amount_btc if amount.nil?
      fields << :block_height if creation_height.nil?
      fields << :event_height if event_height.nil?

      fields
    end

    def record_value(record, key)
      if record.respond_to?(:[])
        record[key] ||
          record[key.to_s]
      else
        record.public_send(key)
      end
    end

    def normalized_string(value)
      value
        &.to_s
        &.strip
    end

    def integer_value(value)
      return nil if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def min_height(current, candidate)
      return candidate if current.nil?

      [
        current,
        candidate
      ].min
    end

    def max_height(current, candidate)
      return candidate if current.nil?

      [
        current,
        candidate
      ].max
    end

    def add_anomaly(attributes)
      anomalies << attributes.compact
    end

    def sorted_anomalies
      anomalies.sort_by do |anomaly|
        [
          anomaly[:type].to_s,
          anomaly[:event].to_s,
          Array(anomaly[:key]).join(":"),
          anomaly[:source].to_s
        ]
      end
    end

    def utxo_outputs_relation
      utxo_outputs_source ||
        UtxoOutput.all
    end

    def cluster_inputs_relation
      cluster_inputs_source ||
        ClusterInput.all
    end
  end
end
