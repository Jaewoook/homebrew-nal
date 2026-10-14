# homebrew-nal

A custom [Homebrew](https://brew.sh/) tap providing automated upstream syncing and prebuilt binary bottles for macOS Intel (`x86_64`) on macOS Sequoia (15).

---

## Background & Motivation

According to the official [Homebrew Support Tiers](https://docs.brew.sh/Support-Tiers) documentation:
- **Tier 3 Classification**: macOS on Intel (`x86_64`) is classified as a Tier 3 configuration ("CI coverage is unavailable; bottles will rarely be built or published").
- **Discontinued Intel Bottles**: In alignment with Apple phasing out Intel hardware, Homebrew has stopped building new bottles for Intel systems, and plans to remove support for running Homebrew on Intel in or after September 2027. While existing bottles may still work, updated formulae build from source.

Without prebuilt bottles, running `brew install` for massive compiler suites (LLVM, GCC) or developer utilities on Intel Macs forces Homebrew to compile entirely from source. This process takes hours, consumes tens of gigabytes of disk space, and frequently fails due to missing build dependencies in Superenv.

This tap solves that problem by:
1. **Syncing Formulas**: Tracking upstream `Homebrew/homebrew-core` for version updates via an automated monthly schedule or manual dispatch.
2. **Sanitizing Tap Formulas**: Automatically stripping official-tap-only DSL directives (such as `no_autobump!`) to keep custom tap loading clean.
3. **Automated Prebuilding**: Compiling native `x86_64` binaries on a dedicated self-hosted macOS runner.
4. **Publishing Bottles**: Hosting bottle archives on GitHub Releases and committing bottle blocks back to formulas for instant installation.

---

## Client Usage

```bash
# Tap the repository
brew tap jaewoook/nal

# Install prebuilt formulas (specify tap prefix to ensure using this tap's bottles)
brew install jaewoook/nal/<formula>
```

> [!TIP]
> **Switching from `homebrew/core`**:
> If a formula was previously installed from `homebrew/core`, Homebrew disallows installing the same formula name from another tap simultaneously. To switch to this tap's prebuilt version:
> ```bash
> brew uninstall <formula>
> brew install jaewoook/nal/<formula>
> # Or directly switch taps:
> brew reinstall jaewoook/nal/<formula>
> ```

---

## Workflow Architecture

```mermaid
flowchart LR
    subgraph Sync ["1. Upstream Sync (Monthly / Dispatch)"]
        direction TB
        A["Homebrew/homebrew-core"] --> B["sync-upstream.yml"]
        B --> C["Sanitize & Update Formula/*.rb"]
        C --> D["Git push to main (SYNC_PAT)"]
    end

    subgraph Build ["2. Automated Bottle Build (Self-Hosted Runner)"]
        direction TB
        D --> E["build.yml (Matrix)"]
        E --> F["Compile with --build-bottle"]
        F --> G["Commit bottle block to main"]
        G --> H["Upload release asset to GitHub Releases"]
    end
```

### 1. Upstream Synchronization (`sync-upstream.yml`)
- Runs on a monthly cron schedule or manual dispatch.
- Downloads updated formula files from `Homebrew/homebrew-core`.
- Automatically strips official-tap-only DSL directives (e.g. `no_autobump!`) and records version state in [`.formula-versions.json`](.formula-versions.json).
- Pushes commits to `main` using `SYNC_PAT` so downstream build workflows are triggered automatically.

### 2. Bottle Build & Release Pipeline (`build.yml`)
- Triggered by pushes to `Formula/**` or manual dispatch.
- Runs on a dedicated macOS self-hosted runner under an isolated matrix (`fail-fast: false`).
- Compiles formulas (`brew install --build-bottle`) and creates bottle metadata.
- **Commit First, Release Second**: Merges and pushes the bottle block to `main` first, then attaches the GitHub Release asset directly to the resulting commit SHA. This ensures release tags always point directly to their respective bottle block commits.

---

## Host & Runner Requirements

### 1. Build Environment Setup

1. **System & Architecture**:
   - macOS 15 (Sequoia) on Intel (`x86_64`) or Apple Silicon running Intel Homebrew under Rosetta 2 (`arch -x86_64`).
   - At least **20 GB of free disk space** for intermediate compiler build objects.

2. **Intel Homebrew Installation**:
   ```bash
   arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

3. **Developer Tools**:
   - **Command Line Tools (CLT)**: Sufficient for all standard CLI formulas (`xcode-select --install`).
   - **Full Xcode (Xcode 16+)**: Required only for formulas building native macOS Cocoa GUI bundles (such as `pinentry-mac`) that depend on Interface Builder (`ibtool`):
     ```bash
     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
     sudo xcodebuild -license accept
     ```

---

### 2. GitHub Repository & Secrets Setup

- **Workflow Permissions**: In **Settings → Actions → General**, set Workflow permissions to **Read and write permissions** and allow creating pull requests.
- **Personal Access Token (`SYNC_PAT`)**: GitHub Actions blocks pushes by the default `GITHUB_TOKEN` from triggering other workflows. Generate a fine-grained PAT (or classic token with `public_repo` scope) with `Contents: Read and write`, and add it as a repository secret named `SYNC_PAT`.

---

### 3. Self-Hosted Runner Notes

- On modern macOS, start the runner LaunchAgent with:
  ```bash
  SVC_LABEL=$(basename ~/Library/LaunchAgents/actions.runner.*.plist .plist)
  launchctl kickstart -kp "gui/$(id -u)/$SVC_LABEL"
  ```
- Enable **Automatic Login** in **System Settings → Users & Groups** and disable system sleep (`sudo pmset -a disablesleep 1`) so the builder stays online across reboots.

---

## Local Script Usage

```bash
# Check upstream versions without making changes (dry-run)
./scripts/sync_formulas.sh --dry-run

# Sync specific formulas
./scripts/sync_formulas.sh llvm gcc

# Force sync and commit changes locally
./scripts/sync_formulas.sh --force --commit

# Sync, commit, and push directly to main
./scripts/sync_formulas.sh --commit --push
```

---

## License

This repository and tap scripts are licensed under the MIT License. Individual formulas and upstream code retain their respective upstream licenses.
