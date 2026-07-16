# frozen_string_literal: true

require "json"

module BtcIsolatedCache
  def install_isolated_btc_cache
    @btc_test_cache = {}
    @btc_test_cache_accesses = []
    @btc_original_fetch_json = Btc::Cache::Store.method(:fetch_json)
    entries = @btc_test_cache
    accesses = @btc_test_cache_accesses

    Btc::Cache::Store.define_singleton_method(:fetch_json) do |key, expires_in: nil, &block|
      accesses << key

      if entries.key?(key)
        JSON.parse(entries.fetch(key), symbolize_names: true)
      elsif block
        value = block.call
        entries[key] = JSON.generate(value)
        value
      end
    end
  end

  def uninstall_isolated_btc_cache
    Btc::Cache::Store.define_singleton_method(
      :fetch_json,
      @btc_original_fetch_json
    )
  end

  attr_reader :btc_test_cache, :btc_test_cache_accesses
end
