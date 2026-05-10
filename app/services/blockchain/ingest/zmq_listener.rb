# frozen_string_literal: true

require "ffi-rzmq"

module Blockchain
  module Ingest
    class ZmqListener
      ZMQ_ENDPOINT = ENV.fetch("BITCOIN_ZMQ_BLOCK", "tcp://127.0.0.1:28332")
      TOPIC = "hashblock"

      def initialize(logger: Rails.logger)
        @logger = logger
      end

      def run
        @logger.info("[zmq] starting listener #{ZMQ_ENDPOINT}")

        setup_socket!

        loop do
          topic, payload = receive_message
          next unless topic == TOPIC

          block_hash = decode(payload)
          handle_block(block_hash)
        end

      rescue => e
        @logger.error("[zmq] crash #{e.class}: #{e.message}")
        @logger.error(e.backtrace.join("\n"))
        sleep 1
        retry
      ensure
        close!
      end

      private

      def setup_socket!
        @context = ZMQ::Context.new
        @socket = @context.socket(ZMQ::SUB)

        @socket.connect(ZMQ_ENDPOINT)
        @socket.setsockopt(ZMQ::SUBSCRIBE, TOPIC)

        @logger.info("[zmq] connected")
      end

      def receive_message
        topic = ""
        payload = ""

        @socket.recv_string(topic)
        @socket.recv_string(payload)

        [topic, payload]
      end

      def decode(payload)
        return payload.reverse.unpack1("H*") if payload.bytesize == 32
        payload
      end

      def handle_block(block_hash)
        @logger.info("[zmq] block #{block_hash}")

        Blockchain::Jobs::BlockIngestJob.perform_async(block_hash)
      end

      def close!
        @socket&.close
        @context&.terminate
      end
    end
  end
end