# EloqDB

A clean, self-contained umbrella build for the Eloq product family — **EloqKV** (Redis),
**EloqSQL** (MariaDB), and **EloqDoc** (MongoDB) — that builds every dependency **locally
without `sudo`** into a single shared prefix, and pulls each product **optionally**.

See [CLAUDE.md](CLAUDE.md) for design rationale and [BUILD-PLAN.md](BUILD-PLAN.md) for the
dependency inventory and build order.

## System prerequisites (install once, via your package manager)

EloqDB does **not** rebuild the base toolchain or common system libraries — it assumes they are
already present. On Ubuntu 24.04:

```bash
sudo apt-get install -y \
    build-essential g++ make cmake ninja-build pkg-config git curl m4 patchelf ccache bison \
    libssl-dev gnutls-dev zlib1g-dev libgflags-dev libleveldb-dev libsnappy-dev liblz4-dev \
    libzstd-dev libbz2-dev libcurl4-openssl-dev libc-ares-dev libuv1-dev libboost-context-dev \
    libjsoncpp-dev libreadline-dev libncurses-dev
```

> The Eloq core (`data_substrate` / `eloqstore`) additionally requires `libjsoncpp-dev`,
> `gnutls-dev`, and `libboost-context-dev` — included above. These are resolved via
> `find_package`/`find_library`, so the dev packages (not just runtime libs) must be present.

Everything else (protobuf, abseil, grpc, brpc, braft, glog, mimalloc, cuckoofilter, rocksdb,
data_substrate, …) is built locally into `install/`. Nothing is installed to system directories.

## Quick start

The build is **layered** — each layer depends on the one below it:

```
layer 1: deps            third-party + eloqdata forks   ->  scripts/deps.sh
layer 2: data_substrate  the shared Eloq core           ->  scripts/substrate.sh
layer 3: projects        eloqkv / eloqsql / eloqdoc      ->  scripts/projects/*.sh
```

```bash
source env.sh                 # exports the shared-prefix contract (ELOQDB_PREFIX=install/)
./scripts/build.sh            # all layers: deps -> substrate -> projects
```

Build a single layer (useful for iterating):

```bash
./scripts/build.sh --deps-only            # layer 1 only
./scripts/build.sh --data-substrate       # layer 2 only (requires layer 1 built)
./scripts/build.sh --product eloqkv       # all layers, projects scoped to eloqkv
./scripts/build.sh --with-tests           # layer 1 also builds test deps (Catch2, FakeIt)
ELOQDB_JOBS=8 ./scripts/build.sh          # cap parallelism
```

## Choosing what to build

Edit [manifest.toml](manifest.toml): set `enabled = true` for the products you want, and adjust
each product's `with_data_store` / `with_log_state` feature flags. The default
(`ELOQDSS_ELOQSTORE` + `ROCKSDB`) builds a **minimal stack with no cloud dependencies**
(AWS SDK, Google Cloud SDK, RocksDB Cloud are pulled in only when a selected backend needs them).

## Layout

| Path | Purpose |
|------|---------|
| `manifest.toml` | which products to build + their feature flags |
| `env.sh` | shared-prefix environment contract |
| `dependencies/data_substrate/` | the shared Eloq core (eloqdata/tx_service), latest |
| `dependencies/sub_modules/` | eloqdata/ forks (brpc, braft, glog, mimalloc, cuckoofilter), latest |
| `dependencies/third_party/` | pinned upstream deps |
| `projects/` | product checkouts (optional; created by the build) |
| `scripts/build.sh` | umbrella orchestrator (dispatches the 3 layers) |
| `scripts/deps.sh` | layer 1 — shared dependency recipes (sudo-free) |
| `scripts/substrate.sh` | layer 2 — the shared `data_substrate` core |
| `scripts/projects/*.sh` | layer 3 — per-product build adapters |
| `build/` | all build trees |
| `install/` | the shared local prefix (`include/ lib/ bin/`) |

## Versioning policy

- **`eloqdata/` and `ltzhang/` repos** → always built from the **latest** of their default branch.
- **All other third-party repos** → **pinned** to known-good versions (in `scripts/deps.sh`).

## EloqDoc / Python 2.7

EloqDoc is locked to MongoDB 4.0.3 (last AGPL release), whose SCons build needs Python 2.7.
Its adapter provisions a hermetic Python 2.7 via `pyenv` (no system changes) automatically.
