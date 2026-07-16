# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class TxidTest < ActiveSupport::TestCase
    test "packs and unpacks a 64 character hexadecimal txid" do
      hex =
        Digest::SHA256.hexdigest("txid-roundtrip")

      bytes =
        Txid.pack(hex)

      assert_equal 32, bytes.bytesize
      assert_equal hex, Txid.unpack(bytes)
    end

    test "rejects invalid hexadecimal txids" do
      assert_raises(ArgumentError) do
        Txid.pack("not-hex")
      end

      assert_raises(ArgumentError) do
        Txid.pack("a" * 63)
      end
    end

    test "validates bytea length exactly" do
      assert_raises(ArgumentError) do
        Txid.pack_bytes("a" * 31)
      end

      assert_equal "b" * 32, Txid.pack_bytes("b" * 32)

      assert_raises(ArgumentError) do
        Txid.pack_bytes("c" * 33)
      end
    end
  end
end
