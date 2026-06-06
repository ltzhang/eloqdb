#!/usr/bin/env bash
# Product adapter: eloquentdb (unified `eloqdb` binary = eloqkv + eloqsql + the shared core).
#
# eloquentdb (eloqdata/eloquentdb) is itself an umbrella: its CMake builds data_substrate, then
# eloqkv and eloqsql as libraries, and links them into a single `eloqdb` executable. Upstream it
# pulls each engine as a pinned git submodule.
#
# Here we do NOT use those submodules and create NO symlinks. We point each path at THIS
# umbrella's own checkout via -D*_DIR (patched overridable on eloquentdb's lintao-mod):
#   - data_substrate -> the single shared core (dependencies/data_substrate)  [-DDATA_SUBSTRATE_DIR]
#   - eloqkv/eloqsql -> projects/<engine>                                     [-DELOQKV_DIR/-DELOQSQL_DIR]
# The wiring is driven by eloquentdb's own .gitmodules, so a future engine is picked up too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../env.sh"
source "$HERE/../lib/common.sh"

SRC="$ELOQDB_PROJECTS/eloquentdb"
BLD="$ELOQDB_BUILD/eloquentdb"
[ -d "$SRC" ] || eloqdb_die "eloquentdb not cloned at $SRC (run build.sh first)"
[ -f "$SRC/.gitmodules" ] || eloqdb_die "eloquentdb has no .gitmodules at $SRC"

WITH_DATA_STORE="${ELOQDB_WITH_DATA_STORE:-ELOQDSS_ELOQSTORE}"
WITH_LOG_STATE="${ELOQDB_WITH_LOG_STATE:-ROCKSDB}"

# eloqkv built as a library here overwrites CMAKE_CXX_FLAGS (eloqkv CMakeLists.txt) and, in this
# converged mode, doesn't add the shared prefix to eloqkv_lib's include path — so headers it pulls
# in transitively (e.g. glog via tx_service) aren't found. CPATH puts the shared prefix on every
# compile's search path at lowest priority (after -I), so it fills the gap without overriding any
# vendored headers. Safe now that abseil is a single shared checkout.
export CPATH="$ELOQDB_PREFIX/include${CPATH:+:$CPATH}"

# Submodule URLs in eloquentdb are SSH (git@github.com:…); use https so the build needs no keys.
to_https() { printf '%s' "$1" | sed -E 's#^git@github\.com:#https://github.com/#'; }

# The shared core (built inline by eloquentdb's CMake against dependencies/data_substrate).
eloq_ensure_data_substrate
mapfile -t DIR_FLAGS < <(eloq_substrate_dir_flags)   # ELOQ_ABSEIL_DIR/TXLOG/ELOQSTORE/DATA_SUBSTRATE_DIR

# Walk eloquentdb's declared submodules; for each engine, ensure the umbrella's own checkout
# exists and point eloquentdb at it via -D<ENGINE>_DIR. No symlinks, no data_substrate recursion.
ENGINE_FLAGS=()
gm="$SRC/.gitmodules"
for name in $(git config -f "$gm" --get-regexp '^submodule\..*\.path$' \
                | sed -E 's/^submodule\.(.*)\.path .*/\1/'); do
    path="$(git config -f "$gm" --get "submodule.$name.path")"
    url="$(to_https "$(git config -f "$gm" --get "submodule.$name.url")")"
    base="$(basename "$path")"

    [ "$base" = "data_substrate" ] && continue   # handled via eloq_substrate_dir_flags

    # An engine -> the umbrella's own product checkout (latest; project-local submodules only).
    local_comp="$ELOQDB_PROJECTS/$base"
    [ -d "$local_comp/.git" ] || { eloqdb_log "wiring eloquentdb engine '$base' -> $local_comp"; clone_product "$url" "$local_comp" ""; }

    case "$base" in
        eloqkv)  ENGINE_FLAGS+=(-DWITH_ELOQKV=ON  -DELOQKV_DIR="$local_comp") ;;
        eloqsql) ENGINE_FLAGS+=(-DWITH_ELOQSQL=ON -DELOQSQL_DIR="$local_comp") ;;
        eloqdoc) ENGINE_FLAGS+=(-DWITH_ELOQDOC=ON -DELOQDOC_DIR="$local_comp") ;;
        *)       eloqdb_warn "unknown eloquentdb engine '$base' — no WITH_ flag set" ;;
    esac
done

eloqdb_log "Configuring eloquentdb (data_store=$WITH_DATA_STORE, log_state=$WITH_LOG_STATE, engines=${ENGINE_FLAGS[*]:-none})"
cmake -S "$SRC" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
    -DCMAKE_CXX_FLAGS="-I$ELOQDB_PREFIX/include" \
    -DCMAKE_C_FLAGS="-I$ELOQDB_PREFIX/include" \
    "${DIR_FLAGS[@]}" \
    -DWITH_DATA_STORE="$WITH_DATA_STORE" \
    -DWITH_LOG_STATE="$WITH_LOG_STATE" \
    -DBRPC_WITH_GLOG=ON \
    -DPLUGIN_TOKUDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO \
    -DPLUGIN_OQGRAPH=NO -DPLUGIN_PERFSCHEMA=NO -DPLUGIN_SPHINX=NO \
    -DPLUGIN_ROCKSDB=NO -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_S3=NO \
    -DWITH_WSREP=OFF -DWITH_SSL=system \
    -DWITHOUT_EXAMPLE_STORAGE_ENGINE=1 -DWITH_UNIT_TESTS=OFF \
    "${ENGINE_FLAGS[@]}"

cmake --build "$BLD" -j "$ELOQDB_JOBS"
cmake --install "$BLD"
eloqdb_log "eloquentdb built -> $BLD/eloqdb (installed to $ELOQDB_PREFIX/bin)"
