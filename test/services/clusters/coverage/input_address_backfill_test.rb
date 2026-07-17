# frozen_string_literal: true

require "test_helper"

module Clusters
  module Coverage
    class InputAddressBackfillTest <
      ActiveSupport::TestCase

      VALID_ADDRESS =
        "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"

      SECOND_VALID_ADDRESS =
        "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"

      test "creates missing address without creating a cluster or link" do
        height =
          9_800_000 + rand(10_000)

        create_checkpoint(height)
        create_input(
          address: VALID_ADDRESS,
          spent_height: height
        )

        assert_difference -> { Address.count }, 1 do
          assert_no_difference -> { Cluster.count } do
            assert_no_difference -> { AddressLink.count } do
              result =
                InputAddressBackfill.call(
                  from_height: height,
                  to_height: height,
                  lock: false
                )

              assert result[:ok]
              assert_equal 1, result[:valid_addresses]
              assert_equal 1, result[:addresses_upserted]
            end
          end
        end

        address =
          Address.find_by!(
            address: VALID_ADDRESS
          )

        assert_nil address.cluster_id
        assert_equal height, address.last_seen_height
      end

      test "is idempotent" do
        height =
          9_810_000 + rand(10_000)

        create_checkpoint(height)
        create_input(
          address: SECOND_VALID_ADDRESS,
          spent_height: height
        )

        InputAddressBackfill.call(
          from_height: height,
          to_height: height,
          lock: false
        )

        assert_no_difference -> { Address.count } do
          assert_no_difference -> { Cluster.count } do
            assert_no_difference -> { AddressLink.count } do
              result =
                InputAddressBackfill.call(
                  from_height: height,
                  to_height: height,
                  lock: false
                )

              assert result[:ok]
              assert_equal 0,
                result[:scanned_missing_addresses]
            end
          end
        end
      end

      test "does not consume inputs beyond the certified cluster tip" do
        height =
          9_820_000 + rand(10_000)

        create_checkpoint(height)

        create_input(
          address: VALID_ADDRESS,
          spent_height: height + 1
        )

        result =
          InputAddressBackfill.call(
            from_height: height,
            to_height: height + 1,
            lock: false
          )

        assert result[:ok]

        assert_nil(
          Address.find_by(
            address: VALID_ADDRESS
          )
        )
      end

      private

      def create_checkpoint(height)
        ClusterProcessedBlock.create!(
          height: height,
          block_hash:
            Digest::SHA256.hexdigest(
              "checkpoint-#{height}"
            ),
          status: "processed",
          processed_at: Time.current
        )
      end

      def create_input(address:, spent_height:)
        ClusterInput.create!(
          block_height:
            spent_height - 100,

          txid:
            SecureRandom.hex(32),

          vout:
            rand(1_000_000),

          address: address,

          amount_btc:
            BigDecimal("0.1"),

          spent: true,

          spent_txid:
            SecureRandom.hex(32),

          spent_block_height:
            spent_height,

          cluster_processed_at:
            Time.current
        )
      end
    end
  end
end
