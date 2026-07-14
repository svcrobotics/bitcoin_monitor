# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    class Gate
      OUTPUTS_KEY = Blockchain::Buffers::OutputBuffer::KEY
      SPENT_KEY = Blockchain::Buffers::SpentOutputBuffer::KEY

      def self.call
        new.call
      end

      def initialize(
        redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")),
        rpc: BitcoinRpc.new,
        work_available: WorkAvailable
      )
        @redis = redis
        @rpc = rpc
        @work_available = work_available
      end

      def call
        return disabled_result unless Config.enabled?

        buffers = {
          outputs: @redis.llen(OUTPUTS_KEY).to_i,
          spent: @redis.llen(SPENT_KEY).to_i
        }
        processing_height = BlockBufferModel.where(status: "processing").minimum(:height)
        processed_height = BlockBufferModel.where(status: "processed").maximum(:height).to_i
        cluster_processing_height =
          ClusterProcessedBlock
            .where(status: "processing")
            .minimum(:height)
        cluster_processed_height =
          ClusterProcessedBlock
            .where(status: "processed")
            .maximum(:height)
            .to_i
        bitcoin_core_height = @rpc.getblockcount.to_i
        lag = [bitcoin_core_height - processed_height, 0].max
        cluster_lag = [processed_height - cluster_processed_height, 0].max
        work_available = @work_available.call == true

        reasons = []

        unless processed_height.positive?
          reasons << "layer1_checkpoint_unavailable"
        end

        reasons << "layer1_processing" if processing_height.present?

        if processed_height.positive? &&
           lag >
           Layer1::HistoricalWorkConfig
             .max_layer1_lag_blocks
          reasons <<
            "layer1_lag_above_historical_budget"
        end

        reasons <<
          "buffers_not_empty" if
            buffers.values.any?(&:positive?)

        unless cluster_processed_height.positive?
          reasons << "cluster_checkpoint_unavailable"
        end

        reasons << "cluster_processing" if cluster_processing_height.present?

        if cluster_processed_height.positive? &&
           cluster_lag >
           Layer1::HistoricalWorkConfig
             .max_cluster_lag_blocks
          reasons <<
            "cluster_lag_above_historical_budget"
        end

        reasons << "no_eligible_checkpoint" unless work_available

        {
          ready: reasons.empty?,
          reasons: reasons,
          bitcoin_core_height: bitcoin_core_height,
          processed_height: processed_height,
          cluster_processed_height: cluster_processed_height,
          lag: lag,
          cluster_lag: cluster_lag,
          processing_height: processing_height,
          cluster_processing_height: cluster_processing_height,
          work_available: work_available,
          buffers: buffers
        }
      rescue StandardError => e
        {
          ready: false,
          reasons: ["gate_error=#{e.class}: #{e.message}"],
          error_class: e.class.name,
          error_message: e.message
        }
      end

      private

      def disabled_result
        {
          ready: false,
          reasons: ["async_sync_disabled"]
        }
      end
    end
  end
end
