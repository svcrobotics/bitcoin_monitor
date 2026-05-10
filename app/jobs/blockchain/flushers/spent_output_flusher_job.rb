# frozen_string_literal: true

module Blockchain
  module Flushers
    class SpentOutputFlusherJob < ApplicationJob
      queue_as :default

      def perform
        Blockchain::Flushers::SpentOutputFlusher.new.call
      end
    end
  end
end