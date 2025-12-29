# frozen_string_literal: true
module DebugTrace
  extend ActiveSupport::Concern

  included do
    helper_method :debug_enabled?
  end

  def debug_enabled?
    params[:debug].to_s == "1" || (defined?(@debug_enabled) && @debug_enabled)
  end

  def debug_steps
    @debug_steps ||= []
  end

  def debug_step(name, inputs: nil, process: nil, outputs: nil, error: nil)
    debug_steps << {
      at: Time.current.iso8601,
      name: name,
      inputs: inputs,
      process: process,
      outputs: outputs,
      error: error
    }
  end
end
