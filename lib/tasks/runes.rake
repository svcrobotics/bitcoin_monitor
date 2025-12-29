# lib/tasks/runes.rake
namespace :runes do
  desc "Scan une plage de blocs pour les événements Runes"
  task scan: :environment do
    from = ENV["FROM"]&.to_i
    to   = ENV["TO"]&.to_i

    if from.nil? || to.nil? || from <= 0 || to <= 0
      puts "Usage : FROM=926000 TO=926168 rails runes:scan"
      exit 1
    end

    puts "[Runes] Scan des blocs #{from}..#{to}"
    RunesIndexer.new.scan_range(from_block: from, to_block: to)
    puts "[Runes] Terminé."
  end
end
