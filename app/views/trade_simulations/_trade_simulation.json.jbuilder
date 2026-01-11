json.extract! trade_simulation, :id, :buy_day, :sell_day, :btc_amount, :buy_fee_pct, :buy_fee_fixed_eur, :sell_fee_pct, :sell_fee_fixed_eur, :slippage_pct, :notes, :created_at, :updated_at
json.url trade_simulation_url(trade_simulation, format: :json)
