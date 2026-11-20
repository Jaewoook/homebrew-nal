# Tap Architecture & Technical Design

This document details the internal architecture, design decisions, and edge-case mitigations implemented in `homebrew-nal`.

---

## 1. Tap & Homebrew Dependency Model

### The Split Tap / Diamond Dependency Problem

In a standard Homebrew installation, installing a tap formula that shares dependencies with formulas from `homebrew/core` exposes a fundamental limitation in Homebrew's dependency resolution:

```mermaid
flowchart TD
    App["jaewoook/nal/node"] --> TapDep["jaewoook/nal/icu4c@78 (tap bottle)"]
    App --> IndirectCoreDep["homebrew/core/sqlite (build/indirect)"]
    IndirectCoreDep --> CoreDep["homebrew/core/icu4c@78 (unbottled)"]
    
    TapDep -. "Lock Conflict & Split Tap" .- CoreDep
```

1. **Lock Collisions (`OperationInProgressError`)**:
   Homebrew locks formula installations at the Cellar level: `/usr/local/Cellar/<formula>/<version>`. Because `Dependency` objects for `jaewoook/nal/foo` and `foo` have different `d.name` values, Homebrew's `Dependency.merge_repeats` (which groups strictly by `d.name`) does not recognize them as the same formula.
   When `FormulaInstaller#lock` calls `formula.recursive_dependencies`, both `jaewoook/nal/foo` and `foo` are returned. Locking the same Cellar directory twice in the same installation batch raises `OperationInProgressError: already locked /usr/local/Cellar/foo/...`.

2. **Cross-Tap Installation Duplicate Conflicts**:
   Even if locking succeeded, `FormulaInstaller#compute_dependencies` would attempt to install both the tap's prebuilt bottle and `homebrew/core`'s unbottled version from source, resulting in linking collisions and broken Superenv keg references.

---

### The Solution: `NAL_TAP_DEDUP` & In-Flight Tap Migration Hooks

Rather than requiring users or runners to modify the core Homebrew installation, tap formulas containing qualified dependencies dynamically inject lightweight, idempotent runtime hooks at formula load time:

```ruby
unless Dependency.singleton_class.const_defined?(:NAL_TAP_DEDUP)
  Dependency.singleton_class.prepend(Module.new do
    const_set(:NAL_TAP_DEDUP, true)
    def merge_repeats(all)
      all.group_by { |d| Utils.name_from_full_name(d.name) }.filter_map do |_, deps|
        pref = deps.find { |d| d.name.start_with?("jaewoook/nal/") } || deps.first
        pref&.class&.new(pref.name, merge_tags(deps), **(pref.uses_from_macos? ? { bounds: pref.bounds } : {}))
      end
    end
  end)

  begin
    require "formula_installer"
    FormulaInstaller.prepend(Module.new do
      def install_dependency(dep, dep_formula = dep.to_formula)
        if dep_formula.tap&.to_s == "jaewoook/nal"
          keg_paths = [dep_formula.linked_keg, dep_formula.prefix]
          keg_paths += dep_formula.rack.subdirs if dep_formula.rack.directory?
          keg_paths.uniq.each do |keg_path|
            next unless keg_path&.directory?

            target = keg_path.symlink? ? Utils::Path.resolved_path(keg_path) : keg_path
            begin
              keg = Keg.new(target)
              if keg.tab&.source.is_a?(Hash) && keg.tab.source["tap"] == "homebrew/core"
                keg.tab.source["tap"] = dep_formula.tap.to_s
                keg.tab.tap = dep_formula.tap if keg.tab.respond_to?(:tap=)
              end
            rescue RuntimeError, SystemCallError, TypeError
            end
          end
        end
        super
      end
    end)
  rescue LoadError
  end
end
```

#### How it Works:
1. **Dependency Deduplication (`merge_repeats`)**:
   - **Grouping by Short Name**: Replaces exact full-name grouping with `Utils.name_from_full_name(d.name)` (e.g. `jaewoook/nal/icu4c@78` and `icu4c@78` group to `icu4c@78`).
   - **Tap Priority**: If a group contains a tap-qualified dependency (`jaewoook/nal/*`), it is selected over the unqualified core dependency, ensuring prebuilt bottles are poured.
   - **Global Compatibility**: Feeds both `formula.recursive_dependencies` (used by `FormulaInstaller#lock`) and `FormulaInstaller#compute_dependencies` (used by `install_dependencies`), eliminating `OperationInProgressError` lock collisions.

2. **Zero-Uninstall Cross-Tap Migration (`FormulaInstaller#install_dependency`)**:
   - **The Upstream Guard**: Homebrew's `formula_installer.rb` checks `dep_formula.tap.to_s != tab_tap.to_s` on existing keg receipts (`INSTALL_RECEIPT.json`) and aborts with `Error: <dep> is already installed from homebrew/core! Please brew uninstall <dep> first.` whenever an upgraded dependency changes tap origin.
   - **In-Memory Tab Remapping**: Before the upstream check runs, the hook inspects existing kegs for the formula in `/usr/local/Cellar` and `/usr/local/var/homebrew/linked`. If the installed receipt originated from `homebrew/core`, its in-memory receipt is remapped to `jaewoook/nal`.
   - **Seamless Bottle Pour**: Homebrew safely bypasses the abort, unlinks the old core keg, pours the tap's prebuilt x86_64 bottle, and records the new tap origin into the receipt without requiring manual `brew uninstall` commands from the end-user.
   - **Idempotency**: Guarded by `const_defined?(:NAL_TAP_DEDUP)` so multiple formula loads in the same Ruby process evaluate safely without overhead or redefinition warnings.

---

### Runtime vs. Build/Test Scoping

`scripts/qualify_dependencies.sh` enforces strict boundaries when qualifying dependencies:

| Dependency Type | Syntax Example | Qualified to `jaewoook/nal/*`? | Rationale |
| :--- | :--- | :--- | :--- |
| **Runtime Dependency** | `depends_on "libuv"` | **Yes** | Client Macs require prebuilt binary bottles for runtime libraries to avoid source builds. |
| **Build Dependency** | `depends_on "cmake" => :build` | **No** | Build tools run temporarily during compilation and do not need tap bottle distribution. |
| **Test Dependency** | `depends_on "pytest" => :test` | **No** | Test harnesses run only during `brew test`. |
| **Combined Build/Test** | `depends_on "pkgconf" => [:build, :test]` | **No** | Treated as non-runtime; delegates directly to core. |
| **Linux / ARM Blocks** | `on_linux do ... end` / `on_arm do ... end` | **No** | Tap targets macOS Intel (`x86_64`); Linux-only and ARM-only dependency blocks are left unqualified and skipped during dependency resolution. |

---

## 2. Upstream Synchronization Engine

The upstream sync pipeline runs on a monthly schedule (`sync-upstream.yml`) or on-demand (`workflow_dispatch`):

```mermaid
flowchart LR
    Upstream["Homebrew/homebrew-core & cask"] -->|"fetch_upstream_formula\nextract_formula_meta"| SyncFormulas["sync_formulas.sh"]
    SyncFormulas -->|"arm64-only? pick latest\nIntel @<ver> sibling"| SyncFormulas
    SyncFormulas -->|"fetch_referenced_patches"| Patches["Patches/<pkg>/*"]
    SyncFormulas -->|"--with-deps (depth <= 2)"| SyncDeps["sync_dependencies.sh"]
    SyncDeps -->|"qualify_dependencies.sh"| InjectHook["Inject NAL_TAP_DEDUP\nRewrite depends_on"]
    InjectHook --> CommitSync["Git Commit & Push"]
```

### Upstream Formula Sharding Resolution
`Homebrew/homebrew-core` shards formulas across subdirectories:
- `Formula/<first-letter>/<name>.rb` (standard)
- `Formula/lib/<name>.rb` (for `lib*` packages, e.g. `libffi`, `libnghttp2`, `libuv`)

`fetch_upstream_formula` in [`scripts/formula_helpers.sh`](scripts/formula_helpers.sh) (shared by [`scripts/sync_formulas.sh`](scripts/sync_formulas.sh) and [`scripts/sync_dependencies.sh`](scripts/sync_dependencies.sh)) dynamically probes:
```bash
https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/lib/${dep}.rb
https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/${first_char}/${dep}.rb
https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/${dep}.rb
```
Formulas are sanitized (stripping `no_autobump!`) and saved into the tap's flat `Formula/<name>.rb` structure.

### Intel (`x86_64`) Compatibility Policy & Versioned Fallback
When upstream drops Intel macOS support for an unversioned formula (`depends_on arch: :arm64` outside `on_linux`/`on_arm` blocks and with no `on_intel` alternative):
1. `extract_formula_meta` in [`scripts/formula_helpers.sh`](scripts/formula_helpers.sh) flags the formula as `arm64_only=true`.
2. For unversioned formulas (e.g. `openjdk`), `list_versioned_candidates` discovers upstream `<formula>@<ver>` siblings via the Homebrew Formulae API (`versioned_formulae`), local directories (`file://` test upstreams), or the GitHub Contents API, sorted newest-first by numeric version tuple.
3. [`scripts/sync_formulas.sh`](scripts/sync_formulas.sh) selects the newest sibling that supports Intel `x86_64` (e.g. `openjdk@25`), syncs it as `Formula/<formula>@<ver>.rb`, and tracks it in `.formula-versions.json`.
4. If an explicitly versioned formula (`<formula>@<ver>`) is `:arm64`-only or no Intel-compatible variant exists, it is skipped cleanly without committing an unbuildable formula.

### Formula Metadata Extraction & Patch Synchronization
- **Block-Scoped Version Parsing (`extract_formula_meta`)**: Parses `version`, `revision`, and `url` only at the formula/class/`stable` level, ignoring `head`, `bottle`, `livecheck`, `resource`, `fails_with`, `patch`, `test`, `on_linux`, `on_arm`, `caveats`, `service`, and `def` blocks. Supports `.tar.*`, `.tgz`, `.tbz2`, `.txz`, `.zip`, `.pem`, `-sources`, tag paths, and git `tag:` URLs, preventing nested directives (such as `fails_with :gcc do version "11"`) or `"unknown"` entries from poisoning `.formula-versions.json`.
- **Referenced Patch Downloads (`fetch_referenced_patches`)**: Both [`scripts/sync_formulas.sh`](scripts/sync_formulas.sh) and [`scripts/sync_dependencies.sh`](scripts/sync_dependencies.sh) scan outside `on_linux`/`on_arm` blocks and comments for `Patches/<pkg>/<file>` references, validate paths against traversal outside `Patches/`, download atomically via temporary files, fail fast on download errors, and stage `Patches/` in both formula and dependency registration commits.
- **Diamond Dependency Visited-Depth Tracking**: [`scripts/sync_dependencies.sh`](scripts/sync_dependencies.sh) resolves runtime dependencies up to `MAX_DEPTH=2`, tracks minimum visited depth per dependency in a Bash 3.2-compatible temp index so diamond dependencies are not re-processed, and preserves valid existing entries in `.formula-versions.json`.

### Automated Major Version Preservation & Cask Sync
- **Major Version Auto-Preservation**: When an unversioned formula advances its major (or `major.minor`) version (e.g. `node` 24 → 26), [`scripts/sync_formulas.sh`](scripts/sync_formulas.sh) retrieves the previous Intel-compatible `<formula>@<prev_version>.rb` sibling (along with any referenced `Patches/`), qualifies its tap dependencies, and records it with `is_versioned: true` in `.formula-versions.json`.
- **Cask Synchronization**: [`scripts/sync_formulas.sh`](scripts/sync_formulas.sh) syncs Casks via `--casks` (or, on scheduled runs, the union of `.cask-versions.json` keys and `Casks/*.rb` filenames) from `Homebrew/homebrew-cask`, recording versions and SHA256 digests in `.cask-versions.json`.

---

## 3. CI/CD Build, Mirror & Release Pipeline

The bottle and Cask pipeline (`build.yml`) runs across three stages:

```mermaid
flowchart TD
    Push["Git Push / Workflow Dispatch"] --> Detect["detect_formulas.sh"]
    Detect -->|"Formulas (topological)"| BuildMatrix["Build Bottle Matrix (Runner)"]
    Detect -->|"Casks"| CaskMatrix["Mirror Cask Matrix (Runner)"]

    subgraph BuildJob ["Per-Formula Build Job"]
        BuildMatrix --> ArchCheck["ArchRequirement Preflight"]
        ArchCheck --> FastPath{"try_mirror_formula_binary.sh"}
        FastPath -->|"GHCR x86_64/all or\nGitHub Release binary"| CommitFormula["Commit Bottle & Release"]
        FastPath -->|"Needs source build"| SourceBuild["Install deps & brew install --build-from-source\nbrew bottle --root-url"]
        SourceBuild --> CommitFormula
        CommitFormula --> RestoreFormula["always(): restore_host_state.sh"]
    end

    subgraph CaskJob ["Per-Cask Mirror Job"]
        CaskMatrix --> MirrorCask["mirror_cask.sh\nVerify x86_64 & rewrite URL"]
        MirrorCask --> CommitCask["commit_cask.sh [skip ci]\n& Upload Release"]
        CommitCask --> RestoreCask["always(): restore_host_state.sh"]
    end
```

### Detection, Rebuild Skipping & Topological Sort
- **Incremental Build Detection (`detect_formulas.sh`)**: On `push` events, inspects changed `Formula/*.rb`, `Patches/<name>/*`, and `Casks/*.rb`. Already-bottled formulas (matching `root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/...`) are skipped unless a file under literal prefix `Patches/<name>/` was modified; already-mirrored Casks are likewise skipped.
- **Topological Dependency Sort**: Parses `depends_on` declarations among queued formulas and sorts them via recursive DFS post-order so dependencies build and publish their bottles before dependents (`max-parallel: 1`).

### Architecture Preflight & Fast-Path Binary Mirroring
1. **Architecture Preflight ([`scripts/build_bottle.sh`](scripts/build_bottle.sh))**: Evaluates `ArchRequirement` on `jaewoook/nal/<formula>` immediately after resolving the version so any `:arm64`-only formula fails fast before installing dependencies.
2. **Fast-Path A — Upstream GHCR Bottle Mirroring ([`scripts/try_mirror_formula_binary.sh`](scripts/try_mirror_formula_binary.sh))**: Eligible when a formula has no `jaewoook/nal/*` tap dependencies and no custom `patch`/`Patches/<name>` (and `FORCE_SOURCE_BUILD != true`). Queries `formulae.brew.sh/api/formula/<name>.json` for the matching version/revision, selects an upstream bottle tag by priority (`x86_64_<host>`/`<host>` → older backward-compatible macOS generations → `all` → newer generations), downloads from `ghcr.io`, verifies SHA256, and rewrites the `bottle do` block to point to GitHub Releases.
3. **Fast-Path B — Standalone GitHub Release Binary Repackaging**: When no upstream GHCR bottle exists and the formula has no macOS runtime dependencies (ignoring `:build`, `:test`, `[:build, :test]`, `:macos`, `:xcode`, and `on_linux`/`on_arm` blocks), checks the upstream GitHub release for macOS `x86_64`/`amd64`/`x64`/`universal` archives, verifies Mach-O `x86_64` executables via `file` and `lipo`, stages them into `/usr/local/Cellar` with a `Tab` receipt, and packages a bottle via `brew bottle`.
4. **Source Build Fallback & Keg Adoption**: Installs dependencies via `--only-dependencies`, adopts a matching Cellar keg if already built (otherwise compiles via `--build-from-source --skip-post-install --skip-link`), marks `built_as_bottle = true`, runs `brew bottle --root-url`, and normalizes double-hyphen tarball filenames (`<name>--` → `<name>-`).
5. **`HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK="1"`**: Prevents Homebrew from failing builds due to unrelated deprecated core formulas or Tier 3 warnings on the runner host.

### Cask Mirroring & Verification
[`scripts/mirror_cask.sh`](scripts/mirror_cask.sh) validates that a Cask does not require `:arm64` without an `on_intel` block, extracts Intel `version`/`url`/`sha256` (using indentation-anchored `on_intel`/`on_arm` matching), downloads and verifies SHA256, inspects extracted `.zip`/tarball or mounted `.dmg` (`hdiutil` + `lipo`) contents for Mach-O `x86_64` slices, and rewrites `Casks/<name>.rb` (stripping upstream `url` kwargs such as `verified:`) to point to tag `cask-<name>.<version>`. [`scripts/commit_cask.sh`](scripts/commit_cask.sh) commits with `[skip ci]` in the commit body to avoid re-triggering `build.yml`.

### Host State Preservation & Restoration
On Apple Silicon build hosts that maintain both `/opt/homebrew` (`arm64`) and `/usr/local` (Rosetta `x86_64`), [`scripts/restore_host_state.sh`](scripts/restore_host_state.sh) records pre-job `/opt/homebrew` install state (`record-state`) and runs on `if: always()` (`restore`) to uninstall the temporary `/usr/local` build, run `brew autoremove`, and reinstall or remove the package in `/opt/homebrew` so the host remains clean.

---

## 4. Runner Security & Committer Lifecycle

Self-hosted runners build formulas/casks and push bottle/cask updates back to `main`.

### Ephemeral Bot Git Identity & Optional Signing
To avoid committing with the runner's personal system identity or leaving automated bot credentials in `.git/config`:
1. [`scripts/commit_bottle.sh`](scripts/commit_bottle.sh) and [`scripts/commit_cask.sh`](scripts/commit_cask.sh) record existing local `user.name`, `user.email`, `user.signingkey`, and `commit.gpgsign` settings.
2. Commits pass `-c` overrides using `BOT_NAME` / `BOT_EMAIL` (defaulting to `NAL Bot <nal-git-system@jaewook.me>`).
3. **Optional GPG Signing**: If `BOT_GPG_KEY` is set and present in the host's GPG keyring, `-c commit.gpgsign=true` is applied; otherwise commits proceed unsigned without blocking the build.
4. A Bash `trap` on `EXIT INT TERM` restores all local git settings, and `build.yml` unsets runner-local git identity config in its `always()` cleanup step.

---

## 5. Summary Matrix of Tap Scripts

| Script | Responsibility | Key Flags / Environment Variables |
| :--- | :--- | :--- |
| [`scripts/formula_helpers.sh`](scripts/formula_helpers.sh) | Shared upstream formula fetching, `versioned_formulae` discovery, block-scoped metadata/arch parsing, SHA256, and atomic `Patches/` downloads. | Sourced by `sync_formulas.sh` and `sync_dependencies.sh` |
| [`scripts/detect_formulas.sh`](scripts/detect_formulas.sh) | Identifies formulas/casks needing build or mirroring, skips already-published artifacts unless `Patches/<name>/` changed, and sorts formulas topologically. | `FORMULA_INPUT`, `CASK_INPUT`, `EVENT_NAME`, `EVENT_BEFORE`, `GITHUB_OUTPUT` |
| [`scripts/sync_formulas.sh`](scripts/sync_formulas.sh) | Syncs formulas and casks from upstream, selects latest Intel-compatible fallback for `:arm64`-only formulas, preserves major versions, downloads `Patches/`, and updates state JSON. | `[formulas...]`, `--casks`, `--with-deps`, `--force`, `--dry-run`, `--commit`, `--push`, `--no-gpg-sign`, `--no-preserve` |
| [`scripts/sync_dependencies.sh`](scripts/sync_dependencies.sh) | Recursively resolves runtime dependencies (depth ≤ 2), fetches missing formulas and `Patches/`, repairs missing/corrupt state entries, and triggers qualification. | `--formula-dir`, `--patches-dir`, `--state-file`, `--upstream-base`, `--upstream-api-base`, `--max-depth` |
| [`scripts/qualify_dependencies.sh`](scripts/qualify_dependencies.sh) | Rewrites non-Linux/non-ARM runtime `depends_on` references to `jaewoook/nal/*` and injects the `NAL_TAP_DEDUP` runtime hook. | `--formula-dir`, `--tap`, `[formulas...]` |
| [`scripts/build_bottle.sh`](scripts/build_bottle.sh) | Runs `ArchRequirement` preflight, attempts fast-path binary mirroring, builds/bottles from source under `x86_64`, and normalizes bottle filenames. | `<formula>`, `FORCE_SOURCE_BUILD`, `SKIP_HOST_RESTORE` |
| [`scripts/try_mirror_formula_binary.sh`](scripts/try_mirror_formula_binary.sh) | Mirrors upstream GHCR `x86_64`/`all` bottles (Fast-Path A) or repackages standalone GitHub Release macOS `x86_64` binaries (Fast-Path B). | `<formula> [--dry-run] [<version>]` |
| [`scripts/commit_bottle.sh`](scripts/commit_bottle.sh) | Commits updated bottle blocks (`[skip ci]`), rebases, and pushes to `main` with ephemeral bot identity and optional GPG signing. | `<formula>`, `BOT_NAME`, `BOT_EMAIL`, `BOT_GPG_KEY` |
| [`scripts/mirror_cask.sh`](scripts/mirror_cask.sh) | Validates Intel `x86_64` support, verifies SHA256 and Mach-O slices, and rewrites Cask URLs/checksums to GitHub Releases. | `<cask>`, `SKIP_ARCH_BINARY_MOUNT`, `SKIP_HOST_RESTORE` |
| [`scripts/commit_cask.sh`](scripts/commit_cask.sh) | Commits mirrored Cask definitions (`[skip ci]` in body), rebases, and pushes to `main`. | `<cask> [<version>]`, `BOT_NAME`, `BOT_EMAIL`, `BOT_GPG_KEY` |
| [`scripts/restore_host_state.sh`](scripts/restore_host_state.sh) | Snapshots `/opt/homebrew` installation state before builds and cleans `/usr/local` while restoring `/opt/homebrew` afterward. | `<record-state\|restore> <formula\|cask> <name>` |
