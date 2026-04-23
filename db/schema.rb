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

ActiveRecord::Schema[8.0].define(version: 2026_04_22_135108) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "address_links", force: :cascade do |t|
    t.bigint "address_a_id", null: false
    t.bigint "address_b_id", null: false
    t.string "link_type", null: false
    t.string "txid", null: false
    t.integer "block_height"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["address_a_id", "address_b_id", "link_type", "txid"], name: "idx_address_links_uniqueness", unique: true
    t.index ["address_a_id"], name: "index_address_links_on_address_a_id"
    t.index ["address_b_id"], name: "index_address_links_on_address_b_id"
    t.index ["block_height"], name: "index_address_links_on_block_height"
    t.index ["txid"], name: "index_address_links_on_txid"
  end

  create_table "addresses", force: :cascade do |t|
    t.string "address", null: false
    t.integer "first_seen_height"
    t.integer "last_seen_height"
    t.bigint "total_received_sats", default: 0, null: false
    t.bigint "total_sent_sats", default: 0, null: false
    t.integer "tx_count", default: 0, null: false
    t.bigint "cluster_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["address"], name: "index_addresses_on_address", unique: true
    t.index ["cluster_id"], name: "index_addresses_on_cluster_id"
    t.index ["first_seen_height"], name: "index_addresses_on_first_seen_height"
    t.index ["last_seen_height"], name: "index_addresses_on_last_seen_height"
  end

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

  create_table "btc_candles", force: :cascade do |t|
    t.string "market", null: false
    t.string "timeframe", null: false
    t.datetime "open_time", null: false
    t.datetime "close_time", null: false
    t.decimal "open", precision: 20, scale: 8, null: false
    t.decimal "high", precision: 20, scale: 8, null: false
    t.decimal "low", precision: 20, scale: 8, null: false
    t.decimal "close", precision: 20, scale: 8, null: false
    t.decimal "volume", precision: 24, scale: 8
    t.integer "trades_count"
    t.string "source", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["market", "timeframe", "open_time"], name: "index_btc_candles_on_market_and_timeframe_and_open_time", unique: true
    t.index ["market", "timeframe"], name: "index_btc_candles_on_market_and_timeframe"
    t.index ["open_time"], name: "index_btc_candles_on_open_time"
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
    t.decimal "close_eur", precision: 20, scale: 8
    t.decimal "open_eur", precision: 20, scale: 8
    t.decimal "high_eur", precision: 20, scale: 8
    t.decimal "low_eur", precision: 20, scale: 8
    t.index ["computed_at"], name: "index_btc_price_days_on_computed_at"
    t.index ["day", "source"], name: "index_btc_price_days_on_day_and_source", unique: true
  end

  create_table "cluster_metrics", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.date "snapshot_date"
    t.integer "tx_count_24h"
    t.integer "tx_count_7d"
    t.bigint "sent_sats_24h"
    t.bigint "sent_sats_7d"
    t.integer "activity_score"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id"], name: "index_cluster_metrics_on_cluster_id"
  end

  create_table "cluster_profiles", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.integer "cluster_size"
    t.integer "tx_count"
    t.bigint "total_sent_sats"
    t.integer "first_seen_height"
    t.integer "last_seen_height"
    t.string "classification"
    t.integer "score"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "traits"
    t.index ["cluster_id"], name: "index_cluster_profiles_on_cluster_id"
  end

  create_table "cluster_signals", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.date "snapshot_date"
    t.string "signal_type"
    t.string "severity"
    t.integer "score"
    t.jsonb "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id"], name: "index_cluster_signals_on_cluster_id"
  end

  create_table "clusters", force: :cascade do |t|
    t.integer "address_count", default: 0, null: false
    t.bigint "total_received_sats", default: 0, null: false
    t.bigint "total_sent_sats", default: 0, null: false
    t.integer "first_seen_height"
    t.integer "last_seen_height"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["first_seen_height"], name: "index_clusters_on_first_seen_height"
    t.index ["last_seen_height"], name: "index_clusters_on_last_seen_height"
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
    t.index ["address"], name: "index_exchange_addresses_on_address", unique: true
  end

  create_table "exchange_flow_day_behaviors", force: :cascade do |t|
    t.date "day", null: false
    t.decimal "retail_deposit_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "retail_deposit_volume_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "whale_deposit_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "whale_deposit_volume_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "institutional_deposit_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "institutional_deposit_volume_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "retail_withdrawal_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "retail_withdrawal_volume_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "whale_withdrawal_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "whale_withdrawal_volume_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "institutional_withdrawal_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "institutional_withdrawal_volume_ratio", precision: 10, scale: 6, default: "0.0"
    t.decimal "deposit_concentration_score", precision: 10, scale: 6, default: "0.0"
    t.decimal "withdrawal_concentration_score", precision: 10, scale: 6, default: "0.0"
    t.decimal "distribution_score", precision: 10, scale: 6, default: "0.0"
    t.decimal "accumulation_score", precision: 10, scale: 6, default: "0.0"
    t.decimal "behavior_score", precision: 10, scale: 6, default: "0.0"
    t.datetime "computed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_exchange_flow_day_behaviors_on_day", unique: true
  end

  create_table "exchange_flow_day_capital_behaviors", force: :cascade do |t|
    t.date "day", null: false
    t.decimal "retail_deposit_capital_ratio", precision: 10, scale: 6
    t.decimal "whale_deposit_capital_ratio", precision: 10, scale: 6
    t.decimal "institutional_deposit_capital_ratio", precision: 10, scale: 6
    t.decimal "retail_withdrawal_capital_ratio", precision: 10, scale: 6
    t.decimal "whale_withdrawal_capital_ratio", precision: 10, scale: 6
    t.decimal "institutional_withdrawal_capital_ratio", precision: 10, scale: 6
    t.decimal "capital_dominance_score", precision: 10, scale: 6
    t.decimal "whale_distribution_score", precision: 10, scale: 6
    t.decimal "whale_accumulation_score", precision: 10, scale: 6
    t.decimal "capital_behavior_score", precision: 10, scale: 6
    t.datetime "computed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "count_volume_divergence_score", precision: 10, scale: 6
    t.index ["day"], name: "index_exchange_flow_day_capital_behaviors_on_day", unique: true
  end

  create_table "exchange_flow_day_details", force: :cascade do |t|
    t.date "day", null: false
    t.integer "deposit_count", default: 0, null: false
    t.decimal "avg_deposit_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "max_deposit_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "inflow_lt_1_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "inflow_1_10_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "inflow_10_100_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "inflow_100_500_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "inflow_gt_500_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.integer "inflow_lt_1_count", default: 0, null: false
    t.integer "inflow_1_10_count", default: 0, null: false
    t.integer "inflow_10_100_count", default: 0, null: false
    t.integer "inflow_100_500_count", default: 0, null: false
    t.integer "inflow_gt_500_count", default: 0, null: false
    t.datetime "computed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "withdrawal_count", default: 0, null: false
    t.decimal "avg_withdrawal_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "max_withdrawal_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "outflow_lt_1_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "outflow_1_10_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "outflow_10_100_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "outflow_100_500_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "outflow_gt_500_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.integer "outflow_lt_1_count", default: 0, null: false
    t.integer "outflow_1_10_count", default: 0, null: false
    t.integer "outflow_10_100_count", default: 0, null: false
    t.integer "outflow_100_500_count", default: 0, null: false
    t.integer "outflow_gt_500_count", default: 0, null: false
    t.index ["day"], name: "index_exchange_flow_day_details_on_day", unique: true
  end

  create_table "exchange_flow_days", force: :cascade do |t|
    t.date "day", null: false
    t.decimal "inflow_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "outflow_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "netflow_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.integer "inflow_utxo_count", default: 0, null: false
    t.integer "outflow_utxo_count", default: 0, null: false
    t.datetime "computed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_exchange_flow_days_on_day", unique: true
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
    t.decimal "true_inflow_btc"
    t.decimal "true_outflow_btc", precision: 20, scale: 8
    t.decimal "true_net_btc", precision: 20, scale: 8
    t.index ["true_outflow_btc"], name: "index_exchange_flows_on_true_outflow_btc"
  end

  create_table "exchange_inflow_breakdowns", force: :cascade do |t|
    t.date "day", null: false
    t.string "scope", default: "inflow", null: false
    t.integer "min_occ", default: 8, null: false
    t.decimal "lt10_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "b10_99_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "b100_499_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "b500p_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "total_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.integer "utxos_count", default: 0, null: false
    t.integer "addresses_count", default: 0, null: false
    t.decimal "top1_btc", precision: 20, scale: 8
    t.decimal "top10_btc", precision: 20, scale: 8
    t.decimal "top1_pct", precision: 8, scale: 4
    t.decimal "top10_pct", precision: 8, scale: 4
    t.jsonb "meta", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day", "scope", "min_occ"], name: "idx_inflow_breakdowns_day_scope_occ", unique: true
    t.index ["day"], name: "index_exchange_inflow_breakdowns_on_day"
  end

  create_table "exchange_observed_utxos", force: :cascade do |t|
    t.string "txid", null: false
    t.integer "vout", null: false
    t.string "address"
    t.decimal "value_btc", precision: 20, scale: 8, null: false
    t.date "seen_day", null: false
    t.string "source", default: "trueflow", null: false
    t.datetime "spent_at"
    t.date "spent_day"
    t.string "spent_by_txid"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "spent_blockhash"
    t.integer "spent_blockheight"
    t.index ["address", "seen_day"], name: "index_exchange_observed_utxos_on_address_and_seen_day"
    t.index ["address"], name: "index_exchange_observed_utxos_on_address"
    t.index ["seen_day"], name: "index_exchange_observed_utxos_on_seen_day"
    t.index ["spent_at"], name: "index_exchange_observed_utxos_on_spent_at"
    t.index ["spent_by_txid"], name: "index_exchange_observed_utxos_on_spent_by_txid"
    t.index ["spent_day"], name: "index_exchange_observed_utxos_on_spent_day"
    t.index ["txid", "vout"], name: "index_exchange_observed_utxos_on_txid_and_vout", unique: true
  end

  create_table "exchange_outflow_breakdowns", force: :cascade do |t|
    t.date "day", null: false
    t.string "scope", null: false
    t.string "bucket", null: false
    t.decimal "btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "pct", precision: 10, scale: 4
    t.jsonb "meta", default: {}, null: false
    t.datetime "computed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day", "scope", "bucket"], name: "idx_outflow_breakdowns_unique", unique: true
    t.index ["day"], name: "index_exchange_outflow_breakdowns_on_day"
    t.index ["scope"], name: "index_exchange_outflow_breakdowns_on_scope"
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
    t.boolean "covered", default: false, null: false
    t.integer "events_count"
    t.integer "touching_exchange_events_count"
    t.decimal "inflow_b_btc"
    t.decimal "inflow_a_btc"
    t.decimal "inflow_s_btc"
    t.decimal "avg30_b"
    t.decimal "avg30_a"
    t.decimal "avg30_s"
    t.decimal "ratio30_b"
    t.decimal "ratio30_a"
    t.decimal "ratio30_s"
    t.decimal "outflow_ext_btc"
    t.decimal "outflow_int_btc"
    t.decimal "outflow_gross_btc"
    t.decimal "outflow_confidence"
    t.string "outflow_kind"
    t.index ["day"], name: "index_exchange_true_flows_on_day", unique: true
    t.index ["outflow_kind"], name: "index_exchange_true_flows_on_outflow_kind"
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
    t.string "slug", null: false
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
    t.index ["slug"], name: "index_guides_on_slug", unique: true
    t.index ["status"], name: "index_guides_on_status"
  end

  create_table "job_runs", force: :cascade do |t|
    t.string "name"
    t.string "status"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.integer "duration_ms"
    t.integer "exit_code"
    t.text "error"
    t.text "meta"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "heartbeat_at"
    t.string "triggered_by"
    t.datetime "scheduled_for"
    t.float "progress_pct"
    t.string "progress_label"
    t.jsonb "progress_meta"
    t.index ["heartbeat_at"], name: "index_job_runs_on_heartbeat_at"
    t.index ["name", "status", "started_at"], name: "index_job_runs_on_name_and_status_and_started_at"
    t.index ["scheduled_for"], name: "index_job_runs_on_scheduled_for"
    t.index ["triggered_by"], name: "index_job_runs_on_triggered_by"
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

  create_table "opsec_answers", force: :cascade do |t|
    t.bigint "opsec_assessment_id", null: false
    t.string "question_key", null: false
    t.string "answer", null: false
    t.integer "risk_points", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["opsec_assessment_id", "question_key"], name: "index_opsec_answers_on_opsec_assessment_id_and_question_key", unique: true
    t.index ["opsec_assessment_id"], name: "index_opsec_answers_on_opsec_assessment_id"
    t.index ["question_key"], name: "index_opsec_answers_on_question_key"
  end

  create_table "opsec_assessments", force: :cascade do |t|
    t.integer "score", default: 0, null: false
    t.string "risk_level", default: "yellow", null: false
    t.integer "total_risk_points", default: 0, null: false
    t.integer "max_risk_points", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["risk_level"], name: "index_opsec_assessments_on_risk_level"
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

  create_table "scan_cursors", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "last_height", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_scan_cursors_on_name", unique: true
  end

  create_table "scanner_cursors", force: :cascade do |t|
    t.string "name", null: false
    t.integer "last_blockheight"
    t.string "last_blockhash"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["last_blockheight"], name: "index_scanner_cursors_on_last_blockheight"
    t.index ["name"], name: "index_scanner_cursors_on_name", unique: true
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
    t.decimal "btc_amount", precision: 20, scale: 8
    t.decimal "buy_fee_pct", precision: 6, scale: 3, default: "0.0", null: false
    t.decimal "buy_fee_fixed_eur", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "sell_fee_pct", precision: 6, scale: 3, default: "0.0", null: false
    t.decimal "sell_fee_fixed_eur", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "slippage_pct", precision: 6, scale: 3, default: "0.0", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "open", null: false
    t.decimal "buy_amount_eur", precision: 20, scale: 8
    t.index ["status"], name: "index_trade_simulations_on_status"
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
    t.string "largest_output_address"
    t.integer "largest_output_vout"
    t.text "largest_output_desc"
    t.string "tier"
    t.string "flow_kind"
    t.integer "flow_confidence"
    t.string "actor_band"
    t.text "flow_reasons"
    t.jsonb "flow_scores"
    t.index ["alert_type"], name: "index_whale_alerts_on_alert_type"
    t.index ["block_height"], name: "index_whale_alerts_on_block_height"
    t.index ["block_time"], name: "index_whale_alerts_on_block_time"
    t.index ["score"], name: "index_whale_alerts_on_score"
    t.index ["tier"], name: "index_whale_alerts_on_tier"
    t.index ["txid"], name: "index_whale_alerts_on_txid", unique: true
  end

  add_foreign_key "address_links", "addresses", column: "address_a_id"
  add_foreign_key "address_links", "addresses", column: "address_b_id"
  add_foreign_key "addresses", "clusters"
  add_foreign_key "brc20_balances", "brc20_tokens"
  add_foreign_key "brc20_events", "brc20_tokens"
  add_foreign_key "brc20_token_daily_stats", "brc20_tokens"
  add_foreign_key "cluster_metrics", "clusters"
  add_foreign_key "cluster_profiles", "clusters"
  add_foreign_key "cluster_signals", "clusters"
  add_foreign_key "opsec_answers", "opsec_assessments"
  add_foreign_key "rune_balances", "rune_tokens"
  add_foreign_key "rune_events", "rune_tokens"
  add_foreign_key "rune_token_daily_stats", "rune_tokens"
  add_foreign_key "trade_simulation_points", "trade_simulations"
  add_foreign_key "vault_addresses", "vaults"
end
