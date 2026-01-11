# frozen_string_literal: true

module JournalLinksHelper
  def journal_entry_prefill_path(
    occurred_at: Time.current,
    kind: "observation",
    mood: "green",
    tags: "",
    context: "",
    body: ""
  )
    new_journal_entry_path(
      occurred_at: occurred_at.strftime("%Y-%m-%dT%H:%M"),
      kind: kind,
      mood: mood,
      tags: tags,
      context: context,
      body: body
    )
  end
end
