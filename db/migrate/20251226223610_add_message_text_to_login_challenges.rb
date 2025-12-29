class AddMessageTextToLoginChallenges < ActiveRecord::Migration[8.0]
  def change
    add_column :login_challenges, :message_text, :text
  end
end
