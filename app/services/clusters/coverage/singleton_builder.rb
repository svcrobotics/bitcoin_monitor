# frozen_string_literal: true

require "bech32"
require "digest"

module Clusters
  module Coverage
    class SingletonBuilder
      DEFAULT_BATCH_SIZE = 1_000

      BASE58_ALPHABET =
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
          .freeze

      BASE58_INDEX =
        BASE58_ALPHABET
          .chars
          .each_with_index
          .to_h
          .freeze

      BASE58_VERSIONS =
        [
          0x00, # mainnet P2PKH
          0x05, # mainnet P2SH
          0x6f, # testnet P2PKH
          0xc4  # testnet P2SH
        ].freeze

      BECH32_HRPS =
        %w[
          bc
          tb
          bcrt
        ].freeze

      def self.call(
        batch_size: DEFAULT_BATCH_SIZE,
        after_id: nil
      )
        new(
          batch_size: batch_size,
          after_id: after_id
        ).call
      end

      def initialize(
        batch_size: DEFAULT_BATCH_SIZE,
        after_id: nil
      )
        @batch_size =
          [
            batch_size.to_i,
            1
          ].max

        @after_id = after_id&.to_i
      end

      def call
        rows =
          load_rows

        valid_addresses =
          rows
            .map(&:second)
            .select { |address| valid_bitcoin_address?(address) }

        invalid_addresses_count =
          rows.size - valid_addresses.size

        ensure_result =
          if valid_addresses.empty?
            empty_ensure_result
          else
            Clusters::EnsureAddressClusters.call(
              addresses: valid_addresses,
              mark_dirty: false
            )
          end

        updated =
          ensure_result[:updated].to_i

        {
          ok: true,
          scanned: rows.size,
          valid_addresses: valid_addresses.size,
          invalid_addresses: invalid_addresses_count,
          updated: updated,
          singleton_clusters_created:
            ensure_result[:clusters].to_i,
          ignored_already_clustered:
            valid_addresses.size - updated,
          last_address_id:
            rows.last&.first
        }
      end

      private

      attr_reader :batch_size, :after_id

      def load_rows
        scope =
          Address
            .where(cluster_id: nil)
            .where.not(address: [nil, ""])

        if after_id.present?
          scope =
            scope.where(
              "id > ?",
              after_id
            )
        end

        scope
          .order(:id)
          .limit(batch_size)
          .pluck(:id, :address)
      end

      def empty_ensure_result
        {
          ok: true,
          updated: 0,
          clusters: 0
        }
      end

      def valid_bitcoin_address?(address)
        value =
          address.to_s

        return false if value.blank?
        return false unless value == value.strip

        valid_base58_address?(value) ||
          valid_bech32_address?(value)
      end

      def valid_base58_address?(value)
        decoded =
          base58_decode(value)

        return false if decoded.blank?
        return false if decoded.bytesize < 5

        payload =
          decoded.byteslice(
            0,
            decoded.bytesize - 4
          )

        checksum =
          decoded.byteslice(
            decoded.bytesize - 4,
            4
          )

        return false unless BASE58_VERSIONS.include?(payload.bytes.first)

        expected_checksum =
          Digest::SHA256
            .digest(
              Digest::SHA256.digest(payload)
            )
            .byteslice(0, 4)

        checksum == expected_checksum
      end

      def base58_decode(value)
        number = 0

        value.each_char do |character|
          index =
            BASE58_INDEX[character]

          return nil if index.nil?

          number =
            (number * 58) + index
        end

        hex =
          number.to_s(16)

        hex =
          "0#{hex}" if hex.length.odd?

        bytes =
          [hex].pack("H*")

        leading_zeroes =
          value[/\A1*/].to_s.length

        ("\x00".b * leading_zeroes) + bytes
      end

      def valid_bech32_address?(value)
        return false if value.downcase != value && value.upcase != value

        decoded =
          Bech32.decode(
            value.downcase
          )

        return false if decoded.blank?

        hrp, data, spec = decoded
        witness_version = data.first
        witness_program =
          Bech32.convert_bits(
            data.drop(1),
            5,
            8,
            false
          )

        return false unless BECH32_HRPS.include?(hrp)
        return false if witness_version.nil?
        return false if witness_version > 16
        return false if witness_program.blank?
        return false unless (2..40).cover?(witness_program.length)

        if witness_version.zero?
          return false unless spec == Bech32::Encoding::BECH32
          return false unless [20, 32].include?(witness_program.length)
        else
          return false unless spec == Bech32::Encoding::BECH32M
        end

        true
      end
    end
  end
end
