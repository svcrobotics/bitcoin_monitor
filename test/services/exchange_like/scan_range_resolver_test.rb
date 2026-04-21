# frozen_string_literal: true

require "test_helper"

class ExchangeLikeScanRangeResolverTest < ActiveSupport::TestCase
  setup do
    ScannerCursor.where(name: "test_exchange_like_cursor").delete_all
  end

  test "returns incremental range from cursor when cursor exists" do
    ScannerCursor.create!(name: "test_exchange_like_cursor", last_blockheight: 100)

    result = ExchangeLike::ScanRangeResolver.new(
      best_height: 120,
      cursor_name: "test_exchange_like_cursor",
      initial_blocks_back: 50,
      blocks_per_day: 144,
      reset: false
    ).call

    assert_equal :incremental, result.mode
    assert_equal 101, result.start_height
    assert_equal 120, result.end_height
    assert_equal 100, result.cursor_last_blockheight
    assert_equal 20, result.blocks_count
  end

  test "returns incremental recent window when cursor does not exist" do
    result = ExchangeLike::ScanRangeResolver.new(
      best_height: 120,
      cursor_name: "test_exchange_like_cursor",
      initial_blocks_back: 50,
      blocks_per_day: 144,
      reset: false
    ).call

    assert_equal :incremental, result.mode
    assert_equal 71, result.start_height
    assert_equal 120, result.end_height
    assert_nil result.cursor_last_blockheight
    assert_equal 50, result.blocks_count
  end

  test "returns manual blocks_back range" do
    result = ExchangeLike::ScanRangeResolver.new(
      best_height: 120,
      cursor_name: "test_exchange_like_cursor",
      blocks_back: 10,
      initial_blocks_back: 50,
      blocks_per_day: 144,
      reset: false
    ).call

    assert_equal :manual_blocks_back, result.mode
    assert_equal 111, result.start_height
    assert_equal 120, result.end_height
    assert_equal 10, result.blocks_count
  end

  test "returns manual days_back range" do
    result = ExchangeLike::ScanRangeResolver.new(
      best_height: 500,
      cursor_name: "test_exchange_like_cursor",
      days_back: 2,
      initial_blocks_back: 50,
      blocks_per_day: 144,
      reset: false
    ).call

    assert_equal :manual_days_back, result.mode
    assert_equal 213, result.start_height
    assert_equal 500, result.end_height
    assert_equal 288, result.blocks_count
  end

  test "returns manual reset range when reset is true" do
    result = ExchangeLike::ScanRangeResolver.new(
      best_height: 120,
      cursor_name: "test_exchange_like_cursor",
      initial_blocks_back: 50,
      blocks_per_day: 144,
      reset: true
    ).call

    assert_equal :manual_reset, result.mode
    assert_equal 71, result.start_height
    assert_equal 120, result.end_height
    assert_equal 50, result.blocks_count
  end
end
