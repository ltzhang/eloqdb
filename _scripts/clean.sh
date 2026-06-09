#!/usr/bin/env bash
# Clean eloq_build_env build artifacts. There is no `make clean` — this is the umbrella equivalent.
#
#   scripts/clean.sh                 # build trees only  (keep install/ libs + sources)  [default]
#   scripts/clean.sh install         # build/ + install/ (force a full rebuild; keep sources)
#   scripts/clean.sh <name>          # reset ONE dep/layer: its done-marker + build tree
#                                    #   e.g. data_substrate, brpc, abseil, eloqkv
#   scripts/clean.sh distclean       # everything generated: build/ install/ deps sources + projects/
#
# Reset a single dep and it rebuilds on the next ./scripts/build.sh; the rest is skipped via markers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/common.sh"

target="${1:-build}"

case "$target" in
    build)
        eloqdb_log "clean: build trees (install/ libs and sources kept)"
        rm -rf "${ELOQDB_BUILD:?}/"* 2>/dev/null || true
        ;;
    install)
        eloqdb_log "clean: build/ + install/ (sources kept; full rebuild next time)"
        rm -rf "${ELOQDB_BUILD:?}" "${ELOQDB_PREFIX:?}"
        ;;
    distclean)
        eloqdb_log "distclean: build/, install/, dependency sources, and projects/"
        rm -rf "${ELOQDB_BUILD:?}" "${ELOQDB_PREFIX:?}" \
               "${ELOQDB_THIRD_PARTY:?}/"* "${ELOQDB_SUBMODULES:?}/"* \
               "${ELOQDB_DATA_SUBSTRATE:?}" "${ELOQDB_PROJECTS:?}/"*
        ;;
    *)
        # Reset a single dep/layer/product by name.
        eloqdb_log "clean: resetting '$target' (marker + build tree) — it rebuilds next run"
        rm -f  "$ELOQDB_PREFIX/.eloqdb/$target.done"
        rm -rf "$ELOQDB_BUILD/deps/$target" "$ELOQDB_BUILD/deps/$target-cpp" \
               "$ELOQDB_BUILD/substrate/$target" "$ELOQDB_BUILD/$target"
        ;;
esac
eloqdb_log "clean done."
