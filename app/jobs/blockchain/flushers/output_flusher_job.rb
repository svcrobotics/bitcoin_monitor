# frozen_string_literal: true

module Blockchain
  module Flushers
    class OutputFlusherJob < ApplicationJob
      queue_as :default

      def perform
        Blockchain::Flushers::OutputFlusher.new.call
      end
    end
  end
end