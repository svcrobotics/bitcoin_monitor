# frozen_string_literal: true

class CreateActorProfileCertificationEpochs <
  ActiveRecord::Migration[8.0]

  def change
    create_table :actor_profile_certification_epochs do |t|
      t.string :profile_version,
        null: false

      t.integer :start_height,
        null: false

      t.datetime :activated_at,
        null: false

      t.string :source,
        null: false

      t.jsonb :metadata,
        null: false,
        default: {}

      t.timestamps
    end

    add_index(
      :actor_profile_certification_epochs,
      :profile_version,
      unique: true,
      name:
        "index_actor_profile_epochs_on_version"
    )

    add_check_constraint(
      :actor_profile_certification_epochs,
      "start_height > 0",
      name:
        "actor_profile_epochs_positive_height"
    )

    add_check_constraint(
      :actor_profile_certification_epochs,
      "profile_version <> ''",
      name:
        "actor_profile_epochs_version_present"
    )

    add_check_constraint(
      :actor_profile_certification_epochs,
      "source <> ''",
      name:
        "actor_profile_epochs_source_present"
    )
  end
end
