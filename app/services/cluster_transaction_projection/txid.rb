# frozen_string_literal: true

module ClusterTransactionProjection
  module Txid
    HEX_PATTERN = /\A\h{64}\z/

    module_function

    def pack(hex)
      value = hex.to_s

      unless value.match?(HEX_PATTERN)
        raise ArgumentError, "txid must be 64 hex characters"
      end

      [value.downcase].pack("H*")
    end

    def pack_bytes(bytes)
      value = bytes.to_s.b
      validate_bytes!(value)
      value
    end

    def unpack(bytes)
      value = bytes.to_s.b
      validate_bytes!(value)
      value.unpack1("H*")
    end

    def normalize(value)
      return pack(value) if value.to_s.match?(HEX_PATTERN)

      pack_bytes(value)
    end

    def validate_bytes!(bytes)
      return true if bytes.bytesize == 32

      raise ArgumentError, "txid bytea must be 32 bytes"
    end
  end
end
