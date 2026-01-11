# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_01_10_232546) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "ai_insights", force: :cascade do |t|
    t.string "key"
    t.text "content"
    t.string "provider"
    t.string "model"
    t.string "input_digest"
    t.jsonb "meta"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["input_digest"], name: "index_ai_insights_on_input_digest"
    t.index ["key"], name: "index_ai_insights_on_key"
  end

  create_table "brc20_balances", force: :cascade do |t|
    t.integer "brc20_token_id", null: false
    t.string "tick", null: false
    t.string "address", null: false
    t.string "balance", default: "0", null: false
    t.string "minted", default: "0", null: false
    t.string "transferred_in", default: "0", null: false
    t.string "transferred_out", default: "0", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brc20_token_id", "address"], name: "index_brc20_balances_on_brc20_token_id_and_address", unique: true
    t.index ["brc20_token_id"], name: "index_brc20_balances_on_brc20_token_id"
    t.index ["tick", "address"], name: "index_brc20_balances_on_tick_and_address"
  end

  create_table "brc20_block_stats", force: :cascade do |t|
    t.integer "block_height", null: false
    t.string "block_hash", null: false
    t.string "tick", null: false
    t.integer "deploy_count", default: 0, null: false
    t.string "deploy_max"
    t.integer "mint_count", default: 0, null: false
    t.string "mint_volume", default: "0", null: false
    t.integer "transfer_count", default: 0, null: false
    t.string "transfer_volume", default: "0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["block_height", "tick"], name: "index_brc20_block_stats_on_block_height_and_tick", unique: true
    t.index ["block_height"], name: "index_brc20_block_stats_on_block_height"
    t.index ["tick"], name: "index_brc20_block_stats_on_tick"
  end

  create_table "brc20_events", force: :cascade do |t|
    t.integer "brc20_token_id"
    t.string "tick", null: false
    t.string "txid", null: false
    t.string "inscription_id", null: false
    t.integer "block_height", null: false
    t.string "block_hash", null: false
    t.datetime "block_time", null: false
    t.string "op", null: false
    t.string "amount", default: "0", null: false
    t.string "from_address"
    t.string "to_address"
    t.json "payload"
    t.boolean "is_valid", default: true, null: false
    t.string "invalid_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brc20_token_id", "block_height"], name: "index_brc20_events_on_brc20_token_id_and_block_height"
    t.index ["brc20_token_id"], name: "index_brc20_events_on_brc20_token_id"
    t.index ["inscription_id"], name: "index_brc20_events_on_inscription_id", unique: true
    t.index ["tick", "block_height"], name: "index_brc20_events_on_tick_and_block_height"
    t.index ["txid"], name: "index_brc20_events_on_txid"
  end

  create_table "brc20_scan_ranges", force: :cascade do |t|
    t.integer "from_height", null: false
    t.integer "to_height", null: false
    t.datetime "scanned_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_height", "to_height"], name: "index_brc20_scan_ranges_on_from_height_and_to_height"
    t.index ["from_height"], name: "index_brc20_scan_ranges_on_from_height"
    t.index ["to_height"], name: "index_brc20_scan_ranges_on_to_height"
  end

  create_table "brc20_token_daily_stats", force: :cascade do |t|
    t.integer "brc20_token_id", null: false
    t.date "day", null: false
    t.integer "mint_count", default: 0, null: false
    t.string "mint_volume", default: "0", null: false
    t.integer "transfer_count", default: 0, null: false
    t.string "transfer_volume", default: "0", null: false
    t.integer "active_addresses_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brc20_token_id", "day"], name: "index_brc20_token_daily_stats_on_brc20_token_id_and_day", unique: true
    t.index ["brc20_token_id"], name: "index_brc20_token_daily_stats_on_brc20_token_id"
  end

  create_table "brc20_tokens", force: :cascade do |t|
    t.string "tick", null: false
    t.string "symbol"
    t.string "deploy_inscription_id", null: false
    t.string "deploy_txid", null: false
    t.integer "deploy_block_height", null: false
    t.string "deploy_block_hash", null: false
    t.datetime "deploy_block_time", null: false
    t.string "max_supply", null: false
    t.string "mint_limit"
    t.integer "decimals", default: 18, null: false
    t.string "total_minted", default: "0", null: false
    t.string "total_transferred", default: "0", null: false
    t.integer "holders_count", default: 0, null: false
    t.integer "events_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tick"], name: "index_brc20_tokens_on_tick", unique: true
  end

  create_table "btc_price_days", force: :cascade do |t|
    t.date "day", null: false
    t.decimal "open_usd", precision: 20, scale: 8
    t.decimal "high_usd", precision: 20, scale: 8
    t.decimal "low_usd", precision: 20, scale: 8
    t.decimal "close_usd", precision: 20, scale: 8, null: false
    t.string "source", default: "coingecko", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "volume_btc", precision: 20, scale: 8
    t.jsonb "sources_json", default: {}, null: false
    t.datetime "computed_at"
    t.index ["computed_at"], name: "index_btc_price_days_on_computed_at"
    t.index ["day"], name: "index_btc_price_days_on_day", unique: true
  end

  create_table "exchange_addresses", force: :cascade do |t|
    t.string "address"
    t.integer "confidence"
    t.integer "occurrences"
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.string "source"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "exchange_flows", force: :cascade do |t|
    t.date "day"
    t.decimal "inflow_btc"
    t.decimal "avg7"
    t.decimal "avg30"
    t.decimal "avg200"
    t.decimal "ratio30"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "exchange_true_flows", force: :cascade do |t|
    t.date "day"
    t.decimal "inflow_btc"
    t.decimal "outflow_btc"
    t.decimal "netflow_btc"
    t.decimal "avg7"
    t.decimal "avg30"
    t.decimal "avg200"
    t.decimal "ratio30"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "feature_requests", force: :cascade do |t|
    t.string "title", null: false
    t.text "description", null: false
    t.string "email"
    t.integer "amount_sats", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.string "btcpay_invoice_id"
    t.string "btcpay_checkout_url"
    t.datetime "paid_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "guides", force: :cascade do |t|
    t.string "title"
    t.string "slug"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "draft", null: false
    t.boolean "featured", default: false
    t.text "excerpt"
    t.string "category"
    t.string "app_area"
    t.integer "position", default: 0
    t.index ["app_area"], name: "index_guides_on_app_area"
    t.index ["category"], name: "index_guides_on_category"
    t.index ["position"], name: "index_guides_on_position"
    t.index ["slug"], name: "index_guides_on_slug"
    t.index ["status"], name: "index_guides_on_status"
  end

  create_table "journal_entries", force: :cascade do |t|
    t.datetime "occurred_at"
    t.string "kind"
    t.string "mood"
    t.decimal "btc_price_eur"
    t.string "context"
    t.text "body"
    t.string "tags"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "login_challenges", force: :cascade do |t|
    t.string "nonce", null: false
    t.string "domain", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.string "signed_address"
    t.string "signature_format"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "message_text"
    t.index ["nonce"], name: "index_login_challenges_on_nonce", unique: true
  end

  create_table "market_snapshots", force: :cascade do |t|
    t.datetime "computed_at", null: false
    t.decimal "price_now_usd", precision: 20, scale: 8
    t.decimal "ma200_usd", precision: 20, scale: 8
    t.decimal "price_vs_ma200_pct", precision: 10, scale: 4
    t.decimal "ath_usd", precision: 20, scale: 8
    t.decimal "drawdown_pct", precision: 10, scale: 4
    t.decimal "amplitude_30d_pct", precision: 10, scale: 4
    t.string "market_bias", null: false
    t.string "cycle_zone", null: false
    t.string "risk_level", null: false
    t.jsonb "reasons", default: [], null: false
    t.string "status", default: "ok", null: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["computed_at"], name: "index_market_snapshots_on_computed_at"
    t.index ["status"], name: "index_market_snapshots_on_status"
  end

  create_table "price_zones", force: :cascade do |t|
    t.string "kind", null: false
    t.decimal "low_usd", precision: 20, scale: 8, null: false
    t.decimal "high_usd", precision: 20, scale: 8, null: false
    t.integer "strength", default: 0, null: false
    t.integer "touches_count", default: 0, null: false
    t.string "timeframe", default: "1y_daily", null: false
    t.datetime "computed_at", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["computed_at"], name: "index_price_zones_on_computed_at"
    t.index ["kind", "timeframe", "computed_at"], name: "index_price_zones_on_kind_and_timeframe_and_computed_at"
    t.index ["kind"], name: "index_price_zones_on_kind"
  end

  create_table "rune_balances", force: :cascade do |t|
    t.bigint "rune_token_id", null: false
    t.string "address", null: false
    t.decimal "balance", precision: 39, default: "0", null: false
    t.integer "first_seen_block_height"
    t.integer "last_seen_block_height"
    t.datetime "last_updated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["address"], name: "index_rune_balances_on_address"
    t.index ["rune_token_id", "address"], name: "index_rune_balances_on_rune_token_id_and_address", unique: true
    t.index ["rune_token_id"], name: "index_rune_balances_on_rune_token_id"
  end

  create_table "rune_block_stats", force: :cascade do |t|
    t.integer "block_height", null: false
    t.datetime "block_time"
    t.integer "rune_tx_count", default: 0, null: false
    t.integer "rune_events_count", default: 0, null: false
    t.integer "distinct_runes_count", default: 0, null: false
    t.decimal "total_runes_volume", precision: 39, default: "0", null: false
    t.bigint "total_runes_bytes", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["block_height"], name: "index_rune_block_stats_on_block_height", unique: true
  end

  create_table "rune_events", force: :cascade do |t|
    t.bigint "rune_token_id"
    t.string "rune_name"
    t.string "op", null: false
    t.string "txid", null: false
    t.integer "vout"
    t.integer "vin"
    t.integer "block_height"
    t.datetime "block_time"
    t.decimal "amount", precision: 39
    t.string "from_address"
    t.string "to_address"
    t.boolean "is_valid", default: true, null: false
    t.jsonb "raw_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["block_height"], name: "index_rune_events_on_block_height"
    t.index ["op"], name: "index_rune_events_on_op"
    t.index ["rune_token_id", "block_height"], name: "index_rune_events_on_rune_token_id_and_block_height"
    t.index ["rune_token_id"], name: "index_rune_events_on_rune_token_id"
    t.index ["txid"], name: "index_rune_events_on_txid"
  end

  create_table "rune_token_daily_stats", force: :cascade do |t|
    t.bigint "rune_token_id", null: false
    t.date "day", null: false
    t.integer "tx_count", default: 0, null: false
    t.integer "transfer_count", default: 0, null: false
    t.integer "mint_count", default: 0, null: false
    t.integer "burn_count", default: 0, null: false
    t.decimal "volume", precision: 39, default: "0", null: false
    t.integer "unique_senders", default: 0, null: false
    t.integer "unique_receivers", default: 0, null: false
    t.integer "active_addresses_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_rune_token_daily_stats_on_day"
    t.index ["rune_token_id", "day"], name: "index_rune_token_daily_stats_on_rune_token_id_and_day", unique: true
    t.index ["rune_token_id"], name: "index_rune_token_daily_stats_on_rune_token_id"
  end

  create_table "rune_tokens", force: :cascade do |t|
    t.string "rune_name", null: false
    t.string "normalized_name", null: false
    t.integer "rune_id_block", null: false
    t.integer "rune_id_tx", null: false
    t.string "symbol"
    t.integer "divisibility", default: 0, null: false
    t.decimal "cap_supply", precision: 39
    t.decimal "premine_amount", precision: 39
    t.decimal "minted_supply", precision: 39, default: "0"
    t.decimal "burned_supply", precision: 39, default: "0"
    t.boolean "minting_finished", default: false, null: false
    t.string "etching_txid"
    t.integer "etching_vout"
    t.integer "etching_block_height"
    t.datetime "etching_block_time"
    t.integer "first_seen_block_height"
    t.integer "last_seen_block_height"
    t.datetime "last_activity_at"
    t.integer "events_count", default: 0, null: false
    t.integer "transfers_count", default: 0, null: false
    t.integer "holders_count", default: 0, null: false
    t.jsonb "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["etching_txid"], name: "index_rune_tokens_on_etching_txid", unique: true
    t.index ["normalized_name"], name: "index_rune_tokens_on_normalized_name"
    t.index ["rune_id_block", "rune_id_tx"], name: "index_rune_tokens_on_rune_id_block_and_rune_id_tx", unique: true
  end

  create_table "trade_simulation_points", force: :cascade do |t|
    t.bigint "trade_simulation_id", null: false
    t.date "day", null: false
    t.decimal "price_usd", precision: 20, scale: 8, null: false
    t.decimal "net_usd", precision: 20, scale: 8, null: false
    t.decimal "pnl_usd", precision: 20, scale: 8, null: false
    t.decimal "pnl_pct", precision: 10, scale: 4, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_trade_simulation_points_on_day"
    t.index ["trade_simulation_id", "day"], name: "index_trade_simulation_points_on_trade_simulation_id_and_day", unique: true
    t.index ["trade_simulation_id"], name: "index_trade_simulation_points_on_trade_simulation_id"
  end

  create_table "trade_simulations", force: :cascade do |t|
    t.date "buy_day"
    t.date "sell_day"
    t.decimal "btc_amount", precision: 20, scale: 8, null: false
    t.decimal "buy_fee_pct", precision: 6, scale: 3, default: "0.0", null: false
    t.decimal "buy_fee_fixed_eur", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "sell_fee_pct", precision: 6, scale: 3, default: "0.0", null: false
    t.decimal "sell_fee_fixed_eur", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "slippage_pct", precision: 6, scale: 3, default: "0.0", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "vault_addresses", force: :cascade do |t|
    t.bigint "vault_id", null: false
    t.string "kind", null: false
    t.integer "index", null: false
    t.string "address", null: false
    t.datetime "last_seen_at"
    t.integer "last_seen_block"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["address"], name: "index_vault_addresses_on_address", unique: true
    t.index ["kind"], name: "index_vault_addresses_on_kind"
    t.index ["last_seen_block"], name: "index_vault_addresses_on_last_seen_block"
    t.index ["vault_id", "kind", "index"], name: "idx_vault_addresses_unique", unique: true
    t.index ["vault_id"], name: "index_vault_addresses_on_vault_id"
  end

  create_table "vaults", force: :cascade do |t|
    t.string "label", null: false
    t.string "pubkey_a"
    t.string "pubkey_b"
    t.integer "delay_blocks", default: 4320
    t.text "miniscript"
    t.text "descriptor"
    t.text "script_hex"
    t.string "address"
    t.string "network", default: "mainnet", null: false
    t.string "status", default: "draft", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "redeem_script_hex"
    t.string "xpub_a"
    t.string "xpub_b"
    t.string "address_a"
    t.string "address_b"
    t.integer "csv_blocks"
    t.bigint "balance_sats"
    t.integer "utxos_count"
    t.integer "utxos_unconfirmed_count"
    t.datetime "last_scanned_at"
    t.string "last_scan_status"
    t.text "last_scan_error"
    t.string "ledger_a_fp"
    t.string "ledger_b_fp"
    t.text "psbt_last_generated"
    t.text "psbt_signed_by_a"
    t.text "psbt_signed_by_b"
    t.string "psbt_last_mode"
    t.text "psbt_last_debug"
    t.integer "first_seen_block"
    t.string "derivation_path"
    t.integer "derivation_index"
    t.string "pubkey_a_child"
    t.string "pubkey_b_child"
    t.text "witness_script"
    t.text "receive_descriptor"
    t.text "change_descriptor"
    t.integer "scan_range", default: 200, null: false
    t.string "watch_wallet_name"
    t.index ["address"], name: "index_vaults_on_address"
    t.index ["derivation_path", "derivation_index"], name: "index_vaults_on_derivation"
    t.index ["first_seen_block"], name: "index_vaults_on_first_seen_block"
    t.index ["network"], name: "index_vaults_on_network"
    t.index ["status"], name: "index_vaults_on_status"
  end

  create_table "whale_alerts", force: :cascade do |t|
    t.string "txid", null: false
    t.integer "block_height"
    t.datetime "block_time"
    t.decimal "total_out_btc", precision: 16, scale: 8, default: "0.0", null: false
    t.integer "inputs_count", default: 0, null: false
    t.integer "outputs_count", default: 0, null: false
    t.integer "outputs_nonzero_count", default: 0, null: false
    t.decimal "largest_output_btc", precision: 16, scale: 8, default: "0.0", null: false
    t.decimal "largest_output_ratio", precision: 6, scale: 4, default: "0.0", null: false
    t.string "alert_type", default: "other", null: false
    t.integer "score", default: 0, null: false
    t.jsonb "meta", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "exchange_likelihood"
    t.string "exchange_hint"
    t.index ["alert_type"], name: "index_whale_alerts_on_alert_type"
    t.index ["block_height"], name: "index_whale_alerts_on_block_height"
    t.index ["block_time"], name: "index_whale_alerts_on_block_time"
    t.index ["score"], name: "index_whale_alerts_on_score"
    t.index ["txid"], name: "index_whale_alerts_on_txid", unique: true
  end

  add_foreign_key "brc20_balances", "brc20_tokens"
  add_foreign_key "brc20_events", "brc20_tokens"
  add_foreign_key "brc20_token_daily_stats", "brc20_tokens"
  add_foreign_key "rune_balances", "rune_tokens"
  add_foreign_key "rune_events", "rune_tokens"
  add_foreign_key "rune_token_daily_stats", "rune_tokens"
  add_foreign_key "trade_simulation_points", "trade_simulations"
  add_foreign_key "vault_addresses", "vaults"
end
