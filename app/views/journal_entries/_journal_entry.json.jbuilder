json.extract! journal_entry, :id, :occurred_at, :kind, :mood, :btc_price_eur, :context, :body, :tags, :created_at, :updated_at
json.url journal_entry_url(journal_entry, format: :json)
