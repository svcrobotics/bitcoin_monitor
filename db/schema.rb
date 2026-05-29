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

ActiveRecord::Schema[8.0].define(version: 2026_05_29_215642) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "actor_labels", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.string "label", null: false
    t.integer "confidence", default: 0, null: false
    t.string "source", default: "cluster_profile", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "actor_profile_id"
    t.index ["actor_profile_id"], name: "index_actor_labels_on_actor_profile_id"
    t.index ["cluster_id", "label", "source"], name: "index_actor_labels_on_cluster_id_and_label_and_source", unique: true
    t.index ["cluster_id"], name: "index_actor_labels_on_cluster_id"
    t.index ["confidence"], name: "index_actor_labels_on_confidence"
    t.index ["label"], name: "index_actor_labels_on_label"
  end

  create_table "actor_metrics", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.integer "address_count", default: 0, null: false
    t.integer "total_tx_count", default: 0, null: false
    t.bigint "total_received_sats", default: 0, null: false
    t.bigint "total_sent_sats", default: 0, null: false
    t.integer "first_seen_height"
    t.integer "last_seen_height"
    t.integer "activity_span_blocks"
    t.integer "exchange_score", default: 0, null: false
    t.integer "whale_score", default: 0, null: false
    t.integer "service_score", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id"], name: "index_actor_metrics_on_cluster_id", unique: true
    t.index ["exchange_score"], name: "index_actor_metrics_on_exchange_score"
    t.index ["service_score"], name: "index_actor_metrics_on_service_score"
    t.index ["whale_score"], name: "index_actor_metrics_on_whale_score"
  end

  create_table "actor_profile_deltas", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.integer "block_height", null: false
    t.decimal "received_btc_delta", precision: 24, scale: 8, default: "0.0", null: false
    t.decimal "sent_btc_delta", precision: 24, scale: 8, default: "0.0", null: false
    t.decimal "net_btc_delta", precision: 24, scale: 8, default: "0.0", null: false
    t.integer "tx_count_delta", default: 0, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id", "block_height"], name: "index_actor_profile_deltas_on_cluster_id_and_block_height"
    t.index ["cluster_id"], name: "index_actor_profile_deltas_on_cluster_id"
    t.index ["processed_at"], name: "index_actor_profile_deltas_on_processed_at"
  end

  create_table "actor_profiles", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.decimal "balance_btc"
    t.decimal "total_received_btc"
    t.decimal "total_sent_btc"
    t.decimal "net_btc"
    t.integer "tx_count"
    t.integer "inflow_count"
    t.integer "outflow_count"
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.integer "accumulation_score"
    t.integer "distribution_score"
    t.integer "exchange_score"
    t.integer "whale_score"
    t.integer "etf_score"
    t.integer "service_score"
    t.string "classification"
    t.jsonb "traits"
    t.jsonb "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "last_computed_height"
    t.boolean "dirty", default: false, null: false
    t.string "priority"
    t.index ["classification"], name: "index_actor_profiles_on_classification"
    t.index ["cluster_id"], name: "index_actor_profiles_on_cluster_id"
    t.index ["dirty"], name: "index_actor_profiles_on_dirty"
    t.index ["last_computed_height"], name: "index_actor_profiles_on_last_computed_height"
    t.index ["priority"], name: "index_actor_profiles_on_priority"
    t.index ["updated_at"], name: "index_actor_profiles_on_updated_at"
  end

  create_table "address_flow_stats", force: :cascade do |t|
    t.string "address", null: false
    t.decimal "received_btc", precision: 24, scale: 8, default: "0.0", null: false
    t.decimal "sent_btc", precision: 24, scale: 8, default: "0.0", null: false
    t.decimal "net_btc", precision: 24, scale: 8, default: "0.0", null: false
    t.integer "tx_count", default: 0, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "cluster_id"
    t.index ["address"], name: "index_address_flow_stats_on_address", unique: true
    t.index ["cluster_id", "last_seen_at"], name: "index_address_flow_stats_on_cluster_id_and_last_seen_at"
    t.index ["cluster_id", "updated_at"], name: "index_address_flow_stats_on_cluster_id_and_updated_at"
    t.index ["cluster_id"], name: "index_address_flow_stats_on_cluster_id"
    t.index ["net_btc"], name: "index_address_flow_stats_on_net_btc"
    t.index ["received_btc"], name: "index_address_flow_stats_on_received_btc"
    t.index ["sent_btc"], name: "index_address_flow_stats_on_sent_btc"
  end

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
    t.index ["txid", "link_type"], name: "index_address_links_on_txid_and_link_type"
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
    t.index ["address", "cluster_id"], name: "index_addresses_on_address_and_cluster_id"
    t.index ["address"], name: "index_addresses_on_address", unique: true
    t.index ["cluster_id", "address"], name: "index_addresses_on_cluster_id_and_address"
    t.index ["cluster_id"], name: "index_addresses_on_cluster_id"
    t.index ["first_seen_height"], name: "index_addresses_on_first_seen_height"
    t.index ["last_seen_height"], name: "index_addresses_on_last_seen_height"
    t.index ["total_received_sats"], name: "index_addresses_on_total_received_sats"
    t.index ["total_sent_sats"], name: "index_addresses_on_total_sent_sats"
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

  create_table "block_buffers", force: :cascade do |t|
    t.integer "height", null: false
    t.string "block_hash", null: false
    t.string "previous_hash"
    t.integer "tx_count"
    t.integer "size_bytes"
    t.string "status", default: "pending", null: false
    t.datetime "block_time"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "is_orphan", default: false, null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "processing_started_at"
    t.datetime "processed_at"
    t.datetime "failed_at"
    t.datetime "last_heartbeat_at"
    t.integer "duration_ms"
    t.integer "rpc_duration_ms"
    t.integer "parse_duration_ms"
    t.integer "db_duration_ms"
    t.integer "flush_duration_ms"
    t.string "error_class"
    t.text "error_message"
    t.index ["block_hash"], name: "index_block_buffers_on_block_hash", unique: true
    t.index ["failed_at"], name: "index_block_buffers_on_failed_at"
    t.index ["height", "status"], name: "index_block_buffers_on_height_and_status"
    t.index ["height"], name: "index_block_buffers_on_height"
    t.index ["is_orphan", "height"], name: "index_block_buffers_on_is_orphan_and_height"
    t.index ["last_heartbeat_at"], name: "index_block_buffers_on_last_heartbeat_at"
    t.index ["processed_at"], name: "index_block_buffers_on_processed_at"
    t.index ["processing_started_at"], name: "index_block_buffers_on_processing_started_at"
    t.index ["status"], name: "index_block_buffers_on_status"
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
    t.index ["market", "timeframe", "open_time"], name: "index_btc_candles_dashboard_lookup", order: { open_time: :desc }
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

  create_table "cluster_activity_states", force: :cascade do |t|
    t.bigint "cluster_id", null: false
    t.integer "last_seen_height"
    t.datetime "last_seen_at"
    t.integer "last_active_height"
    t.datetime "last_active_at"
    t.integer "inactive_blocks"
    t.integer "inactive_seconds"
    t.integer "activity_count"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id"], name: "index_cluster_activity_states_on_cluster_id"
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

  create_table "cluster_pipeline_events", force: :cascade do |t|
    t.string "event"
    t.integer "height"
    t.jsonb "payload"
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
    t.index ["cluster_id"], name: "index_cluster_profiles_on_cluster_id", unique: true
    t.index ["updated_at"], name: "index_cluster_profiles_on_updated_at"
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

  create_table "edges", force: :cascade do |t|
    t.string "txid", null: false
    t.string "address_a", null: false
    t.string "address_b", null: false
    t.integer "block_height"
    t.string "block_hash"
    t.datetime "block_time"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["address_a", "address_b"], name: "index_edges_on_address_a_and_address_b"
    t.index ["block_height"], name: "index_edges_on_block_height"
    t.index ["txid", "address_a", "address_b"], name: "index_edges_unique_triplet", unique: true
    t.index ["txid"], name: "index_edges_on_txid"
  end

  create_table "events", force: :cascade do |t|
    t.string "event_type", null: false
    t.string "txid"
    t.integer "block_height"
    t.string "block_hash"
    t.datetime "block_time"
    t.jsonb "data", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["block_hash"], name: "index_events_on_block_hash"
    t.index ["block_height"], name: "index_events_on_block_height"
    t.index ["data"], name: "index_events_on_data", using: :gin
    t.index ["event_type"], name: "index_events_on_event_type"
    t.index ["txid"], name: "index_events_on_txid"
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

  create_table "exchange_core_flow_days", force: :cascade do |t|
    t.date "day", null: false
    t.decimal "inflow_btc", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "outflow_btc", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "netflow_btc", precision: 18, scale: 8, default: "0.0", null: false
    t.integer "events_count", default: 0, null: false
    t.string "source", default: "actor_graph_core", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_exchange_core_flow_days_on_day", unique: true
  end

  create_table "exchange_core_flow_events", force: :cascade do |t|
    t.integer "block_height", null: false
    t.string "block_hash"
    t.string "txid", null: false
    t.string "address", null: false
    t.bigint "cluster_id"
    t.string "direction", null: false
    t.decimal "amount_btc", precision: 18, scale: 8, default: "0.0", null: false
    t.datetime "event_time"
    t.string "source", default: "actor_graph", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["address"], name: "index_exchange_core_flow_events_on_address"
    t.index ["block_height"], name: "index_exchange_core_flow_events_on_block_height"
    t.index ["cluster_id"], name: "index_exchange_core_flow_events_on_cluster_id"
    t.index ["direction"], name: "index_exchange_core_flow_events_on_direction"
    t.index ["event_time"], name: "index_exchange_core_flow_events_on_event_time"
    t.index ["txid", "address", "direction"], name: "idx_on_txid_address_direction_bbf0aea31e", unique: true
    t.index ["txid"], name: "index_exchange_core_flow_events_on_txid"
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
    t.index ["updated_at"], name: "index_exchange_observed_utxos_on_updated_at"
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

  create_table "macro_indicators", force: :cascade do |t|
    t.string "source", null: false
    t.string "code", null: false
    t.date "observed_on", null: false
    t.decimal "value", precision: 20, scale: 8, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code", "observed_on"], name: "index_macro_indicators_on_code_and_observed_on"
    t.index ["source", "code", "observed_on"], name: "index_macro_indicators_on_source_and_code_and_observed_on", unique: true
  end

  create_table "market_predictions", force: :cascade do |t|
    t.string "source", null: false
    t.string "indicator", null: false
    t.string "direction", null: false
    t.integer "confidence", default: 50, null: false
    t.date "predicted_on", null: false
    t.date "target_on", null: false
    t.decimal "btc_price_at_prediction", precision: 20, scale: 8
    t.decimal "btc_price_at_target", precision: 20, scale: 8
    t.decimal "performance_pct", precision: 10, scale: 4
    t.string "result"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["direction"], name: "index_market_predictions_on_direction"
    t.index ["result"], name: "index_market_predictions_on_result"
    t.index ["source", "indicator", "predicted_on", "target_on"], name: "idx_on_source_indicator_predicted_on_target_on_696ff8ece9", unique: true
  end

  create_table "market_signals", force: :cascade do |t|
    t.string "source", null: false
    t.string "indicator", null: false
    t.string "direction", null: false
    t.integer "confidence", default: 50, null: false
    t.date "observed_on", null: false
    t.text "reason"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["direction"], name: "index_market_signals_on_direction"
    t.index ["indicator", "observed_on"], name: "index_market_signals_on_indicator_and_observed_on"
    t.index ["source", "indicator", "observed_on"], name: "index_market_signals_on_source_and_indicator_and_observed_on", unique: true
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

  create_table "question_definitions", force: :cascade do |t|
    t.string "key", null: false
    t.string "module_name", null: false
    t.string "tier", null: false
    t.text "question", null: false
    t.string "intent", null: false
    t.string "answer_service", null: false
    t.string "historical_path"
    t.boolean "active", default: true, null: false
    t.integer "position", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_question_definitions_on_active"
    t.index ["intent"], name: "index_question_definitions_on_intent"
    t.index ["key"], name: "index_question_definitions_on_key", unique: true
    t.index ["module_name", "tier", "position"], name: "idx_on_module_name_tier_position_c1ea07863e"
    t.index ["module_name"], name: "index_question_definitions_on_module_name"
    t.index ["tier"], name: "index_question_definitions_on_tier"
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

  create_table "system_snapshots", force: :cascade do |t|
    t.string "name", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "captured_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name", "captured_at"], name: "index_system_snapshots_on_name_and_captured_at"
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

  create_table "tx_outputs", force: :cascade do |t|
    t.string "txid", null: false
    t.integer "vout", null: false
    t.string "address"
    t.decimal "amount_btc", precision: 20, scale: 8
    t.integer "block_height"
    t.string "block_hash"
    t.datetime "block_time"
    t.boolean "spent", default: false, null: false
    t.string "spent_txid"
    t.integer "spent_block_height"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["address", "block_time"], name: "index_tx_outputs_on_address_and_block_time"
    t.index ["address", "spent_block_height"], name: "index_tx_outputs_on_address_and_spent_block_height"
    t.index ["address"], name: "index_tx_outputs_on_address"
    t.index ["block_height"], name: "index_tx_outputs_on_block_height"
    t.index ["spent"], name: "index_tx_outputs_on_spent"
    t.index ["spent_block_height", "spent_txid"], name: "index_tx_outputs_on_spent_block_height_and_spent_txid"
    t.index ["spent_txid", "address"], name: "index_tx_outputs_on_spent_txid_and_address"
    t.index ["spent_txid"], name: "index_tx_outputs_on_spent_txid"
    t.index ["txid", "vout"], name: "index_tx_outputs_on_txid_and_vout", unique: true
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
    t.index ["created_at"], name: "index_whale_alerts_on_created_at"
    t.index ["score"], name: "index_whale_alerts_on_score"
    t.index ["tier"], name: "index_whale_alerts_on_tier"
    t.index ["txid"], name: "index_whale_alerts_on_txid", unique: true
  end

  create_table "whale_core_flow_days", force: :cascade do |t|
    t.date "day"
    t.decimal "inflow_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "outflow_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "netflow_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.integer "events_count", default: 0, null: false
    t.string "source"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_whale_core_flow_days_on_day", unique: true
  end

  create_table "whale_core_flow_events", force: :cascade do |t|
    t.integer "block_height"
    t.string "block_hash"
    t.string "txid"
    t.string "address"
    t.integer "cluster_id"
    t.string "direction"
    t.decimal "amount_btc", precision: 20, scale: 8, default: "0.0", null: false
    t.datetime "event_time"
    t.string "source"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["block_height"], name: "index_whale_core_flow_events_on_block_height"
    t.index ["cluster_id"], name: "index_whale_core_flow_events_on_cluster_id"
    t.index ["event_time"], name: "index_whale_core_flow_events_on_event_time"
    t.index ["txid", "address", "direction"], name: "index_whale_core_flow_events_on_txid_and_address_and_direction", unique: true
  end

  add_foreign_key "actor_labels", "clusters", on_delete: :cascade
  add_foreign_key "actor_metrics", "clusters", on_delete: :cascade
  add_foreign_key "actor_profile_deltas", "clusters"
  add_foreign_key "actor_profiles", "clusters"
  add_foreign_key "address_links", "addresses", column: "address_a_id"
  add_foreign_key "address_links", "addresses", column: "address_b_id"
  add_foreign_key "addresses", "clusters"
  add_foreign_key "brc20_balances", "brc20_tokens"
  add_foreign_key "brc20_events", "brc20_tokens"
  add_foreign_key "brc20_token_daily_stats", "brc20_tokens"
  add_foreign_key "cluster_activity_states", "clusters"
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
