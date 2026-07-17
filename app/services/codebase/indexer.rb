# app/services/codebase/indexer.rb
require "digest"

module Codebase
  class Indexer
    INCLUDE_PATTERNS = [
      "app/services/layer1/**/*.rb",
      "app/jobs/layer1/**/*.rb",

      "app/services/clusters/**/*.rb",
      "app/jobs/clusters/**/*.rb",

      "app/services/actor_profiles/**/*.rb",
      "app/jobs/actor_profiles/**/*.rb",

      "app/services/actor_labels/**/*.rb",
      "app/jobs/actor_labels/**/*.rb",

      "app/services/intelligence/**/*.rb",
      "app/services/ai/**/*.rb",
      "app/services/codebase/**/*.rb",

      "app/controllers/ai/**/*.rb",
      "app/controllers/questions/**/*.rb",
      "app/controllers/tansa_heartbeat_controller.rb",

      "app/views/questions/answers/**/*.erb",
      "app/views/ai/**/*.erb",
      "app/views/shared/_topbar.html.erb",

      "app/javascript/controllers/system_heartbeat_controller.js",
      "app/javascript/controllers/auto_refresh_controller.js",

      "app/models/code_chunk.rb",
      "app/models/block_buffer_model.rb",
      "app/models/cluster_processed_block.rb",
      "app/models/actor_profile.rb",

      "config/routes.rb",
      "db/schema.rb",
      "lib/tasks/codebase.rake"
    ].freeze

    EXCLUDE_PATTERNS = [
      "tmp/",
      "log/",
      "storage/",
      "node_modules/",
      ".git/",
      "vendor/",
      "coverage/",
      "public/assets/"
    ].freeze

    MAX_LINES = 120

    def self.call
      new.call
    end

    def call
      files.each do |path|
        index_file(path)
      end

      prune_removed_files!

      { ok: true, chunks: CodeChunk.count, files: files.size }
    end

    private

    def files
      INCLUDE_PATTERNS.flat_map { |pattern| Dir.glob(pattern) }
                      .uniq
                      .select { |path| File.file?(path) }
                      .reject { |path| EXCLUDE_PATTERNS.any? { |excluded| path.include?(excluded) } }
                      .sort
    end

    def index_file(path)
      content = File.read(path)
      chunks = content.lines.each_slice(MAX_LINES).map(&:join)

      chunks.each_with_index do |chunk, index|
        next if chunk.strip.blank?

        hash = Digest::SHA256.hexdigest("#{path}:#{index}:#{chunk}")

        existing = CodeChunk.find_by(path: path, chunk_index: index)
        next if existing&.content_hash == hash

        input = "#{path}\n\n#{chunk}".encode("UTF-8", invalid: :replace, undef: :replace, replace: "")

        puts "Embedding #{path} chunk=#{index} chars=#{input.length}"

        begin
          embedding = Ai::Embedding.call(input)
          sleep 0.15
        rescue => e
          puts
          puts "FAILED FILE: #{path}"
          puts "CHUNK: #{index}"
          puts "CHARS: #{input.length}"
          puts "ERROR: #{e.message}"
          raise
        end

        CodeChunk.find_or_initialize_by(path: path, chunk_index: index).tap do |record|
          record.content = chunk
          record.content_hash = hash
          record.embedding = embedding
          next if embedding.blank?

          unless record.save
            puts
            puts "SAVE FAILED"
            puts "FILE: #{path}"
            puts "CHUNK: #{index}"
            puts "CONTENT SIZE: #{chunk.length}"
            puts "EMBEDDING CLASS: #{embedding.class}"
            puts "EMBEDDING SIZE: #{embedding.respond_to?(:size) ? embedding.size : "n/a"}"
            puts "ERRORS: #{record.errors.full_messages.inspect}"
            raise ActiveRecord::RecordInvalid.new(record)
          end
        end
      end
    end

    def prune_removed_files!
      indexed_paths = files
      CodeChunk.where.not(path: indexed_paths).delete_all
    end
  end
end
