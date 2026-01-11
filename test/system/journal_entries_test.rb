require "application_system_test_case"

class JournalEntriesTest < ApplicationSystemTestCase
  setup do
    @journal_entry = journal_entries(:one)
  end

  test "visiting the index" do
    visit journal_entries_url
    assert_selector "h1", text: "Journal entries"
  end

  test "should create journal entry" do
    visit journal_entries_url
    click_on "New journal entry"

    fill_in "Body", with: @journal_entry.body
    fill_in "Btc price eur", with: @journal_entry.btc_price_eur
    fill_in "Context", with: @journal_entry.context
    fill_in "Kind", with: @journal_entry.kind
    fill_in "Mood", with: @journal_entry.mood
    fill_in "Occurred at", with: @journal_entry.occurred_at
    fill_in "Tags", with: @journal_entry.tags
    click_on "Create Journal entry"

    assert_text "Journal entry was successfully created"
    click_on "Back"
  end

  test "should update Journal entry" do
    visit journal_entry_url(@journal_entry)
    click_on "Edit this journal entry", match: :first

    fill_in "Body", with: @journal_entry.body
    fill_in "Btc price eur", with: @journal_entry.btc_price_eur
    fill_in "Context", with: @journal_entry.context
    fill_in "Kind", with: @journal_entry.kind
    fill_in "Mood", with: @journal_entry.mood
    fill_in "Occurred at", with: @journal_entry.occurred_at.to_s
    fill_in "Tags", with: @journal_entry.tags
    click_on "Update Journal entry"

    assert_text "Journal entry was successfully updated"
    click_on "Back"
  end

  test "should destroy Journal entry" do
    visit journal_entry_url(@journal_entry)
    accept_confirm { click_on "Destroy this journal entry", match: :first }

    assert_text "Journal entry was successfully destroyed"
  end
end
