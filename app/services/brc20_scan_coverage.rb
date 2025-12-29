# app/services/brc20_scan_coverage.rb
class Brc20ScanCoverage
  RangeInfo = Struct.new(:from, :to)

  attr_reader :target_from, :target_to

  def initialize(target_from:, target_to:)
    @target_from = target_from.to_i
    @target_to   = target_to.to_i
    raise ArgumentError, "target_from doit être <= target_to" if @target_from > @target_to
  end

  def merged_scanned_ranges
    raw = Brc20ScanRange.ordered.to_a
    return [] if raw.empty?

    merged = []
    current_from = raw.first.from_height
    current_to   = raw.first.to_height

    raw.drop(1).each do |r|
      if r.from_height <= current_to + 1
        current_to = [current_to, r.to_height].max
      else
        merged << RangeInfo.new(current_from, current_to)
        current_from = r.from_height
        current_to   = r.to_height
      end
    end

    merged << RangeInfo.new(current_from, current_to)
    merged
  end

  def scanned_ranges_in_target
    merged_scanned_ranges.map do |r|
      from = [r.from, target_from].max
      to   = [r.to,   target_to].min
      next if from > to
      RangeInfo.new(from, to)
    end.compact
  end

  def missing_ranges
    ranges = scanned_ranges_in_target
    missing = []
    cursor = target_from

    ranges.each do |r|
      if r.from > cursor
        missing << RangeInfo.new(cursor, r.from - 1)
      end
      cursor = [cursor, r.to + 1].max
    end

    if cursor <= target_to
      missing << RangeInfo.new(cursor, target_to)
    end

    missing
  end

  def stats
    ranges = scanned_ranges_in_target
    scanned_blocks = ranges.sum { |r| (r.to - r.from + 1) }
    total_blocks   = (target_to - target_from + 1)
    missing_blocks = total_blocks - scanned_blocks

    {
      target_from:    target_from,
      target_to:      target_to,
      total_blocks:   total_blocks,
      scanned_blocks: scanned_blocks,
      missing_blocks: missing_blocks,
      coverage_pct:   (total_blocks > 0 ? (scanned_blocks.to_f / total_blocks * 100).round(4) : 0.0),
      gaps_count:     missing_ranges.size
    }
  end

  # 👉 Ici : génération des “petits carrés” visuels
  def slots(count: 120)
    total_blocks = target_to - target_from + 1
    return [] if total_blocks <= 0

    count = 1 if count < 1
    slot_size = (total_blocks.to_f / count).ceil

    ranges = scanned_ranges_in_target
    slots  = []

    current_from = target_from

    count.times do
      break if current_from > target_to

      current_to = [current_from + slot_size - 1, target_to].min
      total      = current_to - current_from + 1

      # combien de blocs scannés dans cette tranche ?
      scanned = ranges.sum do |r|
        overlap_from = [r.from, current_from].max
        overlap_to   = [r.to,   current_to].min
        overlap_to >= overlap_from ? (overlap_to - overlap_from + 1) : 0
      end

      ratio = total.positive? ? scanned.to_f / total : 0.0

      slots << {
        from:    current_from,
        to:      current_to,
        scanned: scanned,
        total:   total,
        ratio:   ratio
      }

      current_from = current_to + 1
    end

    slots
  end
end
