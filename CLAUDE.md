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
2. **No directory symlinks.** The build must not stitch the source tree together with symbolic
   links to directories. Products and the core find the shared sources in `dependencies/` and the
   shared libraries in `install/` **directly** — via `CMAKE_PREFIX_PATH`, explicit source paths,
   or build-script variables — never through a symlinked submodule path.
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
libraries are pulled in **only** when an enabled product+backend needs them, computed per backend
by the orchestrator (`--with-aws` / `--with-gcp` / `--with-rocksdb-cloud`):

| Dependency           | Default | Required when |
|----------------------|---------|---------------|
| rocksdb              | Keep    | `WITH_LOG_STATE=ROCKSDB` (default) |
| **aws-sdk-cpp (s3)** | **Keep** | **EloqStore (default)**, DynamoDB, any S3 backend — eloqstore hard-requires `find_package(AWSSDK COMPONENTS s3)`. Scoped to just the needed components via `ELOQDB_AWS_COMPONENTS` (default `s3`). |
| rocksdb-cloud        | Drop    | `ELOQDSS_ROCKSDB_CLOUD_S3` / `_GCS` backends |
| google-cloud-cpp     | Drop    | `BIGTABLE`, or any cloud-GCS backend |

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

## eloqdoc build constraint: locked to MongoDB 4.0.3 + SCons + Python 2

eloqdoc is a MongoDB fork **licensing-locked to MongoDB 4.0.3** — the last AGPL release. MongoDB
relicensed to SSPL on 2018-10-16, so every later version (4.2+), including the modern Bazel build,
is SSPL and **cannot be used in an open-source project**. We stay on the 4.0.x era: **SCons +
vendored SCons 2.5.0 + Python 2.7**.

- **Do not convert the MongoDB server build to CMake.** It is upstream MongoDB (~503 `env.Library`
  targets, a custom `scons/libdeps.py` graph, 48 `.idl` codegen files, ~25 vendored libs) — a
  person-months port that wouldn't even remove the Python 2 dependency (the IDL compiler is Python
  regardless). Only the Eloq-authored module (`src/mongo/db/modules/eloq/`) is — and stays — CMake.
- The real blocker is **Python 2 obsolescence** (gone from Ubuntu 24.04). **Decision: A now, B
  later.**
  - **Option A — isolate Python 2.7 (NOW).** Provision a hermetic Python 2.7 (`pyenv 2.7.18`) into
    a local prefix — sudo-free. The `eloqdoc.sh` adapter activates Py2.7 + vendored SCons, then
    builds against the shared prefix. Upstream build stays intact.
  - **Option B — port build scripts to Python 3 (LATER).** `2to3` over `SConstruct` +
    `buildscripts/` + the IDL compiler, bump vendored SCons 2.5 → 3.x/4.x. Stays on AGPL 4.0.3 and
    removes Python 2 permanently. (Cannot copy MongoDB 4.4's own Py3 port — that's SSPL.)

## Status

- **No directory symlinks in the build wiring (target met).** `substrate.sh` fetches every core
  sub-dep as a single real checkout under `dependencies/` and passes `eloq_substrate_dir_flags`
  (`-DELOQ_ABSEIL_DIR`, `-DELOQ_TXLOG_PROTO_DIR`, `-DELOQSTORE_PARENT_DIR`, `-DDATA_SUBSTRATE_DIR`).
  `clone_product` clones products top-level + their project-local submodules but **never**
  `data_substrate`, with no recursive pull of the shared core. The eloqdata CMake was patched on
  `lintao-mod` (tx_service, eloqkv, eloqsql, eloqdoc) to make every in-tree submodule path
  overridable; eloqstore defaults `GIT_SUBMODULE=OFF`. (Remaining symlinks are intra-dependency
  artifacts — rocksdb `.so` version links, grpc/liburing repo symlinks — not our wiring.)
- **Builds (default ELOQSTORE + ROCKSDB backend):**
  - **eloqkv** — builds end-to-end ✅ (0 symlinks, 0 submodule pulls).
  - **eloqsql** — builds end-to-end ✅ (`mariadbd`/`mysqld`). Needs system `bison` (apt) and the
    adapter adds `-I$ELOQDB_PREFIX/include` so MariaDB's `sql/` finds brpc's `<bthread/…>` headers.
  - **eloqdoc** — the Eloq cmake module (incl. inline data_substrate) builds ✅. The MongoDB SCons
    server stage is **ON HOLD** pending a Python 2-vs-3 decision (Option A vs B above): it needs
    the Py2.7 toolchain (`bz2`/`_sqlite3`/`ctypes` + `Cheetah`), and we may instead port the build
    scripts to Python 3 (Option B). The symlink/data_substrate side is already done.
  - **eloquentdb** — builds end-to-end ✅ (unified `eloqdb` binary = eloqkv + eloqsql + core).
    Engines pointed at `projects/<engine>` via `-DELOQKV_DIR`/`-DELOQSQL_DIR`; needed three real
    (non-symlink) fixes on `lintao-mod`: eloqsql feature_summary non-fatal in library mode (CURL
    false-flag), `CPATH=install/include` in the adapter (eloqkv_lib loses the prefix include in
    converged mode → glog), and C++20 (eloqkv headers use `std::atomic<shared_ptr>`).
- **System build-tools are apt-installed by the user** (bison, flex, …), not built into `install/`
  — that prefix holds libraries only. The lone sanctioned local toolchain is the hermetic
  Python 2.7 (pyenv) for eloqdoc.
- **Build parallelism is memory-capped** (`env.sh`: `ELOQDB_JOBS=min(nproc, ½·RAM_GB, 8)`) so the
  heavy C++ TUs don't OOM-kill the build; lower `ELOQDB_JOBS=4` if a build still dies suddenly.
