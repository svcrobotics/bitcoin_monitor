# frozen_string_literal: true

namespace :realtime do
  desc "Process latest Bitcoin block asynchronously"
  task process_latest_block: :environment do
    Realtime::ProcessLatestBlockJob.perform_later
    puts "[realtime] latest block job enqueued"
  end
end
