class SystemHeartbeatController < ApplicationController
  def show
    snapshot = Layer1::HealthSnapshot.call

    render json: {
      status: snapshot[:status] || heartbeat_status(snapshot),
      generated_at: Time.current.strftime("%H:%M:%S"),

      layer1_lag: snapshot[:lag].to_i,
      outputs_buffer: snapshot.dig(:buffers, :outputs).to_i,
      spent_buffer: snapshot.dig(:buffers, :spent).to_i,

      layer1_drain: snapshot.dig(:queues, "layer1_drain").to_i,
      spent_resolve: snapshot.dig(:queues, "spent_resolve").to_i,
      flushers: snapshot.dig(:queues, "flushers").to_i,

      pipeline_state: snapshot.dig(:activity, :pipeline_state),
      last_processed_seconds_ago: snapshot.dig(:activity, :last_processed_seconds_ago),
      last_utxo_seconds_ago: snapshot.dig(:activity, :last_utxo_seconds_ago)
    }
  end

  private

  def heartbeat_status(snapshot)
    lag = snapshot[:lag].to_i
    outputs = snapshot.dig(:buffers, :outputs).to_i
    spent = snapshot.dig(:buffers, :spent).to_i
    drain = snapshot.dig(:queues, "layer1_drain").to_i
    resolve = snapshot.dig(:queues, "spent_resolve").to_i

    if lag > 24 || outputs > 50_000 || spent > 50_000 || drain > 500 || resolve > 500
      "critical"
    elsif lag > 0 || outputs > 5_000 || spent > 5_000 || drain > 50 || resolve > 50
      "warning"
    else
      "healthy"
    end
  end
end