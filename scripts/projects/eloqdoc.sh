#!/usr/bin/env bash
# Product adapter: eloqdoc (MongoDB 4.0.3-compatible, SCons + Python 3).
#
# Licensing-locked to MongoDB 4.0.3 (last AGPL) => SCons build. Per the project decision
# (CLAUDE.md Task 3, "Option B"): the SConstruct + buildscripts + IDL compiler were ported
# from Python 2.7 to Python 3 (on lintao-mod), the vendored SCons 2.5.0 engine was replaced
# with a modern pip-installed SCons (which supports Python 3), and Cheetah (templating for
# generate_error_codes.py) is provided by the Cheetah3 fork. Build = cmake the Eloq core
# module, then scons-build mongo — all under a hermetic Python 3 venv (sudo-free).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../env.sh"
source "$HERE/../lib/common.sh"

SRC="$ELOQDB_PROJECTS/eloqdoc"
[ -d "$SRC" ] || eloqdb_die "eloqdoc not cloned at $SRC (run build.sh first)"

WITH_DATA_STORE="${ELOQDB_WITH_DATA_STORE:-ELOQDSS_ELOQSTORE}"
WITH_LOG_STATE="${ELOQDB_WITH_LOG_STATE:-ROCKSDB}"

# --- Provision a hermetic Python 3 venv carrying the SCons engine + build-time deps ---
# (isolate, don't pollute the system interpreter — mirrors the old Python 2.7 isolation).
ensure_eloqdoc_venv() {
    local venv="$ELOQDB_ROOT/.venv-eloqdoc"
    if [ ! -x "$venv/bin/scons" ]; then
        eloqdb_log "provisioning eloqdoc Python 3 build venv -> $venv"
        python3 -m venv "$venv"
        "$venv/bin/pip" install --upgrade pip -q
        "$venv/bin/pip" install -q \
            "scons==4.10.1" pyyaml jinja2 packaging Cheetah3
    fi
    export PATH="$venv/bin:$PATH"
    eloqdb_log "scons = $(scons --version | head -1)"
}

ensure_eloqdoc_venv
# Shared data_substrate, built inline against the shared checkout under dependencies/ — pointed
# at via -DDATA_SUBSTRATE_DIR + the dep-dir flags (no symlinks).
eloq_ensure_data_substrate
mapfile -t DS_DIR_FLAGS < <(eloq_substrate_dir_flags)

# eloqdoc's vendored MongoDB sources (and the eloq module itself) #include
# "mongo/db/modules/eloq/data_substrate/..." — a hardcoded in-tree-submodule path baked into ~20
# files / 76 includes (incl. core mongo/base/object_pool.h), resolved globally via the SCons
# build's "-Isrc". A CPPPATH override can't redirect that prefix without rewriting every include
# in vendored/upstream source. Sanctioned exception to the umbrella's no-symlink build-wiring
# rule (CLAUDE.md item 2 targets *our* dependency wiring; this is forced by upstream's in-tree-
# submodule include layout): symlink this one in-tree path to the single shared checkout.
link_data_substrate_into_eloq_module() {
    local target="$SRC/src/mongo/db/modules/eloq/data_substrate"
    if [ -L "$target" ]; then
        return
    fi
    eloqdb_log "linking shared data_substrate into eloq module -> $target (sanctioned exception: upstream hardcodes this in-tree include path)"
    rm -rf "$target"
    ln -s "$ELOQDB_DATA_SUBSTRATE" "$target"
}
link_data_substrate_into_eloq_module

# 1) Eloq core module via cmake (links shared deps + data_substrate).
eloqdb_log "Building eloqdoc Eloq core module (cmake)"
cmake -S "$SRC/src/mongo/db/modules/eloq" -B "$SRC/src/mongo/db/modules/eloq/build" \
    -DBUILD_SHARED_LIBS=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
    -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
    "${DS_DIR_FLAGS[@]}" \
    -DCMAKE_CXX_STANDARD=17 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DEXT_TX_PROC_ENABLED=ON -DELOQ_MODULE_ENABLED=ON -DSTATISTICS=ON -DUSE_ASAN=OFF \
    -DWITH_LOG_STATE="$WITH_LOG_STATE" -DWITH_DATA_STORE="$WITH_DATA_STORE" \
    -DWITH_CLOUD_STORAGE="${ELOQDB_WITH_CLOUD_STORAGE:-OFF}"
cmake --build "$SRC/src/mongo/db/modules/eloq/build" -j "$ELOQDB_JOBS"
cmake --install "$SRC/src/mongo/db/modules/eloq/build"

# 2) MongoDB server via SCons under Python 3 (install-core into the shared prefix).
# --site-dir=scons: this fork's site-customization dir is named "scons" (the upstream
# convention is "site_scons"); modern SCons needs that spelled out explicitly.
eloqdb_log "Building eloqdoc mongo server (scons + python3)"
( cd "$SRC"
  env WITH_DATA_STORE="$WITH_DATA_STORE" WITH_LOG_STATE="$WITH_LOG_STATE" \
      ELOQDB_DATA_SUBSTRATE_DIR="$ELOQDB_DATA_SUBSTRATE" \
    scons \
        --site-dir=scons \
        MONGO_VERSION=4.0.3 \
        VARIANT_DIR=RelWithDebInfo \
        LIBPATH="$ELOQDB_PREFIX/lib" \
        CPPPATH="$ELOQDB_PREFIX/include" \
        CXXFLAGS="-Wno-nonnull -Wno-class-memaccess -Wno-interference-size -Wno-redundant-move" \
        --build-dir=#build \
        --prefix="$ELOQDB_PREFIX" \
        --disable-warnings-as-errors \
        -j "$ELOQDB_JOBS" \
        install-core )
eloqdb_log "eloqdoc built -> $ELOQDB_PREFIX/bin"
