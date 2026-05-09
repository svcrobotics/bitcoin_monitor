# frozen_string_literal: true

require "rails_helper"

RSpec.describe Blockchain::Orchestration::RequeueStuckBlocks do
  describe "#call" do
    it "requeues old processing blocks" do
      old_block = BlockBufferModel.create!(
        height: 100,
        block_hash: "hash-100",
        status: "processing",
        processing_started_at: 30.minutes.ago,
        last_heartbeat_at: 30.minutes.ago,
        updated_at: 30.minutes.ago,
        created_at: 30.minutes.ago
      )

      recent_block = BlockBufferModel.create!(
        height: 101,
        block_hash: "hash-101",
        status: "processing",
        processing_started_at: 1.minute.ago,
        last_heartbeat_at: 1.minute.ago,
        updated_at: 1.minute.ago,
        created_at: 1.minute.ago
      )

      result = described_class.new.call

      expect(result[:ok]).to eq(true)

      expect(old_block.reload.status).to eq("pending")
      expect(recent_block.reload.status).to eq("processing")
    end
  end
end