# frozen_string_literal: true

module Blockchain
  module Orchestration
    class Layer1OrchestratorJob < ApplicationJob
      queue_as :default

      def perform
        Blockchain::Orchestration::Layer1Orchestrator.new.call
      end
    end
  end
end