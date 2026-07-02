# frozen_string_literal: true

module Layer1
  module Realtime
    class RecentBlockCadenceSnapshot
    DEFAULT_COUNT = 5
    CACHE_VERSION = "v2"

    def self.call(
      tip_height:,
      processed_height:,
      processing_height: nil,
      count: DEFAULT_COUNT,
      rpc: BitcoinRpc.new,
      cache: Rails.cache,
      now: Time.current,
      certification_average_seconds: nil
    )
      new(
        tip_height: tip_height,
        processed_height: processed_height,
        processing_height: processing_height,
        count: count,
        rpc: rpc,
        cache: cache,
        now: now,
        certification_average_seconds: certification_average_seconds
      ).call
    end

    def initialize(
      tip_height:,
      processed_height:,
      processing_height:,
      count:,
      rpc:,
      cache:,
      now:,
      certification_average_seconds:
    )
      @tip_height = tip_height.to_i
      @processed_height = processed_height.to_i
      @processing_height = processing_height&.to_i
      @count = [count.to_i, 1].max
      @rpc = rpc
      @cache = cache
      @now = now
      @certification_average_seconds = certification_average_seconds
    end

    def call
      return unavailable("bitcoin_core_tip_missing") unless @tip_height.positive?

      headers = cached_headers
      return unavailable("block_headers_missing") if headers.size < 2

      blocks = build_blocks(headers)
      intervals = blocks.filter_map { |block| block[:interval_seconds] }
      average_interval_seconds = average(intervals)
      lag = [@tip_height - @processed_height, 0].max
      certification_average_seconds =
        @certification_average_seconds || recent_certification_average_seconds
      backlog_span_seconds = backlog_span(headers, lag)
      waiting_block = blocks.find { |block| block[:state] == "waiting" }
      processing_block = blocks.find { |block| block[:state] == "processing" }

      diagnosis = diagnosis(
        lag: lag,
        average_interval_seconds: average_interval_seconds,
        backlog_span_seconds: backlog_span_seconds,
        certification_average_seconds: certification_average_seconds,
        waiting_block: waiting_block,
        processing_block: processing_block
      )

      {
        available: true,
        tip_height: @tip_height,
        processed_height: @processed_height,
        processing_height: @processing_height,
        lag: lag,
        blocks: blocks,
        average_interval_seconds: average_interval_seconds,
        recent_span_seconds: recent_span(blocks),
        backlog_span_seconds: backlog_span_seconds,
        certification_average_seconds: certification_average_seconds,
        waiting_height: waiting_block&.dig(:height),
        waiting_age_seconds: waiting_block&.dig(:age_seconds),
        diagnosis: diagnosis[:code],
        diagnosis_label: diagnosis[:label],
        diagnosis_detail: diagnosis[:detail]
      }
    rescue StandardError => e
      Rails.logger.warn(
        "[recent_block_cadence_snapshot] error=#{e.class} message=#{e.message.inspect}"
      )

      unavailable("#{e.class}: #{e.message}")
    end

    private

    def cached_headers
      key = "layer1:recent_block_cadence:#{CACHE_VERSION}:#{@tip_height}:#{@count}"

      if @cache
        @cache.fetch(key, expires_in: 2.hours, race_condition_ttl: 5.seconds) do
          fetch_headers
        end
      else
        fetch_headers
      end
    end

    def fetch_headers
      required = @count + 1
      hash = @rpc.getblockhash(@tip_height)
      headers = []

      required.times do
        break if hash.blank?

        raw = @rpc.getblockheader(hash)
        header = raw.respond_to?(:with_indifferent_access) ? raw.with_indifferent_access : raw
        height = value(header, :height).to_i
        timestamp = value(header, :time).to_i

        break unless height.positive? && timestamp.positive?

        headers << {
          height: height,
          hash: hash.to_s,
          time: Time.at(timestamp).utc
        }

        hash = value(header, :previousblockhash)
      end

      headers.sort_by { |header| header[:height] }
    end

    def build_blocks(headers)
      previous_by_height = headers.index_by { |header| header[:height] }

      headers.last(@count).sort_by { |header| -header[:height] }.map do |header|
        previous = previous_by_height[header[:height] - 1]
        raw_interval = previous ? header[:time].to_i - previous[:time].to_i : nil
        interval_seconds = raw_interval&.positive? ? raw_interval : nil

        {
          height: header[:height],
          time: header[:time].iso8601,
          age_seconds: [@now.to_i - header[:time].to_i, 0].max,
          interval_seconds: interval_seconds,
          timestamp_anomaly: raw_interval.present? && raw_interval <= 0,
          state: block_state(header[:height])
        }
      end
    end

    def block_state(height)
      return "certified" if height <= @processed_height
      return "processing" if @processing_height == height

      "waiting"
    end

    def recent_certification_average_seconds
      durations =
        BlockBufferModel
          .where(status: "processed")
          .where.not(duration_ms: nil)
          .order(height: :desc)
          .limit(10)
          .pluck(:duration_ms)
          .map { |duration_ms| duration_ms.to_f / 1_000.0 }
          .select(&:positive?)

      average(durations)
    rescue StandardError
      nil
    end

    def backlog_span(headers, lag)
      return 0 if lag.zero?

      by_height = headers.index_by { |header| header[:height] }
      processed_header = by_height[@processed_height]
      tip_header = by_height[@tip_height]
      return nil unless processed_header && tip_header

      delta = tip_header[:time].to_i - processed_header[:time].to_i
      delta.positive? ? delta : nil
    end

    def recent_span(blocks)
      times = blocks.filter_map { |block| Time.iso8601(block[:time]) rescue nil }
      return nil if times.size < 2

      delta = times.max.to_i - times.min.to_i
      delta.positive? ? delta : nil
    end

    def diagnosis(
      lag:,
      average_interval_seconds:,
      backlog_span_seconds:,
      certification_average_seconds:,
      waiting_block:,
      processing_block:
    )
      if lag.zero?
        return {
          code: "synced",
          label: "Synchronisé",
          detail: synced_detail(average_interval_seconds)
        }
      end

      required_processing_seconds =
        if certification_average_seconds.to_f.positive?
          certification_average_seconds.to_f * lag
        end

      backlog_average_seconds =
        if backlog_span_seconds.to_f.positive? && lag.positive?
          backlog_span_seconds.to_f / lag
        end

      burst =
        backlog_average_seconds.to_f.between?(1, 119) ||
        (backlog_average_seconds.nil? && average_interval_seconds.to_f.between?(1, 119))

      unless processing_block
        if burst
          return {
            code: "burst",
            label: "Rafale réseau",
            detail: burst_waiting_detail(lag, backlog_span_seconds, average_interval_seconds, waiting_block)
          }
        end

        if lag >= 3
          return {
            code: "watch",
            label: "Retard à surveiller",
            detail: "Aucun bloc n’est en traitement alors que #{blocks_label(lag)} attendent leur prise en charge."
          }
        end

        return {
          code: "waiting",
          label: "En attente",
          detail: waiting_detail(waiting_block)
        }
      end

      if burst
        return {
          code: "burst",
          label: "Rafale réseau",
          detail: burst_processing_detail(
            lag,
            backlog_span_seconds,
            average_interval_seconds,
            processing_block
          )
        }
      end

      if certification_average_seconds.to_f.positive? &&
         average_interval_seconds.to_f.positive? &&
         certification_average_seconds > average_interval_seconds * 1.15
        return {
          code: "processing_pressure",
          label: "Layer1 sous pression",
          detail: "Layer1 certifie le bloc #{processing_block[:height]}, mais sa cadence récente est plus lente que celle du réseau."
        }
      end

      if backlog_span_seconds.to_f.positive? &&
         required_processing_seconds.to_f.positive? &&
         backlog_span_seconds < required_processing_seconds
        return {
          code: "catching_up",
          label: "Rattrapage en cours",
          detail: "Layer1 certifie le bloc #{processing_block[:height]}. Les blocs en attente sont arrivés plus vite que leur temps moyen de certification."
        }
      end

      if lag >= 3
        return {
          code: "watch",
          label: "Retard à surveiller",
          detail: "Layer1 certifie le bloc #{processing_block[:height]}, mais les blocs récents sont espacés normalement."
        }
      end

      {
        code: "catching_up",
        label: "Rattrapage en cours",
        detail: "Layer1 certifie actuellement le bloc #{processing_block[:height]}."
      }
    end

    def synced_detail(average_interval_seconds)
      return "Layer1 suit le dernier bloc Bitcoin Core." unless average_interval_seconds.to_f.positive?

      "Cadence récente : un bloc toutes les #{duration_label(average_interval_seconds)}."
    end

    def waiting_detail(waiting_block)
      return "Un bloc attend sa prise en charge par Layer1." unless waiting_block

      "Le bloc #{waiting_block[:height]} attend sa prise en charge depuis #{duration_label(waiting_block[:age_seconds])}."
    end

    def burst_waiting_detail(lag, backlog_span_seconds, average_interval_seconds, waiting_block)
      prefix = burst_interval_detail(lag, backlog_span_seconds, average_interval_seconds)
      suffix =
        if waiting_block
          "Le bloc #{waiting_block[:height]} attend sa prise en charge."
        else
          "Le prochain bloc attend sa prise en charge."
        end

      "#{prefix} #{suffix}"
    end

    def burst_processing_detail(lag, backlog_span_seconds, average_interval_seconds, processing_block)
      "#{burst_interval_detail(lag, backlog_span_seconds, average_interval_seconds)} Layer1 certifie le bloc #{processing_block[:height]}."
    end

    def burst_interval_detail(lag, backlog_span_seconds, average_interval_seconds)
      if backlog_span_seconds.to_f.positive?
        "#{blocks_label(lag)} ont été horodatés en #{duration_label(backlog_span_seconds)}."
      elsif average_interval_seconds.to_f.positive?
        "Cadence récente : un bloc toutes les #{duration_label(average_interval_seconds)}."
      else
        "Plusieurs blocs sont arrivés rapidement."
      end
    end

    def blocks_label(value)
      value == 1 ? "1 bloc" : "#{value} blocs"
    end

    def duration_label(seconds)
      total = seconds.to_i
      return "#{total} s" if total < 60

      minutes = total / 60
      remaining = total % 60
      return "#{minutes} min" if remaining.zero?

      "#{minutes} min #{remaining} s"
    end

    def average(values)
      values = Array(values).compact.map(&:to_f).select(&:positive?)
      return nil if values.empty?

      values.sum / values.size
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:[])

      hash[key] || hash[key.to_s]
    end

    def unavailable(reason)
      {
        available: false,
        blocks: [],
        diagnosis: "unknown",
        diagnosis_label: "Cadence indisponible",
        diagnosis_detail: reason
      }
    end
    end
  end
end
