require "test_helper"

class TradeSimulationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @trade_simulation = trade_simulations(:one)
  end

  test "should get index" do
    get trade_simulations_url
    assert_response :success
  end

  test "should get new" do
    get new_trade_simulation_url
    assert_response :success
  end

  test "should create trade_simulation" do
    assert_difference("TradeSimulation.count") do
      post trade_simulations_url, params: { trade_simulation: { btc_amount: @trade_simulation.btc_amount, buy_day: @trade_simulation.buy_day, buy_fee_fixed_eur: @trade_simulation.buy_fee_fixed_eur, buy_fee_pct: @trade_simulation.buy_fee_pct, notes: @trade_simulation.notes, sell_day: @trade_simulation.sell_day, sell_fee_fixed_eur: @trade_simulation.sell_fee_fixed_eur, sell_fee_pct: @trade_simulation.sell_fee_pct, slippage_pct: @trade_simulation.slippage_pct } }
    end

    assert_redirected_to trade_simulation_url(TradeSimulation.last)
  end

  test "should show trade_simulation" do
    get trade_simulation_url(@trade_simulation)
    assert_response :success
  end

  test "should get edit" do
    get edit_trade_simulation_url(@trade_simulation)
    assert_response :success
  end

  test "should update trade_simulation" do
    patch trade_simulation_url(@trade_simulation), params: { trade_simulation: { btc_amount: @trade_simulation.btc_amount, buy_day: @trade_simulation.buy_day, buy_fee_fixed_eur: @trade_simulation.buy_fee_fixed_eur, buy_fee_pct: @trade_simulation.buy_fee_pct, notes: @trade_simulation.notes, sell_day: @trade_simulation.sell_day, sell_fee_fixed_eur: @trade_simulation.sell_fee_fixed_eur, sell_fee_pct: @trade_simulation.sell_fee_pct, slippage_pct: @trade_simulation.slippage_pct } }
    assert_redirected_to trade_simulation_url(@trade_simulation)
  end

  test "should destroy trade_simulation" do
    assert_difference("TradeSimulation.count", -1) do
      delete trade_simulation_url(@trade_simulation)
    end

    assert_redirected_to trade_simulations_url
  end
end
