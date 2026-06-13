# frozen_string_literal: true

class Layer1BalanceJob < ApplicationJob
  queue_as :low

  OUTPUTS_HIGH = ENV.fetch("LAYER1_OUTPUTS_HIGH", "250000").to_i
  OUTPUTS_LOW  = ENV.fetch("LAYER1_OUTPUTS_LOW", "100000").to_i

  def perform
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

    outputs = redis.llen("blockchain:outputs:buffer")
    spent = redis.llen("blockchain:spent_outputs:buffer")
    lag = Blockchain::State::Layer1Lag.call

    Rails.logger.info("[layer1_balance] outputs=#{outputs} spent=#{spent} lag=#{lag}")

    if outputs > OUTPUTS_HIGH
      enqueue_flushers(4)
      return
    end

    if outputs > OUTPUTS_LOW
      enqueue_flushers(2)
      return
    end

    if lag.positive?
      Blockchain::State::ProcessingRunner.new.call(limit: 10)
      enqueue_flushers(2)
      return
    end

    enqueue_flushers(2) if outputs.positive? || spent.positive?
  end

  private

  def enqueue_flushers(count)
    count.times do
      Blockchain::Flushers::OutputFlusherJob.perform_later
    end

    count.times do
      Blockchain::Flushers::SpentOutputFlusherJob.perform_later
    end
  end
end
