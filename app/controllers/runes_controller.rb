class RunesController < ApplicationController
  def index
    # Est-ce qu'on a au moins une rune en base ?
    @runes_enabled = RuneToken.exists?

    if @runes_enabled
      # Chiffres globaux
      @runes_count        = RuneToken.count
      @rune_events_count  = RuneEvent.count
      @rune_addresses_cnt = RuneBalance.distinct.count(:address)

      first_block = RuneEvent.minimum(:block_height)
      last_block  = RuneEvent.maximum(:block_height)

      @runes_first_block = first_block
      @runes_last_block  = last_block

      # Top Runes actives (par activité globale / events_count)
      @top_runes = RuneToken
        .order(events_count: :desc)
        .limit(20)

      # Derniers événements Runes (tous types confondus)
      @recent_events = RuneEvent
        .order(block_height: :desc, created_at: :desc)
        .limit(25)
    else
      @runes_count        = 0
      @rune_events_count  = 0
      @rune_addresses_cnt = 0
      @runes_first_block  = nil
      @runes_last_block   = nil
      @top_runes          = []
      @recent_events      = []
    end
  end
end
