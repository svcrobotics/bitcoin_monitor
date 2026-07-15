# frozen_string_literal: true

require "test_helper"

class AddressSpendStatTest <
  ActiveSupport::TestCase

  test "accepts a valid strict projection" do
    stat =
      AddressSpendStat.new(
        address:
          "bc1qaddressspendstatvalid" \
          "000000000000000000000",

        total_sent_sats:
          125_000_000,

        spent_inputs_count:
          3,

        first_spent_height:
          100,

        last_spent_height:
          120,

        source_height:
          120,

        projection_version:
          AddressSpendStat::
            PROJECTION_VERSION
      )

    assert_predicate stat, :valid?
  end

  test "rejects reversed spent heights" do
    stat =
      AddressSpendStat.new(
        address:
          "bc1qaddressspendstatreversed" \
          "000000000000000000",

        source_height:
          120,

        projection_version:
          AddressSpendStat::
            PROJECTION_VERSION,

        first_spent_height:
          121,

        last_spent_height:
          120
      )

    assert_not stat.valid?

    assert_predicate(
      stat.errors,
      :any?
    )
  end

  test "requires one row per address string" do
    raw_address =
      "bc1qaddressspendstatunique" \
      "00000000000000000000"

    AddressSpendStat.create!(
      address:
        raw_address,

      source_height:
        100,

      projection_version:
        AddressSpendStat::
          PROJECTION_VERSION
    )

    duplicate =
      AddressSpendStat.new(
        address:
          raw_address,

        source_height:
          101,

        projection_version:
          AddressSpendStat::
            PROJECTION_VERSION
      )

    assert_not duplicate.valid?

    assert_predicate(
      duplicate.errors[:address],
      :any?
    )
  end

  test "does not require an Address record" do
    raw_address =
      "bc1qaddressspendstandalone" \
      "0000000000000000000"

    stat =
      AddressSpendStat.create!(
        address:
          raw_address,

        source_height:
          100,

        projection_version:
          AddressSpendStat::
            PROJECTION_VERSION
      )

    assert_equal(
      raw_address,
      stat.address
    )

    assert_not(
      Address.exists?(
        address:
          raw_address
      )
    )
  end
end
