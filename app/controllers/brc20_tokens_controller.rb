class Brc20TokensController < ApplicationController
  def show
    tick = params[:tick].to_s.downcase

    @token = Brc20Token.find_by(tick: tick)

    if @token.nil?
      render plain: "Token introuvable : #{tick}", status: :not_found
      return
    end

    # === ON-CHAIN : infos brutes du token ===
    @max_supply        = @token.max_supply
    @mint_limit        = @token.mint_limit
    @total_minted      = @token.total_minted
    @total_transferred = @token.total_transferred
    @holders_count     = @token.holders_count
    @events_count      = @token.events_count
    @deploy_height     = @token.deploy_block_height
    @deploy_time       = @token.deploy_block_time

    # Event de deploy (pour txid, adresse déployeur, inscription)
    @deploy_event = Brc20Event
      .where(brc20_token_id: @token.id, op: "deploy")
      .order(:block_height, :id)
      .first

    # Dernière activité on-chain (dernier event connu)
    @last_event = Brc20Event
      .where(brc20_token_id: @token.id)
      .order(block_height: :desc, id: :desc)
      .first

    # Stats rapides d'activité (mints / transferts)
    stats_scope = Brc20Event.where(brc20_token_id: @token.id)

    @mints_count = stats_scope.where(op: "mint").count
    @transfers_count = stats_scope.where(op: "transfer").count

    # Optionnel : volume mint/transfert (si amount est une string décimale)
    @mint_volume =
      stats_scope.where(op: "mint").sum("amount::numeric")
    @transfer_volume =
      stats_scope.where(op: "transfer").sum("amount::numeric")

    # === OFF-CHAIN : placeholder pour plus tard ===
    # Ici on ne fait rien pour l’instant, on va juste afficher une carte vide à remplir plus tard.
  end
end
