# app/models/login_challenge.rb
class LoginChallenge < ApplicationRecord
  validates :nonce, :domain, :expires_at, presence: true

  def used?
    used_at.present?
  end

  def expired?
    Time.current >= expires_at
  end
end
