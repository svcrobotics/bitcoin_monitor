# frozen_string_literal: true

module Blockchain
  module Flushers
    class AllFlusher
      def call
        outputs = Blockchain::Flushers::OutputFlusher.new.call
        spent_outputs = Blockchain::Flushers::SpentOutputFlusher.new.call
        status = System::BlockchainPipelineStatus.call

        {
          ok: true,
          outputs: outputs,
          spent_outputs: spent_outputs,
          status: status
        }
      end
    end
  end
end