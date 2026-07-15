# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class SpentOutputFlusherSelectorTest < ActiveSupport::TestCase
  ENV_NAME = "SPENT_OUTPUT_FLUSHER_V2"

  V2_VALUES = {
    "an absent value" => nil,
    "an empty value" => "",
    "spaces only" => "   ",
    "one" => "1",
    "true" => "true",
    "uppercase true" => "TRUE",
    "yes" => "yes",
    "on" => "on"
  }.freeze

  LEGACY_VALUES = {
    "zero" => "0",
    "false" => "false",
    "uppercase false" => "FALSE",
    "no" => "no",
    "off" => "off"
  }.freeze

  INVALID_VALUES = %w[2 treu enabled disabled arbitrary].freeze

  setup do
    @previous_value = ENV[ENV_NAME]
  end

  teardown do
    if @previous_value.nil?
      ENV.delete(ENV_NAME)
    else
      ENV[ENV_NAME] = @previous_value
    end
  end

  V2_VALUES.each do |description, value|
    test "selects v2 for #{description}" do
      with_setting(value) do
        assert_equal(
          Blockchain::Flushers::SpentOutputFlusherV2,
          Blockchain::Flushers::SpentOutputFlusherSelector.flusher_class
        )
      end
    end
  end

  LEGACY_VALUES.each do |description, value|
    test "selects legacy rollback for #{description}" do
      with_setting(value) do
        assert_equal(
          Blockchain::Flushers::SpentOutputFlusher,
          Blockchain::Flushers::SpentOutputFlusherSelector.flusher_class
        )
      end
    end
  end

  INVALID_VALUES.each do |value|
    test "rejects invalid value #{value}" do
      with_setting(value) do
        error = assert_raises(
          Blockchain::Flushers::SpentOutputFlusherSelector::ConfigurationError
        ) do
          Blockchain::Flushers::SpentOutputFlusherSelector.flusher_class
        end

        assert_includes error.message, ENV_NAME
        assert_includes error.message, value.inspect
        refute_includes error.message, "REDIS_URL"
      end
    end
  end

  test "builds v2 in realtime mode" do
    assert_builds_only(
      setting: "1",
      selected: Blockchain::Flushers::SpentOutputFlusherV2,
      rejected: Blockchain::Flushers::SpentOutputFlusher,
      mode: :realtime
    )
  end

  test "builds v2 in recovery mode" do
    assert_builds_only(
      setting: nil,
      selected: Blockchain::Flushers::SpentOutputFlusherV2,
      rejected: Blockchain::Flushers::SpentOutputFlusher,
      mode: :recovery
    )
  end

  test "builds legacy rollback in realtime mode" do
    assert_builds_only(
      setting: "0",
      selected: Blockchain::Flushers::SpentOutputFlusher,
      rejected: Blockchain::Flushers::SpentOutputFlusherV2,
      mode: :realtime
    )
  end

  test "builds legacy rollback in recovery mode" do
    assert_builds_only(
      setting: "false",
      selected: Blockchain::Flushers::SpentOutputFlusher,
      rejected: Blockchain::Flushers::SpentOutputFlusherV2,
      mode: :recovery
    )
  end

  test "calls the selected flusher once and preserves its return value" do
    redis = Object.new
    logger = Object.new
    expected = { ok: true, flushed: 3 }
    calls = 0
    constructor_options = nil
    flusher = Object.new
    flusher.define_singleton_method(:call) do
      calls += 1
      expected
    end

    result = with_setting(nil) do
      Blockchain::Flushers::SpentOutputFlusherV2.stub(
        :new,
        lambda do |**options|
          constructor_options = options
          flusher
        end
      ) do
        Blockchain::Flushers::SpentOutputFlusher.stub(
          :new,
          ->(**) { flunk "legacy flusher must not be instantiated" }
        ) do
          Blockchain::Flushers::SpentOutputFlusherSelector.call(
            redis: redis,
            logger: logger,
            mode: :recovery
          )
        end
      end
    end

    assert_same expected, result
    assert_equal 1, calls
    assert_same redis, constructor_options[:redis]
    assert_same logger, constructor_options[:logger]
    assert_equal :recovery, constructor_options[:mode]
  end

  test "propagates the selected flusher exception unchanged" do
    expected = RuntimeError.new("selected flusher failed")
    flusher = Object.new
    flusher.define_singleton_method(:call) { raise expected }

    error = with_setting("on") do
      Blockchain::Flushers::SpentOutputFlusherV2.stub(
        :new,
        ->(**) { flusher }
      ) do
        Blockchain::Flushers::SpentOutputFlusher.stub(
          :new,
          ->(**) { flunk "legacy flusher must not be instantiated" }
        ) do
          assert_raises(RuntimeError) do
            Blockchain::Flushers::SpentOutputFlusherSelector.call(
              redis: Object.new
            )
          end
        end
      end
    end

    assert_same expected, error
  end

  test "selection performs no sql redis or sidekiq operation" do
    flusher = Object.new
    flusher.define_singleton_method(:call) { :done }

    result = assert_no_queries_match(/\S/) do
      with_setting(" yes ") do
        Redis.stub(:new, ->(*) { flunk "selector must not access Redis" }) do
          Sidekiq::Client.stub(
            :push,
            ->(*) { flunk "selector must not schedule Sidekiq work" }
          ) do
            Blockchain::Flushers::SpentOutputFlusherV2.stub(
              :new,
              ->(**) { flusher }
            ) do
              Blockchain::Flushers::SpentOutputFlusher.stub(
                :new,
                ->(**) { flunk "legacy flusher must not be instantiated" }
              ) do
                Blockchain::Flushers::SpentOutputFlusherSelector.call(
                  redis: Object.new
                )
              end
            end
          end
        end
      end
    end

    assert_equal :done, result
  end

  test "restores the environment after scoped selection" do
    original = ENV[ENV_NAME]

    with_setting("0") do
      assert_equal "0", ENV[ENV_NAME]
    end

    if original.nil?
      assert_nil ENV[ENV_NAME]
    else
      assert_equal original, ENV[ENV_NAME]
    end
  end

  test "rejects invalid mode before constructing either flusher" do
    with_setting(nil) do
      Blockchain::Flushers::SpentOutputFlusherV2.stub(
        :new,
        ->(**) { flunk "v2 flusher must not be instantiated" }
      ) do
        Blockchain::Flushers::SpentOutputFlusher.stub(
          :new,
          ->(**) { flunk "legacy flusher must not be instantiated" }
        ) do
          error = assert_raises(ArgumentError) do
            Blockchain::Flushers::SpentOutputFlusherSelector.build(
              redis: Object.new,
              mode: :invalid
            )
          end

          assert_match "unknown spent output flusher mode", error.message
        end
      end
    end
  end

  private

  def with_setting(value)
    previous = ENV[ENV_NAME]

    if value.nil?
      ENV.delete(ENV_NAME)
    else
      ENV[ENV_NAME] = value
    end

    yield
  ensure
    if previous.nil?
      ENV.delete(ENV_NAME)
    else
      ENV[ENV_NAME] = previous
    end
  end

  def assert_builds_only(setting:, selected:, rejected:, mode:)
    redis = Object.new
    logger = Object.new
    instance = Object.new
    received = nil

    built = with_setting(setting) do
      selected.stub(
        :new,
        lambda do |**options|
          received = options
          instance
        end
      ) do
        rejected.stub(
          :new,
          ->(**) { flunk "non-selected flusher must not be instantiated" }
        ) do
          Blockchain::Flushers::SpentOutputFlusherSelector.build(
            redis: redis,
            logger: logger,
            mode: mode
          )
        end
      end
    end

    assert_same instance, built
    assert_same redis, received[:redis]
    assert_same logger, received[:logger]
    assert_equal mode, received[:mode]
  end
end
