# Host & Runner Setup Guide

This guide covers everything required to set up, operate, and maintain the self-hosted macOS Intel (`x86_64`) builder and tap maintenance environment.

---

## 1. Build Host Environment

### System & Hardware Requirements
- **Operating System**: macOS 15 (Sequoia) running on native Intel hardware (`x86_64`) or Apple Silicon using Rosetta 2 (`arch -x86_64`).
- **Disk Space**: At least **20 GB of free disk space** for intermediate build objects when compiling large packages (e.g. LLVM, GCC, Node).
- **Homebrew Prefix**: Intel Homebrew must be installed under the standard `/usr/local` prefix.

### Installing Intel Homebrew
If setting up on Apple Silicon or a fresh Intel machine:
```bash
arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Ensure `/usr/local/bin` precedes other paths in `PATH`:
```bash
echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/usr/local/bin/brew shellenv)"
```

### Developer Tools Setup
1. **Command Line Tools (CLT)**:
   Sufficient for almost all CLI formulas and standard C/C++ builds:
   ```bash
   xcode-select --install
   ```

2. **Full Xcode (Xcode 16+)**:
   Required only for formulas building native macOS Cocoa GUI bundles (such as `pinentry-mac`) that require Interface Builder (`ibtool`):
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

---

## 2. GitHub Actions Permissions & Secrets

### Workflow Permissions
In your repository on GitHub:
1. Navigate to **Settings → Actions → General**.
2. Under **Workflow permissions**, select **Read and write permissions**.
3. Check **Allow GitHub Actions to approve pull request requests**.

### Personal Access Token (`SYNC_PAT`)
GitHub Actions blocks git pushes made by the default `GITHUB_TOKEN` from triggering downstream workflows (such as `build.yml`).
1. Generate a GitHub Personal Access Token (Fine-grained or Classic) with `repo` / `Contents: Read and write` scope.
2. In your repository, go to **Settings → Secrets and variables → Actions**.
3. Create a repository secret named `SYNC_PAT` and paste the token.

---

## 3. Self-Hosted Runner Administration

### Runner Service & Daemon Management
To keep the runner daemon running reliably as a launchd service:
```bash
# Locate and inspect the runner launchd label
SVC_LABEL=$(basename ~/Library/LaunchAgents/actions.runner.*.plist .plist)

# Start or restart the runner service
launchctl kickstart -kp "gui/$(id -u)/$SVC_LABEL"
```

### Prevent System Sleep
The build machine must remain awake across long-running compiler jobs and reboots:
```bash
# Disable system sleep
sudo pmset -a disablesleep 1

# Optional: verify power management settings
pmset -g
```
In **System Settings → Users & Groups**, ensure **Automatic Login** is enabled for the runner account so the runner daemon initializes automatically after system restarts.

---

## 4. Bot Committer & GPG Signing (Optional)

When the self-hosted runner pushes bottle blocks back to the repository, it uses an isolated committer identity. **Both custom bot naming and GPG signing are completely optional**:

- **Custom Bot Name & Email**:
  By default, commits use `NAL Bot <nal-git-system@jaewook.me>`. You can customize this by setting `BOT_NAME` and `BOT_EMAIL` in the runner's environment or repository variables:
  ```bash
  export BOT_NAME="My Tap Bot"
  export BOT_EMAIL="bot@example.com"
  ```
- **Optional GPG Signing**:
  If `BOT_GPG_KEY` is configured and present in the host's GPG keyring, commits will be cryptographically signed (`commit.gpgsign = true`). If no key is configured or available, commits proceed as standard unsigned commits without error.

### Setting Up a Verified GPG Key (Optional)
If you wish to show the **Verified** badge on GitHub for bottle commits:
1. Generate a GPG key for your bot on the runner host:
   ```bash
   gpg --batch --generate-key <<EOF
   Key-Type: EDDSA
   Key-Curve: ed25519
   Key-Usage: sign
   Name-Real: NAL Bot
   Name-Email: nal-git-system@jaewook.me
   Expire-Date: 0
   %no-protection
   %commit
   EOF
   ```
2. Retrieve the Key ID:
   ```bash
   gpg --list-secret-keys --keyid-format=long nal-git-system@jaewook.me
   ```
3. Export the public key and add it to GitHub under **Settings → SSH and GPG keys**:
   ```bash
   gpg --armor --export nal-git-system@jaewook.me
   ```
4. Set the Key ID as `BOT_GPG_KEY` in your environment (or pass it in the workflow). The runner automatically applies `commit.gpgsign = true` ephemerally and restores previous git configuration after the commit.

---

## 5. Local Maintenance Scripts

For local maintenance, testing, or manual upstream syncing, use the scripts in `scripts/`:

```bash
# Check upstream versions without making changes (dry-run)
./scripts/sync_formulas.sh --dry-run

# Sync specific formula(s) to latest upstream version
./scripts/sync_formulas.sh node llvm gcc

# Sync specific versioned formula directly
./scripts/sync_formulas.sh node@22 llvm@18

# Sync formula and automatically discover and fetch missing runtime dependencies
./scripts/sync_formulas.sh --with-deps node

# Register specific formulas explicitly as dependencies
./scripts/sync_formulas.sh --as-dependency c-ares libuv

# Fetch missing runtime dependencies for a formula
./scripts/sync_dependencies.sh node

# Re-qualify tap dependencies across all formulas (or specific target formulas)
./scripts/qualify_dependencies.sh
./scripts/qualify_dependencies.sh node uvwasi

# Force sync and commit changes locally
./scripts/sync_formulas.sh --force --commit

# Sync, commit, and push directly to main
./scripts/sync_formulas.sh --commit --push
```

For technical details on how these scripts resolve dependencies, handle sharding, and deduplicate Homebrew locks, see [ARCHITECTURE.md](ARCHITECTURE.md).
