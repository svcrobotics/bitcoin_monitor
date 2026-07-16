# frozen_string_literal: true

require "test_helper"

class SidekiqRecoveryTest < ActiveSupport::TestCase
  FakeConfig = Struct.new(:startup_callback) do
    def on(event, &block)
      raise "unexpected event: #{event}" unless event == :startup

      self.startup_callback = block
    end
  end

  FakeRedis = Struct.new(:set_calls) do
    def set(*args, **kwargs)
      set_calls << [args, kwargs]
      true
    end
  end

  test "legacy recovery is disabled for absent, empty, and explicit false values" do
    [nil, "", " ", "0", "false", "no", "off", "FALSE"].each do |value|
      refute TansaLegacySidekiqRecovery.enabled?(value), value.inspect
    end
  end

  test "legacy recovery recognizes only explicit true values" do
    %w[1 true yes on TRUE].each do |value|
      assert TansaLegacySidekiqRecovery.enabled?(value), value.inspect
    end
  end

  test "invalid value fails closed before Sidekiq is configured" do
    configured = 0

    with_recovery_env("sometimes") do
      with_singleton_method(Sidekiq, :configure_server, ->(*) { configured += 1 }) do
        assert_raises(ArgumentError) { TansaLegacySidekiqRecovery.install! }
      end
    end

    assert_equal 0, configured
  end

  test "disabled recovery performs no boot action" do
    configured = 0

    [nil, "", "0", "false", "no", "off"].each do |value|
      with_recovery_env(value) do
        with_singleton_method(Sidekiq, :configure_server, ->(*) { configured += 1 }) do
          refute TansaLegacySidekiqRecovery.install!
        end
      end
    end

    assert_equal 0, configured
  end

  test "the former recovery flag cannot activate the bootstrap" do
    configured = 0
    previous = ENV["SIDEKIQ_RECOVERY_ENABLED"]
    ENV["SIDEKIQ_RECOVERY_ENABLED"] = "1"

    with_recovery_env(nil) do
      with_singleton_method(Sidekiq, :configure_server, ->(*) { configured += 1 }) do
        refute TansaLegacySidekiqRecovery.install!
      end
    end

    assert_equal 0, configured
  ensure
    previous.nil? ? ENV.delete("SIDEKIQ_RECOVERY_ENABLED") : ENV["SIDEKIQ_RECOVERY_ENABLED"] = previous
  end

  test "enabled recovery registers one startup enqueue behind the existing lock" do
    config = FakeConfig.new
    redis = FakeRedis.new([])
    enqueues = 0

    with_recovery_env("yes") do
      with_singleton_method(Sidekiq, :configure_server, ->(&block) { block.call(config) }) do
        assert TansaLegacySidekiqRecovery.install!
      end
    end

    with_singleton_method(Sidekiq, :redis, ->(&block) { block.call(redis) }) do
      with_singleton_method(RecoveryOrchestratorJob, :perform_later, -> { enqueues += 1 }) do
        config.startup_callback.call
      end
    end

    assert_equal 1, enqueues
    assert_equal [
      [["recovery:startup_enqueue_lock", Process.pid], { nx: true, ex: 60 }]
    ], redis.set_calls
  end

  test "enabled recovery does not enqueue when the startup lock already exists" do
    config = FakeConfig.new
    redis = FakeRedis.new([])
    redis.define_singleton_method(:set) do |*args, **kwargs|
      set_calls << [args, kwargs]
      false
    end
    enqueues = 0

    with_recovery_env("1") do
      with_singleton_method(Sidekiq, :configure_server, ->(&block) { block.call(config) }) do
        assert TansaLegacySidekiqRecovery.install!
      end
    end

    with_singleton_method(Sidekiq, :redis, ->(&block) { block.call(redis) }) do
      with_singleton_method(RecoveryOrchestratorJob, :perform_later, -> { enqueues += 1 }) do
        config.startup_callback.call
      end
    end

    assert_equal 0, enqueues
    assert_equal 1, redis.set_calls.size
  end

  private

  def with_singleton_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, replacement)
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  def with_recovery_env(value)
    key = TansaLegacySidekiqRecovery::ENV_KEY
    previous = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end
end
