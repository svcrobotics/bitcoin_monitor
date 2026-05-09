# frozen_string_literal: true

require "rails_helper"
require "sidekiq/testing"

RSpec.describe Blockchain::State::ProcessingRunner do
  before do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
  end

  describe "#call" do
    it "enqueues pending blocks up to the configured limit" do
      BlockBufferModel.create!(
        height: 200,
        block_hash: "hash-200",
        status: "pending"
      )

      BlockBufferModel.create!(
        height: 201,
        block_hash: "hash-201",
        status: "pending"
      )

      BlockBufferModel.create!(
        height: 202,
        block_hash: "hash-202",
        status: "pending"
      )

      result = described_class.new.call(limit: 2)

      expect(result[:enqueued]).to eq(2)
      expect(result[:selected]).to eq(2)
      expect(result[:limit]).to eq(2)

      expect(BlockBufferModel.find_by(height: 200).status).to eq("enqueued")
      expect(BlockBufferModel.find_by(height: 201).status).to eq("enqueued")
      expect(BlockBufferModel.find_by(height: 202).status).to eq("pending")

      expect(Blockchain::Jobs::BlockProcessJob.jobs.size).to eq(2)
      expect(Blockchain::Jobs::BlockProcessJob.jobs.map { |job| job["args"].first }).to contain_exactly(200, 201)
    end
  end
end