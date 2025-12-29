# db/migrate/20251203120000_create_feature_requests.rb
class CreateFeatureRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :feature_requests do |t|
      t.string  :title,       null: false
      t.text    :description, null: false
      t.string  :email        # pour recontacter la personne
      t.integer :amount_sats, null: false, default: 0

      t.string  :status,      null: false, default: "pending" 
      # pending / awaiting_payment / paid / in_progress / done / rejected

      t.string  :btcpay_invoice_id
      t.string  :btcpay_checkout_url
      t.datetime :paid_at

      t.timestamps
    end
  end
end
