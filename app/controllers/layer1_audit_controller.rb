# frozen_string_literal: true

class Layer1AuditController < ApplicationController
  def show
    @last_audits = Layer1AuditRun.order(created_at: :desc).limit(20)
    @last_audit = @last_audits.first
  end

  def run
    heights = BlockBufferModel
                .where(status: "processed")
                .order(height: :desc)
                .offset(5)
                .limit(10)
                .pluck(:height)

    heights.each do |height|
      Layer1::AuditBlock.call(height: height)
    end

    last_audit = Layer1AuditRun.order(created_at: :desc).first
    last_audits = Layer1AuditRun.order(created_at: :desc).limit(10)

    render turbo_stream: turbo_stream.replace(
      "layer1_audit_panel",
      partial: "layer1_audit/audit_panel",
      locals: {
        last_audit: last_audit,
        last_audits: last_audits
      }
    )
  end
end
