# frozen_string_literal: true

module Blockchain
  module Flushers
    class AllFlusherJob < ApplicationJob
      queue_as :default

      def perform
        Blockchain::Flushers::AllFlusher.new.call
      end
    end
  end
end