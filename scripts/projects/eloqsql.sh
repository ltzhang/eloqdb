#!/usr/bin/env bash
# Product adapter: eloqsql (MariaDB-compatible, CMake).
# NOTE: eloqsql is a full MariaDB tree; it vendors its own rocksdb/libmariadb/wsrep/etc.
# as submodules (kept project-local), and builds the Eloq engine under storage/eloq.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../env.sh"
source "$HERE/../lib/common.sh"

SRC="$ELOQDB_PROJECTS/eloqsql"
BLD="$ELOQDB_BUILD/eloqsql"
[ -d "$SRC" ] || eloqdb_die "eloqsql not cloned at $SRC (run build.sh first)"

WITH_DATA_STORE="${ELOQDB_WITH_DATA_STORE:-ELOQDSS_ELOQSTORE}"
WITH_LOG_STATE="${ELOQDB_WITH_LOG_STATE:-ROCKSDB}"

# Shared data_substrate version (MariaDB root-level submodule path).
link_shared_data_substrate "$SRC" "data_substrate"

eloqdb_log "Configuring eloqsql (data_store=$WITH_DATA_STORE, log_state=$WITH_LOG_STATE)"
# MariaDB build knobs: keep it minimal (Eloq engine only), point at shared prefix.
cmake -S "$SRC" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
    -DWITH_DATA_STORE="$WITH_DATA_STORE" \
    -DWITH_LOG_STATE="$WITH_LOG_STATE" \
    -DPLUGIN_TOKUDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO \
    -DPLUGIN_OQGRAPH=NO -DPLUGIN_PERFSCHEMA=NO -DPLUGIN_SPHINX=NO \
    -DWITHOUT_EXAMPLE_STORAGE_ENGINE=1 -DWITH_UNIT_TESTS=OFF

cmake --build "$BLD" -j "$ELOQDB_JOBS"
eloqdb_log "eloqsql built -> $BLD"
