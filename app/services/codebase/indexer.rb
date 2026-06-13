# app/services/codebase/indexer.rb
require "digest"

module Codebase
  class Indexer
    INCLUDE_PATTERNS = [
      "app/**/*.rb",
      "app/**/*.erb",
      "app/**/*.js",
      "config/routes.rb",
      "db/schema.rb",
      "lib/**/*.rb"
    ].freeze

    EXCLUDE_PATTERNS = [
      "tmp/",
      "log/",
      "storage/",
      "node_modules/",
      ".git/",
      "vendor/",
      "coverage/"
    ].freeze

    MAX_LINES = 120

    def self.call
      new.call
    end

    def call
      files.each do |path|
        index_file(path)
      end

      { ok: true, chunks: CodeChunk.count }
    end

    private

    def files
      INCLUDE_PATTERNS.flat_map { |pattern| Dir.glob(pattern) }
                      .uniq
                      .reject { |path| EXCLUDE_PATTERNS.any? { |excluded| path.include?(excluded) } }
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
  end
end