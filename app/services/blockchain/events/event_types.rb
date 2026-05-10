# frozen_string_literal: true

module Blockchain
  module Events
    module EventTypes
      TX_SEEN = :tx_seen
      INPUT_SEEN = :input_seen
      OUTPUT_CREATED = :output_created
      MULTI_INPUT_EDGE = :multi_input_edge

      ALL = [
        TX_SEEN,
        INPUT_SEEN,
        OUTPUT_CREATED,
        MULTI_INPUT_EDGE
      ].freeze
    end
  end
end