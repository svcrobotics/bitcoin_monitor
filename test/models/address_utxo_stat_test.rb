# frozen_string_literal: true

require "test_helper"

class AddressUtxoStatTest < ActiveSupport::TestCase
  test "accepts a valid inert projection stat" do
    stat =
      AddressUtxoStat.new(
        address:
          "bc1qaddressutxostatvalid000000000000000000",
        total_received_sats:
          200_000,
        current_balance_sats:
          150_000,
        live_utxo_count:
          2,
        received_output_count:
          3,
        first_received_height:
          100,
        last_received_height:
          120,
        last_changed_height:
          120,
        projection_version:
          AddressUtxoStat::PROJECTION_VERSION
      )

    assert_predicate stat, :valid?
  end

  test "requires one row per address string" do
    raw_address =
      "bc1qaddressutxostatunique00000000000000000"

    AddressUtxoStat.create!(
      address: raw_address,
      last_changed_height: 100,
      projection_version:
        AddressUtxoStat::PROJECTION_VERSION
    )

    duplicate =
      AddressUtxoStat.new(
        address: raw_address,
        last_changed_height: 101,
        projection_version:
          AddressUtxoStat::PROJECTION_VERSION
      )

    assert_not duplicate.valid?
    assert_predicate duplicate.errors[:address], :any?
  end

  test "rejects negative amounts and counters" do
    attributes = {
      address:
        "bc1qaddressutxostatnegative000000000000000",
      last_changed_height:
        100,
      projection_version:
        AddressUtxoStat::PROJECTION_VERSION
    }

    %i[
      total_received_sats
      current_balance_sats
      live_utxo_count
      received_output_count
      last_changed_height
    ].each do |attribute|
      stat =
        AddressUtxoStat.new(
          attributes.merge(
            attribute => -1
          )
        )

      assert_not stat.valid?,
        "#{attribute} should reject negative values"

      assert_predicate stat.errors[attribute], :any?
    end
  end

  test "rejects a balance greater than total received" do
    stat =
      AddressUtxoStat.new(
        address:
          "bc1qaddressutxostatbalance0000000000000000",
        total_received_sats:
          100,
        current_balance_sats:
          101,
        last_changed_height:
          100,
        projection_version:
          AddressUtxoStat::PROJECTION_VERSION
      )

    assert_not stat.valid?

    assert_predicate(
      stat.errors[:current_balance_sats],
      :any?
    )
  end

  test "rejects reversed received heights" do
    stat =
      AddressUtxoStat.new(
        address:
          "bc1qaddressutxostatreversed000000000000000",
        first_received_height:
          121,
        last_received_height:
          120,
        last_changed_height:
          121,
        projection_version:
          AddressUtxoStat::PROJECTION_VERSION
      )

    assert_not stat.valid?

    assert_predicate(
      stat.errors[:last_received_height],
      :any?
    )
  end

  test "rejects an empty address" do
    stat =
      AddressUtxoStat.new(
        address: " ",
        last_changed_height: 100,
        projection_version:
          AddressUtxoStat::PROJECTION_VERSION
      )

    assert_not stat.valid?
    assert_predicate stat.errors[:address], :any?
  end

  test "schema exposes strict check constraints" do
    names =
      ActiveRecord::Base
        .connection
        .check_constraints(
          :address_utxo_stats
        )
        .map(&:name)

    assert_includes(
      names,
      "address_utxo_stats_balance_lte_received_check"
    )

    assert_includes(
      names,
      "address_utxo_stats_received_height_order_check"
    )
  end
end
