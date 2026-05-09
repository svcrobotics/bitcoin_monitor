# frozen_string_literal: true

require "rails_helper"

RSpec.describe Blockchain::Orchestration::RequeueStuckBlocks do
  describe "#call" do
    it "requeues processing blocks whose heartbeat is too old" do
      old_block = BlockBufferModel.create!(
        height: 100,
        block_hash: "hash-100",
        status: "processing",
        processing_started_at: 30.minutes.ago,
        last_heartbeat_at: 30.minutes.ago,
        updated_at: 1.minute.ago
      )

      recent_block = BlockBufferModel.create!(
        height: 101,
        block_hash: "hash-101",
        status: "processing",
        processing_started_at: 30.minutes.ago,
        last_heartbeat_at: 1.minute.ago,
        updated_at: 30.minutes.ago
      )

      result = described_class.new(stuck_after: 15.minutes).call

      expect(result[:ok]).to eq(true)
      expect(result[:heights]).to include(100)
      expect(result[:heights]).not_to include(101)

      expect(old_block.reload.status).to eq("pending")
      expect(old_block.processing_started_at).to be_nil
      expect(old_block.last_heartbeat_at).to be_nil

      expect(recent_block.reload.status).to eq("processing")
    end
  end
end