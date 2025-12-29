class CreateLoginChallenges < ActiveRecord::Migration[8.0]
  def change
    create_table :login_challenges do |t|
      t.string   :nonce, null: false
      t.string   :domain, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at

      # Optionnel: pour audit
      t.string :signed_address
      t.string :signature_format # ex: "sparrow_legacy" / "bip322"

      t.timestamps
    end

    add_index :login_challenges, :nonce, unique: true
  end
end
