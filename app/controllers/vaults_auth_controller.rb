class VaultsAuthController < ApplicationController
  include VaultsAuthentication

  # page avec instructions Sparrow + formulaire signature
  def new
  end

  # génère un message à signer (nonce + TTL)
  def challenge
    nonce  = SecureRandom.hex(32)
    domain = request.host

    c = LoginChallenge.create!(
      nonce: nonce,
      domain: domain,
      expires_at: 5.minutes.from_now
    )

    message = build_message(domain: c.domain, nonce: c.nonce, expires_at: c.expires_at)

    c.update!(message_text: message)

    render json: { challenge_id: c.id, message: message }
  end

  # vérifie signature + ouvre session
  def verify
    challenge = LoginChallenge.find(params[:challenge_id])

    if challenge.used? || challenge.expired?
      redirect_to "/vaults/login", alert: "Challenge expiré ou déjà utilisé." and return
    end

    address   = params[:address].to_s.strip
    signature = params[:signature].to_s.strip
    message   = challenge.message_text.to_s   # <= clé du succès

    ok = BitcoinMessageVerifier.verify(address: address, message: message, signature: signature)

    unless ok
      redirect_to "/vaults/login", alert: "Signature invalide." and return
    end

    challenge.update!(used_at: Time.current, signed_address: address)

    session[:vaults_user_id] = 1
    redirect_to "/vaults", notice: "Connecté aux vaults."
  end

  def destroy
    vaults_sign_out!
    redirect_to "/", notice: "Déconnecté des vaults."
  end

  private

  def build_message(domain:, nonce:, expires_at:)
    # Message stable = important (il doit être IDENTIQUE côté verify)
    <<~MSG
      Bitcoin Monitor Vaults Authentication

      Domain: #{domain}
      Nonce: #{nonce}
      Expires At: #{expires_at.utc.iso8601}

      I am proving control of my Bitcoin key to access /vaults.
      No funds will be moved.
    MSG
  end
end
