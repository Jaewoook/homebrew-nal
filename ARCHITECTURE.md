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
| **Linux-Only Blocks** | `on_linux do depends_on "..." end` | **No** | Tap targets macOS Intel (`x86_64`); Linux blocks are stripped or left unqualified. |

---

## 2. Upstream Synchronization Engine

The upstream sync pipeline runs on a monthly schedule (`sync-upstream.yml`) or on-demand:

```mermaid
flowchart LR
    Upstream["Homebrew/homebrew-core"] -->|"fetch_upstream_formula"| SyncDeps["sync_dependencies.sh"]
    SyncDeps -->|"strip on_linux & directives\nresolve sharding"| SaveFormula["Formula/<name>.rb"]
    SaveFormula -->|"qualify_dependencies.sh"| InjectHook["Inject NAL_TAP_DEDUP\nRewrite depends_on"]
    InjectHook -->|"sync_formulas.sh"| CommitSync["Git Commit & Push"]
```

### Upstream Formula Sharding Resolution
`Homebrew/homebrew-core` shards formulas across subdirectories:
- `Formula/<first-letter>/<name>.rb` (standard)
- `Formula/lib/<name>.rb` (for `lib*` packages, e.g. `libffi`, `libnghttp2`, `libuv`)

`scripts/sync_dependencies.sh` dynamically probes:
```bash
https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/lib/${dep}.rb
https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/${first_char}/${dep}.rb
https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/${dep}.rb
```
Formulas are saved into the tap's flat `Formula/<name>.rb` structure.

### Automated Major Version Preservation
When an unversioned formula advances its major version (e.g. `node` 24 → 26):
1. `sync_formulas.sh` compares the new major version against `.formula-versions.json`.
2. The previous major version formula (`Formula/<name>@<prev_version>.rb`) is retrieved and added to the tap.
3. This ensures client workflows targeting `@<major>` continue to resolve while the latest unversioned formula advances.

---

## 3. CI/CD Build & Bottle Pipeline

The bottle build workflow (`build.yml`) operates across two matrix tiers:

```mermaid
flowchart TD
    Push["Git Push / Workflow Dispatch"] --> Detect["detect_formulas.sh"]
    Detect -->|"Skip already-bottled\nTopological sort"| Matrix["Build Matrix (Runner)"]
    
    subgraph BuildJob ["Per-Formula Build Job"]
        Matrix --> InstallDeps["Install only-dependencies"]
        InstallDeps --> BuildBottle["brew bottle --root-url"]
        BuildBottle --> CommitBlock["1. Commit bottle block (NAL Bot)"]
        CommitBlock --> UploadAsset["2. Upload asset to GitHub Release"]
    end
```

### Incremental Build Detection & Rebuild Skipping
On `push` events, `scripts/detect_formulas.sh` inspects whether a formula already has an existing `root_url` block matching `https://github.com/Jaewoook/homebrew-nal/releases/download/<tag>`.
- If the bottle block exists and no custom patch files in `Patches/<formula>/` were modified, the formula is **skipped**.
- This prevents redundant multi-hour rebuilds of massive packages (like `llvm`, `gcc`, or `node`) when only tap dependencies, scripts, or unrelated formulas are updated.

### Topological Dependency Sort
If multiple unbottled formulas are queued in the same push:
1. `detect_formulas.sh` parses `depends_on "jaewoook/nal/<dep>"` declarations.
2. Formulas are sorted in topological order using Kahn's algorithm so dependencies (e.g. `libuv`, `icu4c@78`) build and publish their bottles before dependents (`node`).

### Keg Adoption & Suppressing Deprecation Checks
- **Existing Keg Adoption**: If a matching version is already installed in `/usr/local/Cellar`, the build script packages the existing keg directly via `brew bottle`, bypassing source recompilation.
- **`HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK="1"`**: Homebrew normally runs linkage and dependency health checks on all installed kegs. On Intel macOS Sequoia, this would fail due to deprecated upstream bottles or unrelated core formulas. Setting this variable restricts checks to the active formula.

---

## 4. Runner Security & Committer Lifecycle

Self-hosted runners build formulas and commit updated bottle blocks back to the repository.

### Ephemeral Bot Git Identity & Optional Signing
To avoid committing with the runner's personal system identity or leaving automated bot credentials globally configured:
1. Runner scripts record previous `user.name`, `user.email`, `user.signingkey`, and `commit.gpgsign` settings.
2. The runner configures an isolated commit identity (`BOT_NAME` and `BOT_EMAIL`, defaulting to `NAL Bot <nal-git-system@jaewook.me>`).
3. **Optional GPG Signing**: If a GPG key ID is provided via `BOT_GPG_KEY` and exists in the host's keyring, `commit.gpgsign = true` is applied; otherwise, commits proceed unsigned without blocking the build.
4. A Bash `trap` ensures that when the job exits (on success, error, or cancellation), all git settings are restored to their previous states.

---

## 5. Summary Matrix of Tap Scripts

| Script | Responsibility | Key Flags / Arguments |
| :--- | :--- | :--- |
| [`scripts/detect_formulas.sh`](file:///Users/jaewookahn/repos/homebrew-nal/scripts/detect_formulas.sh) | Identifies formulas needing builds, applies bottle skip logic, and sorts topologically. | `--event <event_name>` |
| [`scripts/sync_formulas.sh`](file:///Users/jaewookahn/repos/homebrew-nal/scripts/sync_formulas.sh) | Synchronizes formulas from upstream, sanitizes DSL, and updates `.formula-versions.json`. | `[formulas...]`, `--with-deps`, `--dry-run`, `--commit` |
| [`scripts/sync_dependencies.sh`](file:///Users/jaewookahn/repos/homebrew-nal/scripts/sync_dependencies.sh) | Discovers and fetches upstream runtime dependencies, resolving sharded paths. | `[formulas...]` |
| [`scripts/qualify_dependencies.sh`](file:///Users/jaewookahn/repos/homebrew-nal/scripts/qualify_dependencies.sh) | Rewrites runtime dependencies to tap namespace and injects the `NAL_TAP_DEDUP` hook. | `[formulas...]` |
| [`scripts/build_bottle.sh`](file:///Users/jaewookahn/repos/homebrew-nal/scripts/build_bottle.sh) | Handles dependency installation, compilation, bottle packaging, and bottle block generation. | `<formula>` |
