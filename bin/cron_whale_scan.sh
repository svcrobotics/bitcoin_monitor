#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Bitcoin Monitor — Whale Scan (cron-safe)
#
# Objectif
# --------
# Ce script lance le scan "whale" (grosses transactions BTC) de façon
# compatible cron : logs propres, environnement Ruby chargé, timeout dur.
#
# À quoi ça sert dans la chaîne "Inflow/Outflow"
# ----------------------------------------------
# 1) cron_whale_scan.sh  ✅ (ce script) :
#    - exécute le scanner "whale" (détection d'événements)
#    - écrit des enregistrements (events/UTXO observés) utilisés ensuite
#      par les jobs d'agrégation (ExchangeTrueFlowRebuilder, etc.)
#
# Important :
# - Ici on NE calcule PAS directement "inflow/outflow".
# - On produit la matière première : des événements et/ou UTXO observés.
#
# Locking (anti-concurrence)
# --------------------------
# Le lock n'est PAS géré ici : il est géré dans la crontab via flock, ex :
#   */2 * * * * flock -n /tmp/bitcoin_monitor_whale_scan.lock -c \
#     '/home/victor/bitcoin_monitor/bin/cron_whale_scan.sh'
#
# Donc :
# - Si le lock est déjà pris, cron n'exécute pas ce script.
# - Ce script peut rester simple et "cron-safe".
#
# Timeout
# -------
# Un timeout dur protège contre les scans bloqués :
# - timeout 900 -> kill après 15 minutes
# - rc=124 indique un timeout
#
# Paramètres d'environnement
# --------------------------
# - RAILS_ENV      : (default: development)
# - N              : nombre de blocs/itérations (default: 24)
# - WHALE_MIN_BTC  : seuil whale (default: 100)
#
# Tiers (solution pro)
# -------------------
# On scanne à partir de WHALE_MIN_BTC=100 (collecte).
# Ensuite, dans tmp/cron_whale_scan.rb on classe chaque event en tier :
# - B (Mid)   : 100..299.999 BTC
# - A (Large) : 300..999.999 BTC
# - S (Mega)  : >= 1000 BTC
#
# Inflow/Outflow :
# - NE SONT PAS calculés ici.
# - Ils seront agrégés dans le job de rebuild (par jour et par tier).
#
# Notes sur le runner
# -------------------
# Le coeur fonctionnel est dans :
#   tmp/cron_whale_scan.rb
#
# Ce fichier Ruby est censé :
# - se connecter à bitcoind via RPC
# - scanner les blocs récents (selon N / last height / etc.)
# - détecter les grosses transactions (>= WHALE_MIN_BTC)
# - classifier l'event (touching exchange ou non)
# - persister les données (events, observed utxos, etc.)
#
# Logs
# ----
# Les logs sont appendés dans :
#   log/cron.victor.log
#
# Format :
#   [whale_scan] start ...
#   [whale_scan] done/FAIL ...
#
# =========================================================

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

# ---------------------------------------------------------
# Préparation dossier log + positionnement dans l'app
# ---------------------------------------------------------
mkdir -p "$APP/log"
cd "$APP"

# ---------------------------------------------------------
# rbenv bootstrap
# - Permet d'avoir la bonne version Ruby + bundler en cron
# ---------------------------------------------------------
export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

ts() { date -Is; }

# ---------------------------------------------------------
# ENV (defaults)
# ---------------------------------------------------------
export RAILS_ENV="${RAILS_ENV:-development}"
export N="${N:-24}"
export WHALE_MIN_BTC="${WHALE_MIN_BTC:-100}"

# ---------------------------------------------------------
# Start log line (diagnostic versions)
# ---------------------------------------------------------
ruby_v="$(ruby -v 2>/dev/null || true)"
bundle_v="$(bundle -v 2>/dev/null || echo "bundle:NOT_FOUND")"
echo "[whale_scan] start $(ts) ruby=${ruby_v} bundler=${bundle_v} RAILS_ENV=${RAILS_ENV} N=${N} WHALE_MIN_BTC=${WHALE_MIN_BTC}" >> "$LOG"

t0="$(date +%s)"

# ---------------------------------------------------------
# Exécution (timeout hard)
# - set +e pour capturer rc sans interrompre le script
# - stdout/stderr append dans le LOG
# ---------------------------------------------------------
set +e
timeout 900 bundle exec rails runner tmp/cron_whale_scan.rb >> "$LOG" 2>&1
rc=$?
set -e

dt="$(( $(date +%s) - t0 ))"

# ---------------------------------------------------------
# End + diagnostics
# ---------------------------------------------------------
if [ "$rc" -eq 124 ]; then
  echo "[whale_scan] WARN $(ts) timeout after 900s" >> "$LOG"
fi

if [ "$rc" -eq 0 ]; then
  echo "[whale_scan] done rc=${rc} dur=${dt}s $(ts)" >> "$LOG"
else
  echo "[whale_scan] FAIL rc=${rc} dur=${dt}s $(ts)" >> "$LOG"
fi

exit "$rc"
