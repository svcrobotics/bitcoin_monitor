class JournalEntriesController < ApplicationController
  before_action :set_journal_entry, only: %i[show edit update destroy]

  def index
    @journal_entries = JournalEntry.order(occurred_at: :desc)
  end

  def show
  end

  def new
    @journal_entry = JournalEntry.new(journal_entry_params_from_query)
    @journal_entry.occurred_at ||= Time.current
  end

  def edit
  end

  def create
    @journal_entry = JournalEntry.new(journal_entry_params)

    if @journal_entry.save
      redirect_to @journal_entry, notice: "✅ Entrée ajoutée au journal."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @journal_entry.update(journal_entry_params)
      redirect_to @journal_entry, notice: "✅ Entrée mise à jour.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @journal_entry.destroy!
    redirect_to journal_entries_path, notice: "🗑️ Entrée supprimée.", status: :see_other
  end

  private

  def set_journal_entry
    @journal_entry = JournalEntry.find(params[:id])
  end

  def journal_entry_params
    params.require(:journal_entry).permit(:occurred_at, :kind, :mood, :btc_price_eur, :context, :body, :tags)
  end

  # Permet de pré-remplir via l’URL (new_journal_entry_path(context:..., mood:...))
  def journal_entry_params_from_query
    params.permit(:occurred_at, :kind, :mood, :btc_price_eur, :context, :body, :tags)
  end
end
