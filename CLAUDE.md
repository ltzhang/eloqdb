# EloqDB

## Goal

EloqDB is the umbrella that gives the Eloq product family a **clean, fast, reproducible,
sudo-free build** from one directory. It replaces the original per-product
`install_dependency_ubuntu2404.sh` scripts (which used `sudo` and installed into system root
locations) with a single shared build into a local prefix.

Products built under this umbrella:

| Product     | Compatibility | Build system | Notable per-product deps |
|-------------|---------------|--------------|--------------------------|
| eloqkv      | Redis         | CMake        | `crcspeed` |
| eloqsql     | MariaDB       | CMake        | `libmariadb`, **vendored `rocksdb`**, `wsrep-lib`, `wolfssl`, `libmarias3`, `columnstore` |
| eloqdoc     | MongoDB 4.0.3 | SCons + Py2  | vendored MongoDB `src/third_party/*` |
| eloquentdb  | unified `eloqdb` binary | CMake | links **eloqkv + eloqsql** + the shared core into one executable |

All products share the same core (**`eloqdata/tx_service`**, a.k.a. *data_substrate*) and overlap
heavily on the heavy libraries (brpc, braft, protobuf, abseil, glog, mimalloc, rocksdb, …).

## The target build architecture (what "better" means)

This is the design contract every build script must satisfy. It is the active objective — some
of it is in place, some is still being migrated (see **Status**).

1. **One checkout per dependency, all under `dependencies/`.** Every common submodule /
   third-party library is checked out exactly once into `dependencies/` (classified by origin —
   see below) and built once into the shared prefix `install/`. No dependency is buried as a
   nested submodule under a product or under another dependency.
2. **Avoid directory symlinks as build wiring.** The build should not *routinely* stitch the
   source tree together with symbolic links to directories — products and the core find the
   shared sources in `dependencies/` and the shared libraries in `install/` **directly**, via
   `CMAKE_PREFIX_PATH`, explicit source paths, or build-script variables, not through a
   symlinked submodule path. The judicious exception: when upstream *hardcodes* an in-tree path
   (e.g. eloqdoc's vendored MongoDB `#include`s ~76 references to
   `mongo/db/modules/eloq/data_substrate/...`, baked into both Eloq and core mongo sources, with
   no override hook), a single targeted symlink from that path to the shared `dependencies/`
   checkout is the pragmatic fix — see `link_data_substrate_into_eloq_module` in
   `scripts/projects/eloqdoc.sh`. Reach for this only when a real path/flag override isn't
   possible; default to the direct-reference approach everywhere else.
3. **No submodule pulling during the build.** The build never runs `git submodule update --init`
   and never clones with `--recurse-submodules`. Each repo is cloned **top-level only**; the
   submodule content it expects is supplied from `dependencies/`. Any CMake/SCons logic that would
   `git submodule update` is patched (on the repo's `lintao-mod` branch) to consume the shared
   checkout instead — e.g. eloqstore's `GIT_SUBMODULE` now defaults **OFF**.
4. **No pulls into random places.** The build must not deposit a freshly-cloned dependency
   somewhere inside a product/dependency tree (the classic failure: `eloqstore/external/abseil`
   appearing mid-configure). Sources live in `dependencies/`, build trees in `build/`, installed
   artifacts in `install/` — nowhere else.

Everything is **sudo-free**: nothing is written outside this repo.

## Directory Layout

```
eloqdb/
  manifest.toml      # which products to build, their refs/build-system, feature flags
  env.sh             # `source` it -> exports the shared-prefix contract (ELOQDB_*)
  projects/          # product checkouts, pulled optionally (empty until selected)
    eloqkv/  eloqsql/  eloqdoc/  eloquentdb/
  dependencies/      # ALL common deps, one checkout each, classified by origin:
    third_party/     #   upstream used as-is (unmodified)
    sub_modules/     #   upstream forked & modified by eloqdata
    data_substrate/  #   original Eloq projects (Eloq's own code, not a fork)
  scripts/
    build.sh         # umbrella orchestrator (deps -> substrate -> products)
    deps.sh          # builds the shared third-party + eloqdata-fork deps
    substrate.sh     # builds the shared core (data_substrate)
    projects/<p>.sh  # per-product build adapter (cmake vs scons)
    lib/common.sh    # shared helpers (clone, build, link policy)
  build/             # all build trees: build/deps/<dep>, build/<product>
  install/           # shared local prefix (include/ lib/ bin/) — replaces /usr/local, no sudo
```

### Dependency classification (by origin)

Every external dependency goes in exactly one bucket under `dependencies/`, decided by **who owns
it and whether it was modified**:

| Bucket | Rule | Examples |
|--------|------|----------|
| `third_party/` | **Original upstream, used as-is.** | abseil, concurrentqueue, inih, protobuf, rocksdb, lua, re2, crc32c, grpc, prometheus-cpp, json, liburing, Catch2, FakeIt, aws-sdk-cpp, google-cloud-cpp |
| `sub_modules/` | **Upstream forked _and modified_ by eloqdata.** | brpc, braft, glog, mimalloc, cuckoofilter, rocksdb-cloud |
| `data_substrate/` | **Original Eloq projects** — Eloq's own code, not a fork. | data_substrate (tx_service core), log_service, tx-log-protos, eloqstore |

### Repo ownership & the `lintao-mod` branch

**Everything Eloq comes from `eloqdata/`; the only `ltzhang/` repo is this umbrella.** All
products, the core, and the Eloq forks are pulled from `eloqdata/` (e.g. `eloqdata/tx_service`,
`eloqdata/eloqstore`, `eloqdata/eloqkv`). Our **modifications to those build scripts** — the
patches that make them consume `dependencies/` and stop pulling submodules — live on the
**`lintao-mod` branch inside each eloqdata repo**, keeping their default branches pristine. The
build prefers `ELOQDB_MOD_BRANCH` (`lintao-mod`) when the remote has it, else the default branch
(`eloq_pick_branch` in `scripts/lib/common.sh`); the working tree may be left on a local
`lintao-mod` until the branch is pushed. The umbrella itself (`ltzhang/eloqdb`) is the sole
`ltzhang/` repo — original orchestration code, not a fork — and our work on it lives on its
`main` branch.

## Versioning policy

- **`eloqdata/` repos → always latest** (default-branch HEAD, preferring `lintao-mod` where it
  exists), **even when a submodule gitlink or dependency script pins an older commit/tag** —
  those pins are informational and we deliberately follow HEAD. Covers the products
  (`eloqdata/{eloqkv,eloqsql,eloqdoc,eloquentdb}`) and the forks + core (`eloqdata/{brpc, braft,
  glog, mimalloc, cuckoofilter, rocksdb-cloud, tx_service, eloqstore, log_service,
  tx-log-protos}`). The `ltzhang/eloqdb` umbrella follows the same rule.
- **All other third-party repos → pinned** to known-good versions (listed in `BUILD-PLAN.md`), so
  an upstream release can't break the build.

## System vs. built dependencies (boundary)

We do **not** rebuild the base toolchain or common system libraries — the build **assumes the
system prerequisites are present** (installed via `apt`, outside this repo's scope): `gcc/g++`,
`make`, `cmake`, `ninja`, `pkg-config`, plus libs like `libssl-dev`, `zlib1g-dev`,
`libgflags-dev`, `libleveldb-dev`, `libsnappy/lz4/zstd/bz2-dev`. These live in the README's
prerequisite list. Only the heavy / pinned / forked dependencies are built locally into `install/`.
The full inventory, versions, sources, and build order live in **`BUILD-PLAN.md`**.

## Minimal default build (feature-gated cloud deps)

The default config is `WITH_DATA_STORE=ELOQDSS_ELOQSTORE` + `WITH_LOG_STATE=ROCKSDB`. Heavy cloud
libraries are an all-or-nothing bundle gated by a single top-level switch, **`ELOQDB_WITH_CLOUD`**
in `env.sh` (default `0` — local-only build, no AWS/GCP at all):

| Dependency           | `ELOQDB_WITH_CLOUD=0` (default) | `ELOQDB_WITH_CLOUD=1` |
|----------------------|---------------------------------|------------------------|
| rocksdb              | Keep (always — `WITH_LOG_STATE=ROCKSDB` default) | Keep |
| aws-sdk-cpp (s3)     | Drop | Built — components scoped via `ELOQDB_AWS_COMPONENTS` (default `s3`, widens for DynamoDB) |
| google-cloud-cpp     | Drop | Built |
| rocksdb-cloud        | Drop | Built |

`scripts/build.sh` turns the single switch into `deps.sh --with-cloud` (its existing shorthand for
`--with-aws --with-gcp --with-rocksdb-cloud`) — no separate per-backend granularity; **on** pulls
the whole stack, **off** pulls none of it.

### `ELOQDB_WITH_CLOUD` — local-only vs. cloud build (env.sh)

EloqStore's S3/GCS object-storage backend (`StoreMode::Cloud`) is **runtime-optional** —
[eloq_store.cpp](https://github.com/eloqdata/eloqstore/blob/main/src/eloq_store.cpp) only spins up
`CloudStorageService` when configured for cloud mode — but upstream it was wired as a **hard
compile-time** dependency (`find_package(AWSSDK REQUIRED COMPONENTS s3)`, with
`storage/cloud_backend.cpp` directly `#include <aws/s3/...>`). On `lintao-mod` we gated this
behind a new `WITH_CLOUD_STORAGE` CMake option (default **ON**, matching upstream): when **OFF**,
`cloud_backend.cpp` compiles to a small stub (`CreateBackend()` → `LOG(FATAL)`, never reached in a
local-only deployment) instead of linking the AWS S3 client, defined via `ELOQSTORE_WITH_CLOUD`
(patched in both `eloqdata/eloqstore` — its own `CMakeLists.txt` — and `eloqdata/tx_service`'s
`store_handler/eloq_data_store_service/build_eloq_store.cmake`, the path the umbrella actually
uses via `WITH_TXSERVICE`).

`env.sh` exports `ELOQDB_WITH_CLOUD` (default `0`): `scripts/build.sh` derives both
`deps.sh --with-cloud` and `-DWITH_CLOUD_STORAGE=ON|OFF` (passed through to `substrate.sh`) from
it directly — one switch controls the whole cloud stack and EloqStore's cloud-storage backend
together. **Caveat:** a manifest entry that explicitly selects `DYNAMODB` / `BIGTABLE` /
`ELOQDSS_ROCKSDB_CLOUD_*` has no local-only fallback — it needs `ELOQDB_WITH_CLOUD=1` too, or the
deps layer won't have what its `find_package` calls require. Set `export ELOQDB_WITH_CLOUD=1`
before sourcing `env.sh` to build the full cloud stack and enable EloqStore's cloud-backed storage.

Backend options: `WITH_DATA_STORE` ∈ {`ELOQDSS_ELOQSTORE`, `ELOQDSS_ROCKSDB`,
`ELOQDSS_ROCKSDB_CLOUD_S3/_GCS`, `DYNAMODB`, `BIGTABLE`}; `WITH_LOG_STATE` ∈ {`MEMORY`, `ROCKSDB`,
`ROCKSDB_CLOUD_S3/_GCS`}.

## Build flow (`scripts/build.sh`)

1. Read `manifest.toml`; clone enabled products into `projects/` (**top-level only**, no submodule
   recursion).
2. Build the **union of dependencies** across enabled products+backends **once** into `install/`
   (cloud stack only if a backend needs it).
3. Build the shared core (`data_substrate`) once.
4. Build each enabled product via its adapter (`scripts/projects/<name>.sh`): CMake products get
   `-DCMAKE_PREFIX_PATH=$ELOQDB_PREFIX`; eloqdoc's SCons gets the same prefix. Pinned project-local
   deps (e.g. eloqsql's vendored rocksdb) are searched ahead of the shared prefix.

### eloquentdb specifics

eloquentdb is itself an umbrella whose CMake links eloqkv + eloqsql + the core into one `eloqdb`
binary. Upstream it declares each engine as a pinned git submodule; here those are **not** pulled —
its adapter points each engine at the umbrella's own `projects/<engine>` checkout and the shared
core, driven by eloquentdb's `.gitmodules`, following latest.

## eloqdoc build constraint: locked to MongoDB 4.0.3 + SCons (now on Python 3)

eloqdoc is a MongoDB fork **licensing-locked to MongoDB 4.0.3** — the last AGPL release. MongoDB
relicensed to SSPL on 2018-10-16, so every later version (4.2+), including the modern Bazel build,
is SSPL and **cannot be used in an open-source project**. We stay on the 4.0.x era's **SCons**
build — but, as of `lintao-mod`, ported to **Python 3** (see "Decision" below).

- **Do not convert the MongoDB server build to CMake.** It is upstream MongoDB (~503 `env.Library`
  targets, a custom `scons/libdeps.py` graph, 48 `.idl` codegen files, ~25 vendored libs) — a
  person-months port that wouldn't even remove the Python 2 dependency (the IDL compiler is Python
  regardless). Only the Eloq-authored module (`src/mongo/db/modules/eloq/`) is — and stays — CMake.
- The real blocker was **Python 2 obsolescence** (gone from Ubuntu 24.04). Two options were
  weighed: **Option A** — isolate a hermetic Python 2.7 (`pyenv`) and keep the vendored SCons
  2.5.0 untouched; or **Option B** — port the build scripts themselves to Python 3 and drop the
  vendored SCons for a modern one. **Decision: B, done.** `2to3`-style fixes (str/bytes,
  `dict.iteritems`→`.items`, `print` statements, the removed `'rU'` file mode, …) were applied
  across `SConstruct`, `scons/`, `scripts/buildscripts/` (incl. the IDL compiler) and the
  generator scripts (`generate_error_codes.py`, `generate_stop_words.py`, the FTS unicode
  generators, …) on `lintao-mod`; the vendored SCons 2.5.0 engine was dropped in favor of a
  pip-installed modern SCons (4.10.x) running under a hermetic Python 3 venv
  (`scripts/projects/eloqdoc.sh`'s `ensure_eloqdoc_venv`, `.venv-eloqdoc/`). `generate_error_codes.py`
  needs `Cheetah.Template`; the original `Cheetah` is Python-2-only and unmaintained, so the venv
  installs **Cheetah3** (its actively-maintained Python 3 drop-in fork) instead. This removes the
  Python 2 dependency permanently while staying on AGPL 4.0.3. (Cannot copy MongoDB 4.4's own Py3
  port — that's SSPL.)

## Status

- **Directory symlinks in the build wiring kept to a single, judicious exception.**
  `substrate.sh` fetches every core sub-dep as a single real checkout under `dependencies/` and
  passes `eloq_substrate_dir_flags` (`-DELOQ_ABSEIL_DIR`, `-DELOQ_TXLOG_PROTO_DIR`,
  `-DELOQSTORE_PARENT_DIR`, `-DDATA_SUBSTRATE_DIR`). `clone_product` clones products top-level +
  their project-local submodules but **never** `data_substrate`, with no recursive pull of the
  shared core. The eloqdata CMake was patched on `lintao-mod` (tx_service, eloqkv, eloqsql,
  eloqdoc) to make every in-tree submodule path overridable; eloqstore defaults
  `GIT_SUBMODULE=OFF`. The **one** sanctioned exception is eloqdoc's
  `link_data_substrate_into_eloq_module` (in `scripts/projects/eloqdoc.sh`): vendored MongoDB +
  the Eloq module hardcode `mongo/db/modules/eloq/data_substrate/...` across ~76 `#include`s with
  no override hook, so that single in-tree path is symlinked to the shared `dependencies/`
  checkout — see rule 2 above. (Remaining symlinks beyond that are intra-dependency artifacts —
  rocksdb `.so` version links, grpc/liburing repo symlinks — not our wiring.)
- **`ELOQDB_WITH_CLOUD` (local-only by default — see "Minimal default build" above):** required a *new* `lintao-mod`
  branch on `eloqdata/eloqstore` (it had none before — only consumed inline via tx_service's
  `build_eloq_store.cmake`) carrying the `WITH_CLOUD_STORAGE` gate in its own `CMakeLists.txt` plus
  the `ELOQSTORE_WITH_CLOUD`-guarded stub in `storage/cloud_backend.cpp`; mirrored in
  `eloqdata/tx_service`'s `lintao-mod` (`build_eloq_store.cmake`). **Not yet pushed** — until then
  `eloq_pick_branch` falls back to eloqstore's default branch, which still hard-links AWS SDK
  (`ELOQDB_WITH_CLOUD=0` would then fail at the `aws-sdk(s3)` deps-layer check or AWSSDK
  `find_package`, depending on which path resolves first).
- **Builds (default ELOQSTORE + ROCKSDB backend):**
  - **eloqkv** — builds end-to-end ✅ (0 symlinks, 0 submodule pulls).
  - **eloqsql** — builds end-to-end ✅ (`mariadbd`/`mysqld`). Needs system `bison` (apt) and the
    adapter adds `-I$ELOQDB_PREFIX/include` so MariaDB's `sql/` finds brpc's `<bthread/…>` headers.
  - **eloqdoc** — builds end-to-end ✅, including the MongoDB SCons server stage
    (`scons install-core` produces `install/bin/eloqdoc`/`eloqdoc-cli`, reporting
    `db version v0.2.6 (compatible with MongoDB version v4.0.3)`, `modules: eloq`). Got there via
    the Python 3 port (Option B, see "eloqdoc build constraint" above) plus three SConscript fixes
    in the Eloq module: (1) `SYSTEM_INCLUDE_PATH`/`CPPPATH` entries that pointed at empty
    in-tree-submodule placeholders (`store_handler/eloq_data_store_service/eloqstore`,
    `tx_service/tx-log-protos`) instead of the umbrella's real sibling checkouts
    (`$ELOQ_DATA_SUBSTRATE_ROOT/{eloqstore,tx-log-protos}`); (2) `-DCMAKE_POSITION_INDEPENDENT_CODE=ON`
    on the shared `data_substrate` build (`substrate.sh`) — its static archives are linked into
    eloqdoc's `.so` and need `-fPIC`; (3) missing link libraries for EloqStore's own dependency
    graph (`-leloqstore` — built inline by `data_substrate` but not installed to the shared
    prefix, so it's linked straight from `build/substrate/data_substrate/` — plus
    `-lprometheus-cpp-{core,pull} -luring -lcurl -ljsoncpp -lzstd -lcrypto`), all ordered **after**
    `-ldata_substrate` since the linker only pulls archive members for already-pending undefined
    symbols (eloqstore's are referenced from `data_substrate`'s `store_handler`).
  - **eloquentdb** — builds end-to-end ✅ (unified `eloqdb` binary = eloqkv + eloqsql + core).
    Engines pointed at `projects/<engine>` via `-DELOQKV_DIR`/`-DELOQSQL_DIR`; needed three real
    (non-symlink) fixes on `lintao-mod`: eloqsql feature_summary non-fatal in library mode (CURL
    false-flag), `CPATH=install/include` in the adapter (eloqkv_lib loses the prefix include in
    converged mode → glog), and C++20 (eloqkv headers use `std::atomic<shared_ptr>`).
- **System build-tools are apt-installed by the user** (bison, flex, …), not built into `install/`
  — that prefix holds libraries only. The lone sanctioned local toolchain is eloqdoc's hermetic
  Python 3 build venv (`.venv-eloqdoc/` — modern SCons + Cheetah3 + the IDL compiler's deps; see
  `ensure_eloqdoc_venv` in `scripts/projects/eloqdoc.sh`).
- **Build parallelism is memory-capped** (`env.sh`: `ELOQDB_JOBS=min(nproc, ½·RAM_GB, 8)`) so the
  heavy C++ TUs don't OOM-kill the build; lower `ELOQDB_JOBS=4` if a build still dies suddenly.
