# app/models/rune_balance.rb
class RuneBalance < ApplicationRecord
  belongs_to :rune_token

  # Pour être cohérent avec BRC-20, tu peux garder balance en string dans le code,
  # mais ici on est déjà en decimal DB.
end
