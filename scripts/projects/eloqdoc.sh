#!/usr/bin/env bash
# Product adapter: eloqdoc (MongoDB 4.0.3-compatible, SCons + Python 2.7).
#
# Licensing-locked to MongoDB 4.0.3 (last AGPL) => SCons + Python 2.7. Per the project
# decision (CLAUDE.md Task 3, "Option A"): isolate a hermetic Python 2.7 via pyenv rather
# than port the build now. Build = cmake the Eloq core module, then scons-build mongo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../env.sh"
source "$HERE/../lib/common.sh"

SRC="$ELOQDB_PROJECTS/eloqdoc"
[ -d "$SRC" ] || eloqdb_die "eloqdoc not cloned at $SRC (run build.sh first)"

WITH_DATA_STORE="${ELOQDB_WITH_DATA_STORE:-ELOQDSS_ELOQSTORE}"
WITH_LOG_STATE="${ELOQDB_WITH_LOG_STATE:-ROCKSDB}"
PY2_VERSION="2.7.18"

# --- Provision hermetic Python 2.7 (Option A: isolate, don't pollute system) ---
ensure_python2() {
    if command -v python2 >/dev/null && python2 -c 'import sys; sys.exit(0 if sys.version_info[:2]==(2,7) else 1)' 2>/dev/null; then
        eloqdb_log "python2.7 already available: $(command -v python2)"; return 0
    fi
    export PYENV_ROOT="$ELOQDB_ROOT/.pyenv"
    if [ ! -d "$PYENV_ROOT" ]; then
        eloqdb_log "installing pyenv into $PYENV_ROOT"
        run_with_retry git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
    fi
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init - 2>/dev/null || true)"
    if ! pyenv versions --bare | grep -qx "$PY2_VERSION"; then
        eloqdb_log "building Python $PY2_VERSION via pyenv (hermetic, no sudo)"
        pyenv install -s "$PY2_VERSION"
    fi
    pyenv shell "$PY2_VERSION"
    eloqdb_log "python2 = $(python --version 2>&1)"
}

ensure_python2
# Shared data_substrate version (eloqdoc nests it under the eloq module).
link_shared_data_substrate "$SRC" "src/mongo/db/modules/eloq/data_substrate"

# 1) Eloq core module via cmake (links shared deps + data_substrate).
eloqdb_log "Building eloqdoc Eloq core module (cmake)"
cmake -S "$SRC/src/mongo/db/modules/eloq" -B "$SRC/src/mongo/db/modules/eloq/build" \
    -DBUILD_SHARED_LIBS=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
    -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
    -DCMAKE_CXX_STANDARD=17 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DEXT_TX_PROC_ENABLED=ON -DELOQ_MODULE_ENABLED=ON -DSTATISTICS=ON -DUSE_ASAN=OFF \
    -DWITH_LOG_STATE="$WITH_LOG_STATE" -DWITH_DATA_STORE="$WITH_DATA_STORE"
cmake --build "$SRC/src/mongo/db/modules/eloq/build" -j "$ELOQDB_JOBS"
cmake --install "$SRC/src/mongo/db/modules/eloq/build"

# 2) MongoDB server via SCons under Python 2.7 (install-core into the shared prefix).
eloqdb_log "Building eloqdoc mongo server (scons + python2.7)"
( cd "$SRC"
  env WITH_DATA_STORE="$WITH_DATA_STORE" WITH_LOG_STATE="$WITH_LOG_STATE" \
    python scripts/buildscripts/scons.py \
        MONGO_VERSION=4.0.3 \
        VARIANT_DIR=RelWithDebInfo \
        CXXFLAGS="-Wno-nonnull -Wno-class-memaccess -Wno-interference-size -Wno-redundant-move" \
        --build-dir=#build \
        --prefix="$ELOQDB_PREFIX" \
        --disable-warnings-as-errors \
        -j "$ELOQDB_JOBS" \
        install-core )
eloqdb_log "eloqdoc built -> $ELOQDB_PREFIX/bin"
