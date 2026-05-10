Rails.application.config.to_prepare do
  Blockchain::Events::EventEmitter.reset!

  builder = Blockchain::Events::EventBuilder.new
  edge_builder = Blockchain::Edges::EdgeBuilder.new
  spent_marker = Blockchain::Utxo::SpentMarker.new

  # On persiste seulement les événements importants.
  Blockchain::Events::EventEmitter.subscribe(:multi_input_edge) do |payload|
    builder.call(:multi_input_edge, payload)
    edge_builder.call(payload)
  end

  # On ne persiste pas input_seen, mais on met à jour l'UTXO.
  Blockchain::Events::EventEmitter.subscribe(:input_seen) do |payload|
    spent_marker.call(payload)
  end
end