# frozen_string_literal: true

class AddCascadeDeleteToActorLabelsClusterFk < ActiveRecord::Migration[8.0]
  def change
    remove_foreign_key :actor_labels, :clusters
    add_foreign_key :actor_labels, :clusters, on_delete: :cascade
  end
end