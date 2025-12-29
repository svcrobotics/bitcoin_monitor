WALLET="vault_watch"

# 1) Récupérer les descriptors (avec checksum) pour chaque adresse
DESC_SPARROW=$(
  bitcoin-cli -rpcwallet="$WALLET" \
    getdescriptorinfo "addr(bc1qhk5ylfdn35qkx66hn03rdqk9wcdhqrfm0d69e7t225wzg6wvm2ts2h5hc2)" \
    | jq -r '.descriptor'
)

DESC_BTCPAY=$(
  bitcoin-cli -rpcwallet="$WALLET" \
    getdescriptorinfo "addr(bc1qzukeq35tyhsv4d778sv90kqaxzhxfpzxl3velup3erlj6g3ny0lq3wqcss)" \
    | jq -r '.descriptor'
)

DESC_PHOENIX=$(
  bitcoin-cli -rpcwallet="$WALLET" \
    getdescriptorinfo "addr(bc1q20z7dnpkpyaueq9wn2kq7u8xt7kh6mfs05em3zycyaqxaqq6ws2qy0tacj)" \
    | jq -r '.descriptor'
)

echo "Descriptor Sparrow :  $DESC_SPARROW"
echo "Descriptor BTCPay  :  $DESC_BTCPAY"
echo "Descriptor Phoenix :  $DESC_PHOENIX"

# 2) Timestamps un peu avant la création de chaque vault
#   Sparrow  : créé le 08 déc 2025 à 14:02 → on prend 13:50
#   BTCPay   : créé le 07 déc 2025 à 14:17 → on prend 14:00
#   Phoenix  : créé le 06 déc 2025 à 10:55 → on prend 10:30

TS_SPARROW=$(date -d "2025-12-08 13:50" +%s)
TS_BTCPAY=$(date -d "2025-12-07 14:00" +%s)
TS_PHOENIX=$(date -d "2025-12-06 10:30" +%s)

echo "TS_SPARROW  = $TS_SPARROW"
echo "TS_BTCPAY   = $TS_BTCPAY"
echo "TS_PHOENIX  = $TS_PHOENIX"

# 3) Importdescriptors en une seule fois pour les 3 vaults
bitcoin-cli -rpcwallet="$WALLET" importdescriptors "$(
  cat <<JSON
[
  {
    "desc": "$DESC_SPARROW",
    "timestamp": $TS_SPARROW,
    "active": false
  },
  {
    "desc": "$DESC_BTCPAY",
    "timestamp": $TS_BTCPAY,
    "active": false
  },
  {
    "desc": "$DESC_PHOENIX",
    "timestamp": $TS_PHOENIX,
    "active": false
  }
]
JSON
)"
