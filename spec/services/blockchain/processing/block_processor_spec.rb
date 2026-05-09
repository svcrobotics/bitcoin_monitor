# frozen_string_literal: true

require "rails_helper"

RSpec.describe Blockchain::Processing::BlockProcessor do
  describe "#call" do
    it "processes a block and stores processing metrics" do
      block_buffer = BlockBufferModel.create!(
        height: 300,
        block_hash: "block-hash-300",
        status: "enqueued"
      )

      rpc = instance_double(BitcoinRpc)
      tx_processor = instance_double(Blockchain::Processing::TxProcessor)

      block = {
        "hash" => "block-hash-300",
        "time" => Time.current.to_i,
        "tx" => [
          { "txid" => "tx-1" },
          { "txid" => "tx-2" }
        ]
      }

      allow(rpc).to receive(:getblock).with("block-hash-300", 2).and_return(block)
      allow(tx_processor).to receive(:call).and_return({ ok: true })

      result =
        described_class.new(
          rpc: rpc,
          tx_processor: tx_processor,
          flush_after_block: false
        ).call(block_buffer)

      expect(result[:ok]).to eq(true)
      expect(result[:txs]).to eq(2)
      expect(result[:errors]).to eq(0)

      block_buffer.reload

      expect(block_buffer.status).to eq("processed")
      expect(block_buffer.attempts).to eq(1)
      expect(block_buffer.processed_at).to be_present
      expect(block_buffer.failed_at).to be_nil
      expect(block_buffer.error_class).to be_nil

      expect(block_buffer.duration_ms).to be_present
      expect(block_buffer.rpc_duration_ms).to be_present
      expect(block_buffer.parse_duration_ms).to be_present
      expect(block_buffer.flush_duration_ms).to be_nil

      expect(tx_processor).to have_received(:call).twice
    end
  end
end