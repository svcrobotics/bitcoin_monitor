# frozen_string_literal: true

class TxOutputsRetentionJob < ApplicationJob
  queue_as :low

  RETENTION_DAYS = ENV.fetch("TX_OUTPUTS_RETENTION_DAYS", "14").to_i
  BATCH_SIZE = ENV.fetch("TX_OUTPUTS_RETENTION_BATCH_SIZE", "50000").to_i

  def perform
    cutoff = RETENTION_DAYS.days.ago
    deleted = 0

    loop do
      ids = TxOutput
        .where("block_time < ?", cutoff)
        .limit(BATCH_SIZE)
        .pluck(:id)

      break if ids.empty?

      count = TxOutput.where(id: ids).delete_all
      deleted += count

      Rails.logger.info(
        "[tx_outputs_retention] deleted=#{deleted} cutoff=#{cutoff}"
      )
    end

    Rails.logger.info(
      "[tx_outputs_retention] done deleted=#{deleted} retention_days=#{RETENTION_DAYS}"
    )

    { ok: true, deleted: deleted, retention_days: RETENTION_DAYS }
  end
end
