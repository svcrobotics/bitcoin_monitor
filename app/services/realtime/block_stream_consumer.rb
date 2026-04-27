# frozen_string_literal: true
require "sidekiq/api"

module Realtime
  class BlockStreamConsumer
    STREAM = "bitcoin.blocks"
    GROUP = "bitcoin_monitor"
    CONSUMER = "block_consumer"

    def self.call(count: 10)
      new(count: count).call
    end

    def initialize(count:)
      @count = count
      @redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
    end

    def call
      ensure_group!

      entries = redis.call(
        "XREADGROUP",
        "GROUP", GROUP, CONSUMER,
        "COUNT", count,
        "STREAMS", STREAM, ">"
      )

      processed = 0

      if entries.present?
        entries.each do |_stream, messages|
          messages.each do |id, fields|
            event = Hash[*fields]

            process_event(id, event)
            redis.call("XACK", STREAM, GROUP, id)

            processed += 1
          end
        end
      end

      trigger_recovery_if_needed(processed)

      { ok: true, processed: processed }
    end

    private

    attr_reader :redis, :count

    def ensure_group!
      redis.call(
        "XGROUP",
        "CREATE",
        STREAM,
        GROUP,
        "$",
        "MKSTREAM"
      )
    rescue Redis::CommandError => e
      raise unless e.message.include?("BUSYGROUP")
    end

    def process_event(id, event)
      return unless event["type"] == "new_block"

      height = event["height"].to_i
      blockhash = event["blockhash"].to_s

      Rails.logger.info(
        "[block_stream_consumer] new_block id=#{id} height=#{height} hash=#{blockhash}"
      )

      enqueue_once("realtime", "Realtime::ProcessLatestBlockJob") do
        Realtime::ProcessLatestBlockJob.perform_later
      end

      enqueue_once("p1_exchange", "ExchangeObservedScanJob") do
        ExchangeObservedScanJob.perform_later
      end

      enqueue_once("p3_clusters", "ClusterScanJob") do
        ClusterScanJob.perform_later
      end
    end

    def trigger_recovery_if_needed(processed)
      state = System::RecoveryStateBuilder.call

      return if state[:realtime_lag].to_i <= 0 &&
                state[:exchange_lag].to_i <= 0 &&
                state[:cluster_lag].to_i <= 0

      Rails.logger.info(
        "[block_stream_consumer] recovery_needed " \
        "processed=#{processed} " \
        "realtime_lag=#{state[:realtime_lag]} " \
        "exchange_lag=#{state[:exchange_lag]} " \
        "cluster_lag=#{state[:cluster_lag]}"
      )

      if state[:realtime_lag].to_i.positive?
        enqueue_once("realtime", "Realtime::ProcessLatestBlockJob") do
          Realtime::ProcessLatestBlockJob.perform_later
        end
      end

      if state[:exchange_lag].to_i.positive?
        enqueue_once("p1_exchange", "ExchangeObservedScanJob") do
          ExchangeObservedScanJob.perform_later
        end
      end

      if state[:cluster_lag].to_i.positive?
        enqueue_once("p3_clusters", "ClusterScanJob") do
          ClusterScanJob.perform_later
        end
      end
    end

    def enqueue_once(queue_name, klass_name)
      if job_pending_or_running?(queue_name, klass_name)
        Rails.logger.info("[block_stream_consumer] skip_enqueue klass=#{klass_name} queue=#{queue_name}")
        return
      end

      yield
    end

    def job_pending_or_running?(queue_name, klass_name)
      queue_has_job?(queue_name, klass_name) || worker_has_job?(queue_name, klass_name)
    end

    def queue_has_job?(queue_name, klass_name)
      Sidekiq::Queue.new(queue_name).any? do |job|
        job.klass.to_s == klass_name ||
          job.display_class.to_s == klass_name
      end
    rescue StandardError
      false
    end

    def worker_has_job?(queue_name, klass_name)
      Sidekiq::Workers.new.any? do |_, _, work|
        payload = work.payload
        work.queue == queue_name &&
          (
            payload["wrapped"].to_s == klass_name ||
            payload["class"].to_s == klass_name
          )
      end
    rescue StandardError
      false
    end
  end
end
