#!/usr/bin/env bash
# Layer 2 of the EloqDB build: the shared Eloq core (data_substrate).
# Internal script — invoked automatically by build.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard: this is an internal layer script. Direct invocation is unsupported.
if [ -z "${ELOQDB_ORCHESTRATED:-}" ]; then
    cat <<'EOF'

================================================================
  EloqDB Build System
  https://github.com/ltzhang/eloq_build_env
================================================================

  substrate.sh is an internal build layer — use build.sh instead:

    build.sh [--data-substrate] [--fetch-only] [OPTIONS]
    build.sh --help

  Advanced: to bypass this check (e.g. for debugging):
    ELOQDB_ORCHESTRATED=1 _scripts/substrate.sh

================================================================

EOF
    exit 1
fi

source "$HERE/../env.sh"
source "$HERE/common.sh"

DS_DATA_STORE="${ELOQDB_WITH_DATA_STORE:-ELOQDSS_ELOQSTORE}"
DS_MODULE="${ELOQDB_ELOQ_MODULE:-}"
# EloqStore's cloud (S3/GCS) object-storage backend is compile-time optional (lintao-mod:
# -DWITH_CLOUD_STORAGE, gates ELOQSTORE_WITH_CLOUD + the AWSSDK link). build.sh derives this
# from ELOQDB_WITH_CLOUD; default OFF (local-only) when invoked standalone.
DS_WITH_CLOUD_STORAGE="${ELOQDB_WITH_CLOUD_STORAGE:-OFF}"

# data_substrate's (recursive) submodules are FLATTENED to depth-2 under dependencies/ — each is
# cloned ONCE to a flat location and symlinked into the deep path the build expects. This keeps all
# checkouts shallow (no submodules buried under other repos) and de-duplicates shared ones (e.g.
# tx-log-protos, used by both tx_service and log_service, becomes a single checkout).
# Versioning: eloqdata -> latest (prefers lintao-mod); upstream third-party -> pinned.
ELOQSTORE_REPO="https://github.com/eloqdata/eloqstore.git"
ELOQSTORE_BRANCH=""   # empty => remote default (unless ELOQDB_MOD_BRANCH exists)
PIN_ABSEIL_REF="69195d5bd2416a7224416887c78353ee8edf67ee"   # must match deps.sh (the shared abseil)
PIN_CONCURRENTQUEUE="c68072129c8a5b4025122ca5a0c82ab14b30cb03"
PIN_INIH="8e06f6b77b5d4471bdc6d85ada81b67d37354a5c"

# Sanity: layer 2 needs layer 1. Spot-check a couple of representative deps.
check_deps_layer() {
    local missing=()
    [ -e "$ELOQDB_PREFIX/include/mimalloc.h" ] || [ -e "$ELOQDB_PREFIX/include/mimalloc-2.1/mimalloc.h" ] || missing+=(mimalloc)
    [ -n "$(ls "$ELOQDB_PREFIX"/lib/libbrpc* 2>/dev/null)" ] || missing+=(brpc)
    [ -n "$(ls "$ELOQDB_PREFIX"/lib/librocksdb* 2>/dev/null)" ] || missing+=(rocksdb)
    # AWS S3 SDK: required for DynamoDB/S3 backends always, and for EloqStore only when its
    # optional cloud-storage backend is being compiled in (DS_WITH_CLOUD_STORAGE=ON).
    case "$DS_DATA_STORE" in
        *DYNAMODB*|*S3*)
            [ -n "$(ls "$ELOQDB_PREFIX"/lib/libaws-cpp-sdk-s3* 2>/dev/null)" ] || missing+=("aws-sdk(s3)") ;;
        *ELOQSTORE*)
            [ "$DS_WITH_CLOUD_STORAGE" = "ON" ] && { [ -n "$(ls "$ELOQDB_PREFIX"/lib/libaws-cpp-sdk-s3* 2>/dev/null)" ] || missing+=("aws-sdk(s3)"); } ;;
    esac
    if [ ${#missing[@]} -gt 0 ]; then
        eloqdb_die "deps layer incomplete (missing: ${missing[*]}). Run: build.sh --deps-only"
    fi
}

# --- flat-checkout + symlink helpers (no recursion: each repo's own submodules are flattened too) ---
# Remove a stale path at <dest> (a symlink, or a non-git directory) so a fresh clone can land there.
_clear_stale() { local d=$1; { [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d/.git" ]; }; } && rm -rf "$d"; return 0; }
_flat_latest() {  # url dest [branch]   eloqdata -> latest (prefers ELOQDB_MOD_BRANCH if present)
    local url=$1 dest=$2 branch=${3:-}
    url="$(eloq_ssh_url "$url")"   # eloqdata -> SSH (reach lintao-mod); third-party untouched
    branch="$(eloq_pick_branch "$url" "$branch")"
    _clear_stale "$dest"
    if [ -d "$dest/.git" ]; then
        git -C "$dest" remote set-url origin "$url"   # migrate existing https origin -> SSH
        run_with_retry git -C "$dest" fetch origin
        [ -n "$branch" ] && git -C "$dest" checkout "$branch" 2>/dev/null || true
        git -C "$dest" pull --ff-only 2>/dev/null || true
    else
        local args=(clone); [ -n "$branch" ] && args+=(-b "$branch")
        run_with_retry git "${args[@]}" "$url" "$dest"
    fi
}
_flat_pinned() {  # url dest ref        upstream third-party -> pinned
    local url=$1 dest=$2 ref=$3
    _clear_stale "$dest"
    [ -d "$dest/.git" ] || run_with_retry git clone "$url" "$dest"
    git -C "$dest" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || git -C "$dest" fetch origin --tags
    git -C "$dest" checkout --force "$ref"
}
_link() {  # deep-path  flat-checkout   (idempotent symlink)
    local deep=$1 flat=$2
    [ -L "$deep" ] && [ "$(readlink "$deep")" = "$flat" ] && return 0
    rm -rf "$deep"; mkdir -p "$(dirname "$deep")"; ln -s "$flat" "$deep"
}

# Clone data_substrate top-level only (submodules are flattened separately, not inited here).
clone_data_substrate() {
    local ds="$ELOQDB_DATA_SUBSTRATE"
    # _flat_latest rewrites eloqdata/ltzhang origins to SSH form (eloq_ssh_url), so an existing
    # checkout's origin won't textually match $ELOQDB_DATA_SUBSTRATE_REPO (https) — compare against
    # both the SSH-rewritten and original forms to avoid spuriously wiping a healthy clone.
    local origin; origin="$(git -C "$ds" remote get-url origin 2>/dev/null || true)"
    local want_ssh; want_ssh="$(eloq_ssh_url "$ELOQDB_DATA_SUBSTRATE_REPO")"
    if [ -d "$ds/.git" ] && [ -n "$origin" ] \
       && [ "$origin" != "$want_ssh" ] && [ "$origin" != "$ELOQDB_DATA_SUBSTRATE_REPO" ]; then
        eloqdb_warn "data_substrate origin ($origin) differs from $want_ssh — re-cloning"
        rm -rf "$ds"
    fi
    _flat_latest "$ELOQDB_DATA_SUBSTRATE_REPO" "$ds" "$ELOQDB_DATA_SUBSTRATE_BRANCH"
    # We manage submodules as flat checkouts + symlinks, NOT via git. Drop git's submodule object
    # stores so they don't accumulate duplicate copies (e.g. tx-log-protos under both tx_service
    # and log_service). The build reads the symlinked working tree, not .git/modules.
    rm -rf "$ds/.git/modules"
}

# Fetch data_substrate's sub-deps as REAL checkouts under dependencies/ — NO symlinks, and never
# pulled during the build (the eloqdata CMake is patched on lintao-mod to consume these paths and
# default GIT_SUBMODULE=OFF). Each dep has a SINGLE checkout:
#   third_party/abseil-cpp                 -> consumed via -DELOQ_ABSEIL_DIR
#   data_substrate/tx-log-protos           -> consumed via -DELOQ_TXLOG_PROTO_DIR (shared by
#                                             tx_service + log_service)
#   data_substrate/eloqstore               -> consumed via -DELOQSTORE_PARENT_DIR
#   data_substrate/log_service             -> used at its natural path
#   data_substrate/eloqstore/external/{concurrentqueue,inih} -> eloqstore-private, at their
#                                             natural in-tree path (real checkouts, pinned)
fetch_substrate_deps() {
    local ds="$ELOQDB_DATA_SUBSTRATE" tp="$ELOQDB_THIRD_PARTY"
    eloqdb_log "fetching data_substrate sub-deps as real checkouts (no symlinks)"
    # Remove any directory symlinks left by the previous (symlink-based) layout so real checkouts
    # can land. `rm -f` only unlinks symlinks; real dirs are left for _flat_* to manage.
    local lnk
    for lnk in "$ds/tx_service/abseil-cpp" "$ds/tx_service/tx-log-protos" \
               "$ds/store_handler/eloq_data_store_service/eloqstore" \
               "$ds/log_service/tx-log-protos" \
               "$ds/eloqstore/external/concurrentqueue" "$ds/eloqstore/external/inih"; do
        [ -L "$lnk" ] && rm -f "$lnk"
    done
    # abseil: one shared checkout in third_party/ (pinned to the commit tx_service vendors).
    _flat_pinned https://github.com/abseil/abseil-cpp.git "$tp/abseil-cpp" "$PIN_ABSEIL_REF"
    # Eloq-original cores: one flat checkout each under data_substrate/ (latest).
    _flat_latest https://github.com/eloqdata/tx-log-protos.git "$ds/tx-log-protos"
    _flat_latest https://github.com/eloqdata/log_service.git   "$ds/log_service"
    _flat_latest "$ELOQSTORE_REPO"                             "$ds/eloqstore" "$ELOQSTORE_BRANCH"
    # eloqstore-private external deps: real checkouts at the in-tree path eloqstore expects.
    _flat_pinned https://github.com/cameron314/concurrentqueue.git "$ds/eloqstore/external/concurrentqueue" "$PIN_CONCURRENTQUEUE"
    _flat_pinned https://github.com/benhoyt/inih.git               "$ds/eloqstore/external/inih"            "$PIN_INIH"
    # No eloqstore/external/abseil — eloqstore links tx_service's abseil under WITH_TXSERVICE.
}

build_data_substrate() {
    if dep_done data_substrate; then eloqdb_log "data_substrate already built"; return 0; fi
    [ "${ELOQDB_FETCH_ONLY:-0}" = 1 ] && { eloqdb_log "fetch-only: substrate sources ready, skipping build"; return 0; }
    local bld="$ELOQDB_BUILD/substrate/data_substrate"
    # One shared lib bakes in ONE product identity (metrics/branches gated on ELOQ_MODULE_*).
    local module_def=""
    [ -n "$DS_MODULE" ] && module_def="-DCMAKE_CXX_FLAGS=-D${DS_MODULE}"
    eloqdb_log "building data_substrate (data_store=$DS_DATA_STORE, module=${DS_MODULE:-none}, cloud_storage=$DS_WITH_CLOUD_STORAGE)"
    # Dependency dirs point at the single shared checkouts (no symlinks); GIT_SUBMODULE=OFF so the
    # build never pulls submodules.
    local dir_flags; mapfile -t dir_flags < <(eloq_substrate_dir_flags)
    cmake -S "$ELOQDB_DATA_SUBSTRATE" -B "$bld" \
        -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo -DGIT_SUBMODULE=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        "${dir_flags[@]}" \
        -DWITH_DATA_STORE="$DS_DATA_STORE" -DWITH_CLOUD_STORAGE="$DS_WITH_CLOUD_STORAGE" $module_def
    cmake --build "$bld" -j "$ELOQDB_JOBS"
    cmake --install "$bld"
    dep_mark_done data_substrate
    eloqdb_log "data_substrate layer complete."
}

[ "${ELOQDB_FETCH_ONLY:-0}" = 0 ] && check_deps_layer
# Always ensure the source tree is set up (idempotent), even if the build is cached — products
# build data_substrate inline against this same checkout.
clone_data_substrate
fetch_substrate_deps
build_data_substrate
