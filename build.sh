#!/usr/bin/env bash
# eloq_build_env umbrella build orchestrator — a 3-layer build:
#
#   layer 1: deps           (third-party + eloqdata forks)   scripts/deps.sh
#   layer 2: data_substrate (the shared Eloq core)           scripts/substrate.sh
#   layer 3: projects        (eloqkv / eloqsql / eloqdoc)     projects/*/build.sh
#
# Each layer depends on the one below it. Invoke a single layer or the whole stack:
#
#   ./build.sh                  # all layers: deps -> substrate -> projects
#   ./build.sh --deps-only      # layer 1 only
#   ./build.sh --data-substrate # layer 2 only (requires layer 1 already built)
#   ./build.sh --product eloqkv # all layers, projects scoped to eloqkv
#   ./build.sh --with-tests     # (layer 1) also build test deps
#   ./build.sh --fetch-only     # clone/download all sources, skip all builds
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
source "$HERE/env.sh"
source "$HERE/_scripts/common.sh"

eloqdb_banner

_usage() {
    cat <<'EOF'
Usage: build.sh [OPTIONS]

Builds all enabled Eloq products (manifest.toml) and their shared
dependencies into install/ — no sudo required.

Layer options:
  --all                 All three layers: deps → substrate → products  (required)
  --deps-only           Layer 1: shared third-party dependencies only
  --data-substrate      Layer 2: data_substrate core only (needs layer 1)

Product filter:
  --product <name>      Scope to one product: eloqkv | eloqsql | eloqdoc | eloquentdb

Build modifiers:
  --fetch-only          Clone/download all sources; skip all compilation
  --with-tests          Also build test deps (Catch2, FakeIt)

Clean:
  --clean               Remove build trees only (install/ and sources kept)
  --clean install       Remove build/ + install/ (full rebuild next run)
  --clean distclean     Remove everything generated (build/, install/, sources, projects/)
  --clean <name>        Reset one dep/layer by name (e.g. brpc, data_substrate, eloqkv)

Environment variables:
  ELOQDB_WITH_CLOUD=1   Include the full cloud stack (aws-sdk-cpp, google-cloud-cpp,
                        rocksdb-cloud) and EloqStore's S3/GCS backend

Other:
  --help                Show this help

Examples:
  build.sh --all                          # full build (all enabled products)
  build.sh --all --product eloqkv         # build eloqkv only
  build.sh --all --fetch-only             # pull all sources, no compilation
  build.sh --deps-only --fetch-only       # fetch dependency sources only
  build.sh --clean                        # wipe build trees, keep libs
  build.sh --clean distclean              # wipe everything
  ELOQDB_WITH_CLOUD=1 build.sh --all      # build with cloud storage backends
EOF
}

MANIFEST="$ROOT/manifest.toml"
[ -f "$MANIFEST" ] || eloqdb_die "manifest not found: $MANIFEST"

[ $# -eq 0 ] && { _usage; exit 0; }

LAYER=""; ONLY_PRODUCT=""; WITH_TESTS=0; FETCH_ONLY=0; CLEAN_TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --all)            LAYER="all" ;;
        --deps-only)      LAYER="deps" ;;
        --data-substrate) LAYER="substrate" ;;
        --product)        ONLY_PRODUCT="${2:-}"; shift ;;
        --with-tests)     WITH_TESTS=1 ;;
        --fetch-only)     FETCH_ONLY=1 ;;
        --clean)          CLEAN_TARGET="${2:-build}"
                          case "${2:-}" in --*|"") ;; *) shift ;; esac ;;
        --help|-h)        _usage; exit 0 ;;
        *) eloqdb_die "unknown arg: $1 (try --help)" ;;
    esac
    shift
done
export ELOQDB_FETCH_ONLY="$FETCH_ONLY"
export ELOQDB_ORCHESTRATED=1

# --- tiny TOML reader: value of <key> within section [<section>] -------------
toml_get() {
    local section=$1 key=$2
    awk -v sec="[$section]" -v k="$key" '
        $0==sec {ins=1; next}
        /^\[/   {ins=0}
        ins && $1==k {
            line=$0
            sub(/^[^=]*=[ \t]*/,"",line)
            if (line ~ /^"/)      { sub(/^"/,"",line); sub(/".*$/,"",line) }
            else if (line ~ /^'"'"'/) { sub(/^'"'"'/,"",line); sub(/'"'"'.*$/,"",line) }
            else                  { sub(/[ \t]*#.*$/,"",line); sub(/[ \t]+$/,"",line) }
            print line; exit
        }' "$MANIFEST"
}
list_products() { grep -oE '^\[products\.[a-zA-Z0-9_-]+\]' "$MANIFEST" | sed -E 's/^\[products\.(.*)\]/\1/'; }

DEF_DS="$(toml_get defaults with_data_store)"; DEF_DS="${DEF_DS:-ELOQDSS_ELOQSTORE}"
DEF_LS="$(toml_get defaults with_log_state)"; DEF_LS="${DEF_LS:-ROCKSDB}"

# --- determine enabled products ---------------------------------------------
ENABLED=()
for p in $(list_products); do
    if [ -n "$ONLY_PRODUCT" ]; then
        [ "$p" = "$ONLY_PRODUCT" ] && ENABLED+=("$p")
    else
        [ "$(toml_get "products.$p" enabled)" = "true" ] && ENABLED+=("$p")
    fi
done
[ "$LAYER" = "all" ] && [ ${#ENABLED[@]} -eq 0 ] && eloqdb_die "no enabled products in manifest (or --product not found)"
eloqdb_log "enabled products: ${ENABLED[*]:-<none>}  (layer: $LAYER)"

# --- backend/module derived from the first enabled product (for the substrate layer) ---
DEPS_DS="$DEF_DS"; DEPS_MODULE=""
if [ ${#ENABLED[@]} -gt 0 ]; then
    _p0="${ENABLED[0]}"; _ds0="$(toml_get "products.$_p0" with_data_store)"
    DEPS_DS="${_ds0:-$DEF_DS}"
    case "$_p0" in
        eloqkv)  DEPS_MODULE="ELOQ_MODULE_ELOQKV" ;;
        eloqsql) DEPS_MODULE="ELOQ_MODULE_ELOQSQL" ;;
        eloqdoc) DEPS_MODULE="ELOQ_MODULE_ELOQDOC" ;;
        eloquentdb) DEPS_MODULE="ELOQ_MODULE_ELOQKV" ;;  # combined kv+sql binary; bake kv's labels
    esac
    [ ${#ENABLED[@]} -gt 1 ] && eloqdb_warn "multiple products enabled; shared data_substrate baked with $_p0's module ($DEPS_MODULE) — others get its metric labels"
fi

# --- cloud deps: one master switch (ELOQDB_WITH_CLOUD), no per-backend granularity ----------
# ON  -> pull the whole cloud stack (aws-sdk-cpp + google-cloud-cpp + rocksdb-cloud) via deps.sh's
#        --with-cloud shorthand, AND compile EloqStore's optional S3/GCS cloud-storage backend
#        (-DWITH_CLOUD_STORAGE=ON, gated on lintao-mod via ELOQSTORE_WITH_CLOUD).
# OFF -> pull none of it; EloqStore's cloud-storage backend compiles to a stub (no AWS SDK link).
#        A manifest that selects an explicit cloud backend (DYNAMODB/BIGTABLE/ELOQDSS_ROCKSDB_CLOUD_*)
#        needs ELOQDB_WITH_CLOUD=1 — those backends have no local-only fallback.
CLOUD_FLAGS=(); WITH_CLOUD_STORAGE="OFF"
if [ "$ELOQDB_WITH_CLOUD" = 1 ]; then
    CLOUD_FLAGS=(--with-cloud)
    WITH_CLOUD_STORAGE="ON"
fi
export ELOQDB_WITH_CLOUD_STORAGE="$WITH_CLOUD_STORAGE"
TEST_FLAG=""; [ "$WITH_TESTS" = 1 ] && TEST_FLAG="--with-tests"

# AWS components: eloqstore needs s3; widen for DynamoDB.
AWS_COMPONENTS="s3"
for p in "${ENABLED[@]}"; do
    ds="$(toml_get "products.$p" with_data_store)"; ds="${ds:-$DEF_DS}"
    case "$ds" in *DYNAMODB*) AWS_COMPONENTS="dynamodb;s3;kinesis" ;; esac
done
export ELOQDB_AWS_COMPONENTS="$AWS_COMPONENTS"

# ===== layer functions ======================================================
layer_deps() {
    eloqdb_log "=== LAYER 1: deps ${CLOUD_FLAGS[*]:+(${CLOUD_FLAGS[*]})} ==="
    bash "$HERE/_scripts/deps.sh" "${CLOUD_FLAGS[@]}" $TEST_FLAG
}
layer_substrate() {
    eloqdb_log "=== LAYER 2: data_substrate (backend=$DEPS_DS, module=${DEPS_MODULE:-none}) ==="
    ELOQDB_WITH_DATA_STORE="$DEPS_DS" ELOQDB_ELOQ_MODULE="$DEPS_MODULE" bash "$HERE/_scripts/substrate.sh"
}
layer_projects() {
    [ ${#ENABLED[@]} -eq 0 ] && eloqdb_die "no enabled products to build"
    for p in "${ENABLED[@]}"; do
        local repo branch adapter ds ls recurse skip
        repo="$(toml_get "products.$p" repo)"; branch="$(toml_get "products.$p" branch)"
        adapter="$(toml_get "products.$p" adapter)"
        [ -n "$repo" ] || eloqdb_die "no repo for product $p"
        # Umbrella products (recurse_submodules=false, e.g. eloquentdb) get a top-level-only clone;
        # their adapter wires submodule paths itself. Normal products clone top-level + their
        # project-local submodules, but NOT the shared data_substrate (consumed from dependencies/).
        recurse="$(toml_get "products.$p" recurse_submodules)"
        if [ "$recurse" = "false" ]; then
            clone_latest "$repo" "$ELOQDB_PROJECTS/$p" "$branch" 1
        else
            clone_product "$repo" "$ELOQDB_PROJECTS/$p" "$branch"
        fi
        if [ "$FETCH_ONLY" = 1 ]; then
            eloqdb_log "fetch-only: sources at $ELOQDB_PROJECTS/$p (skipping build)"
            continue
        fi
        ds="$(toml_get "products.$p" with_data_store)"; export ELOQDB_WITH_DATA_STORE="${ds:-$DEF_DS}"
        ls="$(toml_get "products.$p" with_log_state)"; export ELOQDB_WITH_LOG_STATE="${ls:-$DEF_LS}"
        eloqdb_log "=== LAYER 3: product $p ==="
        bash "$ROOT/$adapter"
    done
}

# ===== dispatch =============================================================
if [ -n "$CLEAN_TARGET" ]; then
    bash "$HERE/_scripts/clean.sh" "$CLEAN_TARGET"
    exit 0
fi
[ -z "$LAYER" ] && eloqdb_die "no action specified — use --all, --deps-only, --data-substrate, or --clean (try --help)"
case "$LAYER" in
    deps)      layer_deps ;;
    substrate) layer_substrate ;;
    all)       layer_deps; layer_substrate; layer_projects ;;
esac
eloqdb_log "Done (layer: $LAYER). Artifacts under $ELOQDB_BUILD and $ELOQDB_PREFIX."
