# frozen_string_literal: true

require "json"
require "set"

module Layer1
  module Audit
    class OperationalEventRecorder
      MAX_METADATA_BYTES = 4_096
      MAX_STRING_BYTES = 255
      SENSITIVE_METADATA_KEYS = Set.new(%w[
        token
        redis_token
        redis_key
        full_redis_key
        password
        secret
        backtrace
        error_message
        payload
        arguments
        job_arguments
        args
      ]).freeze
      CLASS_NAME_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
      INTEGER_PATTERN = /\A[+-]?\d+\z/

      class InvalidMetadata < ArgumentError; end

      class << self
        def call(event_type:, severity:, audited_height: nil, defer_attempt: nil,
          sidekiq_jid: nil, error_class: nil, occurred_at: Time.current, metadata: {})
          normalized_metadata = normalize_metadata(metadata)
          enforce_metadata_size!(normalized_metadata)

          Layer1AuditOperationalEvent.create!(
            event_type: normalize_required_string(event_type),
            severity: normalize_required_string(severity),
            audited_height: normalize_optional_integer(audited_height, field: :audited_height),
            defer_attempt: normalize_optional_integer(defer_attempt, field: :defer_attempt),
            sidekiq_jid: normalize_optional_string(sidekiq_jid, field: :sidekiq_jid),
            error_class: normalize_error_class(error_class),
            occurred_at: occurred_at,
            metadata: normalized_metadata
          )
        end

        private

        def normalize_required_string(value)
          String(value).strip
        end

        def normalize_optional_integer(value, field:)
          return if value.nil?
          return value if value.is_a?(Integer)

          unless value.is_a?(String) && INTEGER_PATTERN.match?(value.strip)
            raise ArgumentError, "#{field} must be an integer"
          end

          Integer(value.strip, 10)
        end

        def normalize_optional_string(value, field:)
          return if value.nil?

          normalized = String(value).strip
          return if normalized.empty?

          unless normalized.valid_encoding? && !normalized.include?("\0") && normalized.bytesize <= MAX_STRING_BYTES
            raise ArgumentError, "#{field} is invalid or too long"
          end

          normalized
        end

        def normalize_error_class(value)
          return if value.nil?

          name = case value
          when Exception
            value.class.name
          when Class, Module
            value.name
          else
            normalize_optional_string(value, field: :error_class)
          end

          unless name && CLASS_NAME_PATTERN.match?(name)
            raise ArgumentError, "error_class must be a class name"
          end

          name
        end

        def normalize_metadata(metadata)
          unless metadata.is_a?(Hash)
            raise InvalidMetadata, "metadata must be a JSON object"
          end

          normalize_json_value(metadata, seen: Set.new)
        end

        def normalize_json_value(value, seen:)
          case value
          when Hash
            with_cycle_guard(value, seen) do
              value.each_with_object({}) do |(key, nested_value), normalized|
                normalized_key = normalize_metadata_key(key)
                reject_sensitive_key!(normalized_key)
                raise InvalidMetadata, "metadata contains duplicate keys" if normalized.key?(normalized_key)

                normalized[normalized_key] = normalize_json_value(nested_value, seen: seen)
              end
            end
          when Array
            with_cycle_guard(value, seen) do
              value.map { |nested_value| normalize_json_value(nested_value, seen: seen) }
            end
          when String
            raise InvalidMetadata, "metadata contains invalid text" unless value.valid_encoding? && !value.include?("\0")

            value.dup
          when Integer, TrueClass, FalseClass, NilClass
            value
          when Float
            raise InvalidMetadata, "metadata contains a non-finite number" unless value.finite?

            value
          else
            raise InvalidMetadata, "metadata contains a non-JSON value"
          end
        end

        def with_cycle_guard(value, seen)
          object_id = value.object_id
          raise InvalidMetadata, "metadata contains a cycle" if seen.include?(object_id)

          seen.add(object_id)
          yield
        ensure
          seen.delete(object_id) if object_id
        end

        def normalize_metadata_key(key)
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise InvalidMetadata, "metadata keys must be strings"
          end

          normalized = key.to_s
          raise InvalidMetadata, "metadata contains an invalid key" unless normalized.valid_encoding? && !normalized.include?("\0")

          normalized
        end

        def reject_sensitive_key!(key)
          normalized = key.downcase.tr("-", "_")
          return unless SENSITIVE_METADATA_KEYS.include?(normalized)

          raise InvalidMetadata, "metadata contains a forbidden key"
        end

        def enforce_metadata_size!(metadata)
          return if JSON.generate(metadata).bytesize <= MAX_METADATA_BYTES

          raise InvalidMetadata, "metadata exceeds #{MAX_METADATA_BYTES} bytes"
        end
      end
    end
  end
end
