# lib/tasks/codebase.rake
namespace :codebase do
  desc "Indexe le code source de Tansa"
  task index: :environment do
    pp Codebase::Indexer.call
  end

  desc "Pose une question sur le code"
  task ask: :environment do
    question = ENV.fetch("Q")
    result = Ai::CodebaseAnswerer.call(question: question)

    puts result[:answer]
    puts
    puts "Sources:"
    result[:sources].each do |source|
      puts "- #{source[:path]} ##{source[:chunk_index]}"
    end
  end
end