# frozen_string_literal: true

module Clusters
  class ClickHouseEventWriter
    def self.call(**args)
      new(**args).call
    end

    def initialize(
      cluster_id:,
      block_height:,
      signal_type:,
      severity:,
      score:,
      amount_btc: 0,
      tx_count: 0,
      address_count: 0,
      event_type: "cluster_signal",
      source: "rails"
    )
      @cluster_id = cluster_id
      @block_height = block_height
      @signal_type = signal_type
      @severity = severity
      @score = score
      @amount_btc = amount_btc
      @tx_count = tx_count
      @address_count = address_count
      @event_type = event_type
      @source = source
    end

    def call
      ClickHouse::Client.new.execute(insert_sql)
    end

    private

    attr_reader \
      :cluster_id,
      :block_height,
      :signal_type,
      :severity,
      :score,
      :amount_btc,
      :tx_count,
      :address_count,
      :event_type,
      :source

    def insert_sql
      <<~SQL
        INSERT INTO cluster_events
        (
          event_date,
          event_time,
          cluster_id,
          block_height,
          event_type,
          signal_type,
          severity,
          score,
          amount_btc,
          tx_count,
          address_count,
          source
        )
        VALUES
        (
          today(),
          now(),
          #{cluster_id.to_i},
          #{block_height.to_i},
          '#{escape(event_type)}',
          '#{escape(signal_type)}',
          '#{escape(severity)}',
          #{score.to_i},
          #{amount_btc.to_f},
          #{tx_count.to_i},
          #{address_count.to_i},
          '#{escape(source)}'
        )
      SQL
    end

    def escape(value)
      value.to_s.gsub("'", "''")
    end
  end
end
