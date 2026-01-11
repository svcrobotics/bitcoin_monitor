require "application_system_test_case"

class TradeSimulationsTest < ApplicationSystemTestCase
  setup do
    @trade_simulation = trade_simulations(:one)
  end

  test "visiting the index" do
    visit trade_simulations_url
    assert_selector "h1", text: "Trade simulations"
  end

  test "should create trade simulation" do
    visit trade_simulations_url
    click_on "New trade simulation"

    fill_in "Btc amount", with: @trade_simulation.btc_amount
    fill_in "Buy day", with: @trade_simulation.buy_day
    fill_in "Buy fee fixed eur", with: @trade_simulation.buy_fee_fixed_eur
    fill_in "Buy fee pct", with: @trade_simulation.buy_fee_pct
    fill_in "Notes", with: @trade_simulation.notes
    fill_in "Sell day", with: @trade_simulation.sell_day
    fill_in "Sell fee fixed eur", with: @trade_simulation.sell_fee_fixed_eur
    fill_in "Sell fee pct", with: @trade_simulation.sell_fee_pct
    fill_in "Slippage pct", with: @trade_simulation.slippage_pct
    click_on "Create Trade simulation"

    assert_text "Trade simulation was successfully created"
    click_on "Back"
  end

  test "should update Trade simulation" do
    visit trade_simulation_url(@trade_simulation)
    click_on "Edit this trade simulation", match: :first

    fill_in "Btc amount", with: @trade_simulation.btc_amount
    fill_in "Buy day", with: @trade_simulation.buy_day
    fill_in "Buy fee fixed eur", with: @trade_simulation.buy_fee_fixed_eur
    fill_in "Buy fee pct", with: @trade_simulation.buy_fee_pct
    fill_in "Notes", with: @trade_simulation.notes
    fill_in "Sell day", with: @trade_simulation.sell_day
    fill_in "Sell fee fixed eur", with: @trade_simulation.sell_fee_fixed_eur
    fill_in "Sell fee pct", with: @trade_simulation.sell_fee_pct
    fill_in "Slippage pct", with: @trade_simulation.slippage_pct
    click_on "Update Trade simulation"

    assert_text "Trade simulation was successfully updated"
    click_on "Back"
  end

  test "should destroy Trade simulation" do
    visit trade_simulation_url(@trade_simulation)
    accept_confirm { click_on "Destroy this trade simulation", match: :first }

    assert_text "Trade simulation was successfully destroyed"
  end
end
