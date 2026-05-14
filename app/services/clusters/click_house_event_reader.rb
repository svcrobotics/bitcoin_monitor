# frozen_string_literal: true

require "json"

module Clusters
  class ClickHouseEventReader
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 500

    def self.recent(limit: DEFAULT_LIMIT, q: nil, source: nil, severity: nil, signal_type: nil)
      new.recent(
        limit: limit,
        q: q,
        source: source,
        severity: severity,
        signal_type: signal_type
      )
    end

    def recent(limit: DEFAULT_LIMIT, q: nil, source: nil, severity: nil, signal_type: nil)
      safe_limit = [[limit.to_i, 1].max, MAX_LIMIT].min
      where_sql = build_where_sql(q: q, source: source, severity: severity, signal_type: signal_type)

      sql = <<~SQL
        SELECT
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
        FROM cluster_events
        #{where_sql}
        ORDER BY event_time DESC
        LIMIT #{safe_limit}
        FORMAT JSONEachRow
      SQL

      ClickHouse::Client
        .new
        .execute(sql)
        .lines
        .map { |line| JSON.parse(line) }
    end

    private

    def build_where_sql(q:, source:, severity:, signal_type:)
      clauses = []

      clauses << "source = '#{escape(source)}'" if source.present?
      clauses << "severity = '#{escape(severity)}'" if severity.present?
      clauses << "signal_type = '#{escape(signal_type)}'" if signal_type.present?

      if q.present?
        clean_q = escape(q.to_s.strip)

        if clean_q.match?(/\A\d+\z/)
          clauses << "(toString(cluster_id) = '#{clean_q}' OR toString(block_height) = '#{clean_q}')"
        else
          clauses << "positionCaseInsensitive(signal_type, '#{clean_q}') > 0"
        end
      end

      return "" if clauses.empty?

      "WHERE #{clauses.join(' AND ')}"
    end

    def escape(value)
      value.to_s.gsub("'", "''")
    end
  end
end