class AllowNullBtcAmountOnTradeSimulations < ActiveRecord::Migration[8.0]
  def change
    change_column_null :trade_simulations, :btc_amount, true
  end
end
