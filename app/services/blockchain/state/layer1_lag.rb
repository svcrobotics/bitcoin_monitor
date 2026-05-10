# frozen_string_literal: true

module Blockchain
  module State
    class Layer1Lag
      def self.call
        best_height = BlockBufferModel.maximum(:height).to_i
        processed_height = BlockBufferModel.where(status: "processed").maximum(:height).to_i

        best_height - processed_height
      end
    end
  end
end
