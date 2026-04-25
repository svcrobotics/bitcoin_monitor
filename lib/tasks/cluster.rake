# lib/tasks/cluster.rake
namespace :cluster do
  desc "Scan Bitcoin blocks for multi-input address clustering"
  task scan: :environment do
    from  = ENV["FROM"]&.to_i
    to    = ENV["TO"]&.to_i
    limit = ENV["LIMIT"]&.to_i

    result = Clusters::ScanAndDispatch.call(
      from_height: from,
      to_height: to,
      limit: limit
    )

    pp result
  end

  desc "Scan recent blocks only"
  task scan_recent: :environment do
    blocks_back = (ENV["BLOCKS"] || "20").to_i

    rpc  = BitcoinRpc.new(wallet: nil)
    best = rpc.getblockcount.to_i

    from = [0, best - blocks_back + 1].max
    to   = best

    result = Clusters::ScanAndDispatch.call(
      from_height: from,
      to_height: to
    )

    pp result
  end

  desc "Show global cluster stats"
  task stats: :environment do
    puts
    puts "=== Cluster Stats ==="
    puts "Clusters     : #{Cluster.count}"
    puts "Addresses    : #{Address.count}"
    puts "Links        : #{AddressLink.count}"
    puts

    puts "Top 10 largest clusters:"
    puts

    rows = Cluster.order(address_count: :desc).limit(10)

    rows.each do |c|
      puts [
        "cluster_id=#{c.id}",
        "addresses=#{c.address_count}",
        "first_seen=#{c.first_seen_height || '-'}",
        "last_seen=#{c.last_seen_height || '-'}",
        "sent_sats=#{c.total_sent_sats || 0}",
        "received_sats=#{c.total_received_sats || 0}"
      ].join(" | ")
    end

    puts
  end

  desc "Show one cluster details: bin/rails 'cluster:show[123]'"
  task :show, [:id] => :environment do |_t, args|
    id = args[:id].to_i
    raise "cluster id manquant" if id <= 0

    cluster = Cluster.find_by(id: id)
    raise "cluster ##{id} introuvable" unless cluster

    puts
    puts "=== Cluster ##{cluster.id} ==="
    puts "address_count   : #{cluster.address_count}"
    puts "first_seen      : #{cluster.first_seen_height || '-'}"
    puts "last_seen       : #{cluster.last_seen_height || '-'}"
    puts "total_sent_sats : #{cluster.total_sent_sats || 0}"
    puts "total_recv_sats : #{cluster.total_received_sats || 0}"
    puts

    puts "--- Sample addresses ---"

    cluster.addresses.limit(20).each do |addr|
      puts [
        addr.address,
        "tx_count=#{addr.tx_count}",
        "sent_sats=#{addr.total_sent_sats}"
      ].join(" | ")
    end

    puts
    puts "--- Sample links ---"

    address_ids = cluster.addresses.limit(200).pluck(:id)

    AddressLink
      .where(address_a_id: address_ids)
      .or(AddressLink.where(address_b_id: address_ids))
      .limit(20)
      .each do |link|

      puts [
        "link_id=#{link.id}",
        "a=#{link.address_a_id}",
        "b=#{link.address_b_id}",
        "txid=#{link.txid}",
        "height=#{link.block_height}"
      ].join(" | ")
    end

    puts
  end
end