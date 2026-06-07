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

# Shared data_substrate, built inline against the shared checkout under dependencies/ — pointed
# at via -DDATA_SUBSTRATE_DIR + the dep-dir flags (no symlinks).
eloq_ensure_data_substrate
mapfile -t DS_DIR_FLAGS < <(eloq_substrate_dir_flags)

eloqdb_log "Configuring eloqsql (data_store=$WITH_DATA_STORE, log_state=$WITH_LOG_STATE)"
# MariaDB's sql/ includes brpc headers directly (e.g. <bthread/moodycamelqueue.h>). With the
# original sudo install those lived in /usr/local/include (a default search path); our sudo-free
# prefix is not, so add it explicitly. (CMAKE_PREFIX_PATH only drives find_*, not bare #includes.)
# MariaDB build knobs: keep it minimal (Eloq engine only), point at shared prefix.
cmake -S "$SRC" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
    -DCMAKE_CXX_FLAGS="-I$ELOQDB_PREFIX/include" \
    -DCMAKE_C_FLAGS="-I$ELOQDB_PREFIX/include" \
    "${DS_DIR_FLAGS[@]}" \
    -DWITH_DATA_STORE="$WITH_DATA_STORE" \
    -DWITH_LOG_STATE="$WITH_LOG_STATE" \
    -DWITH_CLOUD_STORAGE="${ELOQDB_WITH_CLOUD_STORAGE:-OFF}" \
    -DPLUGIN_TOKUDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO \
    -DPLUGIN_OQGRAPH=NO -DPLUGIN_PERFSCHEMA=NO -DPLUGIN_SPHINX=NO \
    -DPLUGIN_ROCKSDB=NO -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_S3=NO \
    -DWITH_WSREP=OFF -DWITH_SSL=system \
    -DWITHOUT_EXAMPLE_STORAGE_ENGINE=1 -DWITH_UNIT_TESTS=OFF

cmake --build "$BLD" -j "$ELOQDB_JOBS"
eloqdb_log "eloqsql built -> $BLD"
