#!/usr/bin/env bash
# Product adapter: eloqkv (Redis-compatible, CMake).
# Builds against the shared prefix; uses the shared data_substrate checkout.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../env.sh"
source "$HERE/../lib/common.sh"

SRC="$ELOQDB_PROJECTS/eloqkv"
BLD="$ELOQDB_BUILD/eloqkv"
[ -d "$SRC" ] || eloqdb_die "eloqkv not cloned at $SRC (run build.sh first)"

WITH_DATA_STORE="${ELOQDB_WITH_DATA_STORE:-ELOQDSS_ELOQSTORE}"
WITH_LOG_STATE="${ELOQDB_WITH_LOG_STATE:-ROCKSDB}"

# One shared data_substrate version for every product.
link_shared_data_substrate "$SRC" "data_substrate"

eloqdb_log "Configuring eloqkv (data_store=$WITH_DATA_STORE, log_state=$WITH_LOG_STATE)"
cmake -S "$SRC" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
    -DWITH_DATA_STORE="$WITH_DATA_STORE" \
    -DWITH_LOG_STATE="$WITH_LOG_STATE" \
    -DBRPC_WITH_GLOG=ON

cmake --build "$BLD" -j "$ELOQDB_JOBS"
eloqdb_log "eloqkv built -> $BLD/eloqkv"
