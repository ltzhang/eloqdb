# EloqDB

## Goal

Migrate EloqKV, EloqSQL and EloqDoc and their build infrastructure into a clean, self-contained repository named **EloqDB**.

The original EloqKV repository lives in the parent directory (`../eloqkv` `../eloqdoc` `../eloqsql`). Its current build process relies on the script `eloqkv/scripts/install_dependency_ubuntu2404.sh` and related scripts in other projects, which uses `sudo` to install many dependencies into system-wide root locations. EloqKV also pulls in a number of git submodules.

## First Task: Local, sudo-free dependency builds

Rework the build so that **every dependency is built locally without `sudo`** — nothing is installed into system root directories. All libraries install into a local library directory within this repo.

## Directory Layout

```
dependencies/          # all external projects, classified by origin (see below)
    third_party/       # upstream projects used as-is (unmodified)
    sub_modules/       # upstream projects forked & modified by eloqdata
    data_substrate/    # original Eloq projects (Eloq's own code, not forks)
build/                 # all build outputs land here
```

### Dependency classification (by origin)

Every external dependency is placed in exactly one of three buckets, decided by **who owns it
and whether it was modified**:

| Bucket | Rule | Examples |
|--------|------|----------|
| `third_party/` | **Original upstream, used as-is** (taken directly, not modified). | abseil, concurrentqueue, inih, protobuf, rocksdb, lua, re2, crc32c, grpc, prometheus-cpp, Catch2, FakeIt, aws-sdk-cpp, google-cloud-cpp |
| `sub_modules/` | **Upstream projects forked _and modified_ by eloqdata.** | brpc, braft, glog, mimalloc, cuckoofilter, rocksdb-cloud |
| `data_substrate/` | **Original Eloq projects** — Eloq's own code, not a fork of anything. | data_substrate (tx_service core), log_service, tx-log-protos, eloqstore |

**`ltzhang/` ≡ `eloqdata/`:** an Eloq project forked under `ltzhang/` is treated the same as the
`eloqdata/` original (same project, just the working fork). So `ltzhang/data_substrate`,
`ltzhang/eloqstore`, etc. go in `data_substrate/`; a hypothetical `ltzhang/` fork of brpc would go
in `sub_modules/`.

All dependency checkouts are kept **at depth-2** under `dependencies/` (no submodules buried deep
under other repos). data_substrate's nested submodules are flattened to these buckets and symlinked
into the deep paths the build expects; shared ones (e.g. `tx-log-protos`, used by both `tx_service`
and `log_service`) get a **single** checkout.

## Build Conventions

- No `sudo`; no installs into the host's root directories.
- All compiled libraries install into the local library directory.
- All build artifacts are produced under `build/`.
- **Versioning policy depends on who owns the repo:**
  - **`eloqdata/` and `ltzhang/` repos → always latest.** Build the latest of the default
    branch, **even when a submodule gitlink or dependency script pins an older commit/tag** —
    those pins are informational and we deliberately follow HEAD. This covers the products
    (`ltzhang/{eloqkv,eloqsql,eloqdoc}`) and the Eloq forks + core (`eloqdata/{brpc, braft,
    glog, mimalloc, cuckoofilter, rocksdb-cloud, tx_service}`).
  - **All other third-party repos → pin the version.** protobuf, abseil, grpc, re2, crc32c,
    liburing, lua, json, rocksdb (facebook), Catch2, FakeIt, prometheus-cpp, aws-sdk-cpp,
    google-cloud-cpp are pinned to known-good versions (listed in `BUILD-PLAN.md`), so an
    upstream release can't break the build.

### System vs. built dependencies (boundary)

We do **not** rebuild the base toolchain or common system libraries. The build **assumes the
system prerequisites are already present** (installed via `apt`, outside this repo's scope) —
e.g. `gcc/g++`, `make`, `cmake`, `ninja`, `pkg-config`, plus system libs such as `libssl-dev`,
`zlib1g-dev`, `libgflags-dev`, `libleveldb-dev`, `libsnappy/lz4/zstd/bz2-dev`. These are
documented as a prerequisite list in the **README**, not built locally.

Only the heavy / pinned / forked dependencies (protobuf, abseil, grpc, brpc, braft, glog,
mimalloc, cuckoofilter, rocksdb, data_substrate, …) are built locally into the shared prefix.
The full inventory, versions, sources, and build order live in **`BUILD-PLAN.md`**.

## Second Task: Trim the dependency set

The goal is a **minimal default build**. The current script builds the full cloud stack
(AWS SDK, Google Cloud SDK, RocksDB Cloud, etc.) even when the default configuration never
links against them.

Guiding principles:

- **Drop the heavy, optional dependencies by default** — AWS SDK, Google Cloud SDK, and
  RocksDB Cloud — unless they are actually required at link time.
- **Link errors are the test.** Build with a dependency removed; if nothing fails to link,
  it was not needed and should stay out of the script.
- **Make the rest feature-gated, not unconditional.** Pull in a heavy library only when the
  feature that needs it is enabled — so the build only pays for what it uses.

### Why this works: the build is already feature-gated

EloqKV selects its storage and log backends at configure time
(`eloqkv/CMakeLists.txt`), and each heavy library is tied to a specific backend:

- `WITH_DATA_STORE` — default `ELOQDSS_ELOQSTORE`. Options: `DYNAMODB`, `BIGTABLE`,
  `ELOQDSS_ROCKSDB_CLOUD_S3`, `ELOQDSS_ROCKSDB_CLOUD_GCS`, `ELOQDSS_ROCKSDB`,
  `ELOQDSS_ELOQSTORE`.
- `WITH_LOG_STATE` — default `ROCKSDB`. Options: `MEMORY`, `ROCKSDB`,
  `ROCKSDB_CLOUD_S3`, `ROCKSDB_CLOUD_GCS`.

At the **top-level product** CMake, the AWS SDK is only resolved for `DYNAMODB` and Google
Cloud only for `BIGTABLE`. RocksDB Cloud, AWS, and GCP are otherwise pulled in by the
`data_substrate` submodule based on the selected backend.

> **CORRECTION (verified against eloqstore source):** the default **EloqStore backend is NOT
> cloud-free.** `eloqstore`'s `build_eloq_store.cmake` does `find_package(AWSSDK REQUIRED
> COMPONENTS s3)` **unconditionally** and `object_store.cpp` `#include <aws/core/Aws.h>`
> (its object store uses S3; `cloud_provider` defaults to `"aws"`). So **AWS SDK (s3) is a hard
> dependency of EloqStore** and cannot be dropped. Only **GCP** and **rocksdb-cloud** are truly
> optional. The build only compiles the **s3** AWS component for EloqStore (not the full SDK).

### Default-build dependency map

Under the default config (`ELOQDSS_ELOQSTORE` data store + `ROCKSDB` log state):

| Dependency        | Default build | Required when |
|-------------------|---------------|---------------|
| rocksdb           | Keep          | `WITH_LOG_STATE=ROCKSDB` (the default) |
| **aws-sdk-cpp (s3)** | **Keep**   | **EloqStore (default, via eloqstore)**, DynamoDB, any S3 backend |
| rocksdb-cloud     | Drop          | `ELOQDSS_ROCKSDB_CLOUD_S3` / `_GCS` backends |
| google-cloud-cpp  | Drop          | `BIGTABLE`, or any cloud-GCS backend |

So for the **default EloqStore** build: keep `rocksdb` + `aws-sdk-cpp (s3 only)`; drop
`google-cloud-cpp` and `rocksdb-cloud`. The orchestrator computes this per backend
(`--with-aws` / `--with-gcp` / `--with-rocksdb-cloud`), with AWS scoped to just the needed
components via `ELOQDB_AWS_COMPONENTS`.

## Third Task: Umbrella build for multiple products

EloqDB is the umbrella for several product repositories that live in the parent directory
and share a common core:

| Product   | Compatibility | Build system | Notable submodules |
|-----------|---------------|--------------|--------------------|
| eloqkv    | Redis         | CMake        | `crcspeed`, `data_substrate` |
| eloqsql   | MariaDB       | CMake        | `libmariadb`, **vendored `rocksdb`**, `wsrep-lib`, `wolfssl`, `libmarias3`, `columnstore`, `data_substrate` |
| eloqdoc   | MongoDB       | SCons        | `data_substrate` |

All three pull the **same `data_substrate` (eloqdata/tx_service)** — it is the shared core —
and overlap heavily on the heavy libraries (brpc, braft, protobuf, abseil, glog, mimalloc,
rocksdb, …). They differ on build system (eloqdoc uses SCons) and on some pinned versions
(eloqsql vendors its own `rocksdb`).

### Goals

- Build every product under this one EloqDB directory.
- Pull each product **optionally** — only selected products are cloned and built.
- **Share dependencies**: common deps build once and are reused by all products.
- Each product may add **project-specific dependencies** in its own dependency directory.
- Everything sudo-free, into a local prefix (same rule as Task 1).

### Decided approach

**Pull mechanism — manifest + clone script.** A top-level `manifest.toml` is the source of
truth: per product it records repo URL, ref, build system, enabled flag, and feature flags
(`WITH_DATA_STORE`, `WITH_LOG_STATE`, …). `scripts/build.sh` clones only the *enabled*
products into `projects/`. (Not top-level submodules — those are always-on and hard to keep
optional.)

**Dependency sharing — single shared prefix + project overrides.** One shared local prefix
(`install/`) holds the common deps, built once. A dependency that is pinned, vendored, or
otherwise conflicting (e.g. eloqsql's own `rocksdb`) installs into a **project-scoped**
prefix that is searched *before* the shared one. `CMAKE_PREFIX_PATH` ordering makes the
project-local version win where present and the shared prefix fill in the rest.

The heavy deps are **version-aligned across all three products**, so one shared build serves all.
Per the versioning policy: the third-party ones are **pinned** (protobuf v21.12, abseil
20230802.0, grpc v1.51.1, liburing 2.6, rocksdb v9.1.0), while `eloqdata/` libs track **latest**
(brpc, braft, glog, mimalloc, cuckoofilter). (eloqsql's *vendored* MyRocks submodule
`storage/rocksdb/rocksdb` is separate and stays project-local.)

**Shared core — one data_substrate.** All products build against a **single shared
`data_substrate` (eloqdata/tx_service)** built once into the shared prefix. The products
currently pin *different* commits (eloqkv `2c6c757`, eloqsql/eloqdoc `985017e`), but per the
always-latest policy we **ignore both pins and build the latest of the default branch** — the
single shared build is the convergence point. (This resolves the former open question of which
commit to pick.)

**Fork sources — everything from `eloqdata/`, modifications on a `lintao-mod` branch.** We do
**not** use separate `ltzhang/` forks. Instead, our changes to Eloq-owned repos live on a
`lintao-mod` branch **inside the eloqdata repos**, keeping their default branches pristine while
isolating our work (and avoiding fork drift). The build **prefers `ELOQDB_MOD_BRANCH`
(`lintao-mod`) when the remote has it, else falls back to the default branch** — so it works
before/after those branches are created (`eloq_pick_branch` in `scripts/lib/common.sh`).

- **Products**: `eloqdata/{eloqkv, eloqsql, eloqdoc}`.
- **Core**: `eloqdata/tx_service` (note: the repo is named *tx_service*; there is no
  `eloqdata/data_substrate`). Its components `eloqdata/{eloqstore, log_service, tx-log-protos}`.
- **Dependency forks** (eloqdata forks of upstream): `eloqdata/{brpc, braft, glog, mimalloc,
  cuckoofilter, rocksdb-cloud}`.
- **Upstream-only** (protobuf, abseil, grpc, re2, crc32c, liburing, lua, json, rocksdb, Catch2,
  FakeIt, prometheus-cpp, aws-sdk, google-cloud-cpp): pull from upstream, pinned.

### Layout

```
eloqdb/
  manifest.toml              # which products, refs, build systems, feature flags
  env.sh                     # `source` it -> exports the shared-prefix contract
  projects/                  # product repos, pulled optionally (empty until selected)
    eloqkv/  eloqsql/  eloqdoc/
  dependencies/              # classified by origin (see Dependency classification)
    data_substrate/          # original Eloq projects: the core + log_service, tx-log-protos, eloqstore
    sub_modules/             # eloqdata forks of upstream: brpc, braft, glog, mimalloc, cuckoofilter
    third_party/             # upstream used as-is: protobuf, abseil, rocksdb, lua, concurrentqueue, ...
  scripts/
    build.sh                 # umbrella orchestrator
    deps/<dep>.sh            # one idempotent build recipe per shared dep
    projects/<name>.sh       # per-product build adapter (cmake vs scons)
  build/                     # all build trees: build/deps/<dep>, build/<project>
  install/                   # shared local prefix (include/ lib/ bin/) - no sudo
```

### The dependency contract (`env.sh`)

Replacing system-wide installs, every dep installs into the shared prefix and every product
consumes it through one set of env vars:

```sh
export ELOQDB_PREFIX=$PWD/install
export CMAKE_PREFIX_PATH=$ELOQDB_PREFIX
export PKG_CONFIG_PATH=$ELOQDB_PREFIX/lib/pkgconfig
export LD_LIBRARY_PATH=$ELOQDB_PREFIX/lib:$LD_LIBRARY_PATH
export PATH=$ELOQDB_PREFIX/bin:$PATH
```

### Build flow (`scripts/build.sh`)

1. Read `manifest.toml`; clone enabled products into `projects/`.
2. Compute the **union of dependencies** across enabled products and their feature flags;
   build each shared dep **exactly once** into `install/` (Task 2's feature-gating applied
   across products — e.g. no cloud stack unless an enabled product+backend needs it).
3. Build each enabled product via its adapter (`scripts/projects/<name>.sh`): CMake products
   get `-DCMAKE_PREFIX_PATH=$ELOQDB_PREFIX`; eloqdoc's SCons gets the same prefix. Pinned
   project-local deps are searched ahead of the shared prefix.

### eloqdoc build constraint: locked to MongoDB 4.0.3 + SCons + Python 2

eloqdoc is a MongoDB fork, and we are **licensing-locked to MongoDB 4.0.3** — the last release
under AGPL. MongoDB relicensed to SSPL on 2018-10-16, so every later version (4.2+), including
the modern Bazel-based build, is SSPL and **cannot be used in an open-source project**. There is
no "upgrade to a modern build" path; we stay on the 4.0.x era, which means **SCons + vendored
SCons 2.5.0 + Python 2.7**.

Implications:

- **Do not convert the MongoDB server build to CMake.** It is upstream MongoDB (~503
  `env.Library` targets, a custom `scons/libdeps.py` dependency graph, 48 `.idl` codegen files,
  ~25 vendored libs) — a person-months port, high risk, and it would *not* even remove the
  Python 2 dependency (the IDL compiler and buildscripts are Python regardless). Only the
  Eloq-authored module (`src/mongo/db/modules/eloq/`) is — and stays — CMake.
- The real blocker is **Python 2 obsolescence** (gone from Ubuntu 24.04 defaults), not the build
  system. Two options were considered:
  - **Option A — isolate Python 2.7 (NOW).** Provision a hermetic Python 2.7 (e.g. `pyenv 2.7.18`)
    into a local prefix — sudo-free, no system pollution. The `eloqdoc.sh` adapter activates that
    Py2.7 + vendored SCons, then builds against the shared prefix. Upstream build stays
    byte-for-byte intact. Cost: Py2.7 lives on as a build-time-only tool.
  - **Option B — port build scripts to Python 3 (LATER).** `2to3` over `SConstruct` +
    `buildscripts/` + the IDL compiler, fix manual cases, bump vendored SCons 2.5 → 3.x/4.x.
    Self-contained *Python* work (weeks, not the CMake port), stays on the AGPL 4.0.3 base, and
    removes Python 2 permanently. (Cannot copy MongoDB 4.4's own Py3 port — that's SSPL — but
    `2to3` is generic.)

**Decision: A now, B later.** Isolation unblocks the unified build immediately at near-zero risk;
the Py3 port is the long-run cleanup, scoped independently and not a blocker for the umbrella.