puts "🌱 Seeding guides..."

path = Rails.root.join("db/seeds/guides/security.md")
content = File.read(path)

g = Guide.find_or_initialize_by(
  slug: "securite-informations-a-ne-jamais-divulguer"
)

g.title    = "Sécurité Bitcoin : les informations à ne jamais divulguer"
g.status   = "published"
g.featured = true
g.position = 2
g.content  = content
g.save!

puts "✅ Guide seeded: #{g.slug} (bytes=#{content.bytesize})"
