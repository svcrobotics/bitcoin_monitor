# app/services/bitcoin_rpc.rb
require "net/http"
require "json"
require "uri"

class BitcoinRpc
  class Error < StandardError; end

  DEFAULT_HOST = ENV.fetch("BITCOIN_RPC_HOST", "127.0.0.1")
  DEFAULT_PORT = Integer(ENV.fetch("BITCOIN_RPC_PORT", "8332"))

  DEFAULT_USER = ENV["BITCOIN_RPC_USER"]
  DEFAULT_PASS = ENV["BITCOIN_RPC_PASSWORD"]

  # Retry court pour absorber le "Wallet already loading" (loadwallet async)
  WALLET_LOAD_RETRIES = Integer(ENV.fetch("BITCOIN_WALLET_LOAD_RETRIES", "8"))
  WALLET_LOAD_SLEEP_S = Float(ENV.fetch("BITCOIN_WALLET_LOAD_SLEEP_S", "0.2"))

  attr_reader :wallet, :host, :port, :user, :password

  def initialize(wallet: nil, host: DEFAULT_HOST, port: DEFAULT_PORT, user: DEFAULT_USER, password: DEFAULT_PASS)
    @wallet   = wallet.presence
    @host     = host
    @port     = port
    @user     = user
    @password = password
    @id_seq   = 0

    # ✅ Cookie auth (optionnel). Utilisé seulement si BITCOIN_RPC_COOKIE est défini.
    cookie_path = ENV["BITCOIN_RPC_COOKIE"].presence
    
    if (@user.blank? || @password.blank?) && cookie_path.present? && File.exist?(cookie_path)
      u, p = File.read(cookie_path).strip.split(":", 2)
      @user = u
      @password = p
    end

    if @user.blank? || @password.blank?
      hint = cookie_path.present? ? " ou BITCOIN_RPC_COOKIE=#{cookie_path}" : ""
      raise Error, "RPC credentials manquants. Mets BITCOIN_RPC_USER/PASSWORD#{hint}"
    end
  end

  # =========================================================
  # Factories
  # =========================================================
  def self.vault_watch
    new(wallet: ENV.fetch("VAULT_WATCH_WALLET", "vault_watch3"))
  end

  def self.wallet(name)
    new(wallet: name)
  end

  # =========================================================
  # Core JSON-RPC low-level
  # =========================================================
  def rpc_call(method, params = [], wallet: :default)
    @id_seq += 1

    path =
      case wallet
      when :default then wallet_path
      when nil      then ""                  # chain endpoint
      else               "/wallet/#{wallet}" # explicit wallet
      end

    uri = URI.parse("http://#{@host}:#{@port}#{path}")

    req = Net::HTTP::Post.new(uri.request_uri)
    req.basic_auth(@user, @password)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req["Connection"] = "close"
    req["Proxy-Connection"] = "close"
    req.body = { jsonrpc: "1.0", id: @id_seq, method: method.to_s, params: params }.to_json

    open_timeout = Integer(ENV.fetch("BITCOIN_RPC_OPEN_TIMEOUT", "10"))
    read_timeout = Integer(ENV.fetch("BITCOIN_RPC_TIMEOUT", "60"))

    transport_attempts = 0

    begin
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: open_timeout, read_timeout: read_timeout) do |h|
        h.keep_alive_timeout = 0 if h.respond_to?(:keep_alive_timeout=)
        h.max_retries = 0 if h.respond_to?(:max_retries=)
        h.close_on_empty_response = true if h.respond_to?(:close_on_empty_response=)
        h.request(req)
      end
    rescue Net::ReadTimeout, EOFError, Errno::ECONNRESET => e
      transport_attempts += 1
      if transport_attempts <= 1
        sleep 0.05
        retry
      end
      raise Error, "#{method} timeout/closed (after retry). host=#{@host} port=#{@port} path=#{path} wallet=#{wallet.inspect} : #{e.class} - #{e.message}"
    end

    payload = JSON.parse(res.body) rescue nil
    raise Error, "RPC invalid JSON response: #{res.body.to_s[0, 300]}" if payload.nil?

    if payload["error"]
      e    = payload["error"]
      code = e["code"]
      msg  = e["message"].to_s

      # ✅ auto-load wallet si pas chargé (code -18) ET qu'on appelle le wallet par défaut
      if code == -18 && wallet == :default && @wallet.present?
        ensure_wallet_loaded!
        return rpc_call(method, params, wallet: wallet)
      end

      raise Error, "RPC error #{code}: #{msg}"
    end

    payload["result"]
  rescue Error
    raise
  rescue => e
    raise Error, "#{method} failed: #{e.class} - #{e.message}"
  end

  def rpc_call_chain(method, params = [])
    rpc_call(method, params, wallet: nil)
  end

  def wallet_path
    @wallet.present? ? "/wallet/#{@wallet}" : ""
  end

  # =========================================================
  # Wallet lifecycle (chain endpoint)
  # =========================================================
  def listwallets
    rpc_call_chain("listwallets")
  end

  def listwalletdir
    rpc_call_chain("listwalletdir")
  end

  def loadwallet(name = @wallet)
    raise Error, "wallet name manquant" if name.blank?
    rpc_call_chain("loadwallet", [name.to_s])
  end

  # ✅ Robuste contre "Wallet already loading"
  def ensure_wallet_loaded!
    return if @wallet.blank?

    # déjà chargé -> OK
    return true if wallet_loaded?(@wallet)

    WALLET_LOAD_RETRIES.times do |attempt|
      begin
        loadwallet(@wallet)
      rescue Error => e
        msg = e.message.to_s

        # cas: déjà en cours de chargement
        if msg.include?("Wallet already loading") || msg.include?("already loading")
          sleep WALLET_LOAD_SLEEP_S
          return true if wallet_loaded?(@wallet)
          next
        end

        # cas: déjà chargé (selon versions/configs)
        if msg.include?("already loaded")
          return true
        end

        # autres erreurs -> on remonte
        raise
      end

      # loadwallet peut être async: on laisse le temps puis on re-check
      sleep WALLET_LOAD_SLEEP_S
      return true if wallet_loaded?(@wallet)
    end

    # dernière chance
    return true if wallet_loaded?(@wallet)

    raise Error, "Impossible de loadwallet #{@wallet.inspect}: timeout (#{WALLET_LOAD_RETRIES} tentatives)"
  end

  def wallet_loaded?(name)
    Array(listwallets).include?(name.to_s)
  rescue => _
    false
  end

  # =========================================================
  # Chain / util (sans wallet)
  # =========================================================
  def get_blockchain_info = rpc_call_chain("getblockchaininfo")
  def mempool_info        = rpc_call_chain("getmempoolinfo")
  def getblockcount       = rpc_call_chain("getblockcount")
  def get_block_count     = getblockcount
  def getblockhash(h)     = rpc_call_chain("getblockhash", [h.to_i])
  def getblock(hash, v=1) = rpc_call_chain("getblock", [hash, v])

  def getrawtransaction(txid, verbose = true, blockhash = nil)
    params = [txid.to_s, !!verbose]
    params << blockhash.to_s if blockhash.present?
    rpc_call_chain("getrawtransaction", params)
  end

  def getblockstats(hash_or_height, stats = nil)
    params = [hash_or_height]
    params << stats if stats.present?
    rpc_call_chain("getblockstats", params)
  end

  # ✅ util : ok sans wallet
  def getdescriptorinfo(desc)
    rpc_call_chain("getdescriptorinfo", [desc.to_s])
  end

  # ✅ util : ok sans wallet (évite dépendance wallet)
  def deriveaddresses(desc, range = nil)
    range ? rpc_call_chain("deriveaddresses", [desc.to_s, range]) : rpc_call_chain("deriveaddresses", [desc.to_s])
  end

  # Aliases lisibles
  def best_block_height      = getblockcount.to_i
  def get_block_hash(height) = getblockhash(height)
  def get_block(block_hash, verbosity = 1) = getblock(block_hash, verbosity)

  # =========================================================
  # Wallet RPC (utilise /wallet/<name>)
  # =========================================================
  def getwalletinfo
    rpc_call("getwalletinfo")
  end

  def importdescriptors(reqs)
    rpc_call("importdescriptors", [reqs])
  end

  def listdescriptors
    rpc_call("listdescriptors")
  end

  # ✅ wallet RPC (nécessite wallet chargé)
  def getaddressinfo(address)
    rpc_call("getaddressinfo", [address.to_s])
  end

  # =========================================================
  # Address validation (util)
  # =========================================================
  def validateaddress(address)
    addr = address.to_s.strip
    return({ "isvalid" => false, "address" => addr, "error" => "Adresse vide" }) if addr.empty?

    getdescriptorinfo("addr(#{addr})")
    { "isvalid" => true, "address" => addr }
  rescue => e
    { "isvalid" => false, "address" => addr, "error" => e.message }
  end

  def validate_destination_address!(address, network: "mainnet")
    addr = address.to_s.strip
    raise Error, "Adresse vide" if addr.blank?

    getdescriptorinfo("addr(#{addr})")

    case network.to_s
    when "mainnet", "", nil
      raise Error, "Adresse testnet/signet sur un vault mainnet" if addr.start_with?("tb1", "m", "n", "2")
      raise Error, "Adresse regtest sur un vault mainnet" if addr.start_with?("bcrt1")
    when "testnet", "signet"
      raise Error, "Adresse mainnet sur un vault testnet/signet" if addr.start_with?("bc1", "1", "3")
      raise Error, "Adresse regtest sur un vault testnet/signet" if addr.start_with?("bcrt1")
    when "regtest"
      raise Error, "Adresse mainnet sur un vault regtest" if addr.start_with?("bc1", "1", "3")
      raise Error, "Adresse testnet/signet sur un vault regtest" if addr.start_with?("tb1", "m", "n", "2")
    end

    true
  rescue => e
    raise Error, "Adresse de destination invalide: #{e.message}"
  end

  # =========================================================
  # UTXO (wallet)
  # =========================================================
  def listunspent(minconf: 1, maxconf: 9_999_999, addresses: [], include_unsafe: true, query_options: nil)
    params = [minconf.to_i, maxconf.to_i, Array(addresses), !!include_unsafe]
    params << query_options if query_options
    rpc_call("listunspent", params)
  end

  def list_unspent_for_address(address, minconf: 0, maxconf: 9_999_999, include_unsafe: true, query_options: nil)
    listunspent(
      minconf:        minconf,
      maxconf:        maxconf,
      addresses:      [address.to_s],
      include_unsafe: include_unsafe,
      query_options:  query_options
    )
  end

  # =========================================================
  # PSBT
  # =========================================================
  def create_psbt(inputs, outputs, locktime = 0, replaceable = true)
    rpc_call_chain("createpsbt", [inputs, outputs, locktime.to_i, !!replaceable])
  end

  def utxoupdatepsbt(psbt, descriptors = nil)
    descriptors ? rpc_call_chain("utxoupdatepsbt", [psbt.to_s, descriptors]) : rpc_call_chain("utxoupdatepsbt", [psbt.to_s])
  end

  def combinepsbt(psbts)
    rpc_call_chain("combinepsbt", [psbts])
  end

  def finalizepsbt(psbt)
    rpc_call_chain("finalizepsbt", [psbt.to_s])
  end

  def decodepsbt(psbt)
    rpc_call_chain("decodepsbt", [psbt.to_s])
  end

  def analyzepsbt(psbt)
    rpc_call_chain("analyzepsbt", [psbt.to_s])
  end

  def walletprocesspsbt(psbt, sign = false, sighashtype = nil, bip32derivs = true)
    rpc_call("walletprocesspsbt", [psbt.to_s, !!sign, sighashtype, !!bip32derivs])
  end

  def sendrawtransaction(tx_hex)
    rpc_call_chain("sendrawtransaction", [tx_hex.to_s])
  end
end
