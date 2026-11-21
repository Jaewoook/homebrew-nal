#!/usr/bin/env bash
# ==============================================================================
# restore_host_state.sh - Manage host state preservation and restoration
#   for Apple Silicon (arm64) runners during and after Intel (x86_64) builds.
#
# Usage:
#   scripts/restore_host_state.sh record-state <formula|cask> <name>
#   scripts/restore_host_state.sh restore <formula|cask> <name>
# ==============================================================================
set -euo pipefail

ACTION="${1:-}"
TYPE_ARG="${2:-}"
PKG_NAME="${3:-}"

# Normalize action
case "$ACTION" in
  record-state|record)
    ACTION="record-state"
    ;;
  restore)
    ACTION="restore"
    ;;
  *)
    echo "Usage: $0 <record-state|restore> <formula|cask> <name>" >&2
    exit 1
    ;;
esac

# Normalize type
TYPE_CLEAN="${TYPE_ARG#--}"
case "$TYPE_CLEAN" in
  formula|cask)
    PACKAGE_TYPE="$TYPE_CLEAN"
    ;;
  *)
    echo "::error::Invalid package type: $TYPE_ARG (must be formula or cask)" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/formula_helpers.sh"

if [ -z "$PKG_NAME" ] || ! is_valid_cask_name "$PKG_NAME"; then
  echo "::error::Invalid or missing package name: $PKG_NAME" >&2
  exit 1
fi

ARM64_BREW_BIN="${ARM64_BREW_BIN:-/opt/homebrew/bin/brew}"
INTEL_BREW_BIN="${INTEL_BREW_BIN:-/usr/local/bin/brew}"
HOST_STATE_DIR="${HOST_STATE_DIR:-${PWD}/.host_state}"
mkdir -p "$HOST_STATE_DIR"
STATE_FILE="${HOST_STATE_DIR}/${PACKAGE_TYPE}_${PKG_NAME}.env"

run_arm64_brew() {
  if [ -x "$ARM64_BREW_BIN" ]; then
    local arm64_dir arm64_path
    arm64_dir="$(dirname "$ARM64_BREW_BIN")"
    case ":${PATH}:" in
      *":${arm64_dir}:"*) arm64_path="$PATH" ;;
      *) arm64_path="${arm64_dir}:${PATH}" ;;
    esac
    local env_cmd=(
      env
      -u CMAKE_APPLE_SILICON_PROCESSOR
      "PATH=${arm64_path}"
      HOMEBREW_NO_AUTO_UPDATE=1
      HOMEBREW_NO_ASK=1
      NONINTERACTIVE=1
    )
    if command -v arch >/dev/null 2>&1; then
      "${env_cmd[@]}" arch -arm64 "$ARM64_BREW_BIN" "$@"
    else
      "${env_cmd[@]}" "$ARM64_BREW_BIN" "$@"
    fi
  else
    return 1
  fi
}

run_intel_brew() {
  if [ -x "$INTEL_BREW_BIN" ]; then
    local env_cmd=(
      env
      HOMEBREW_NO_AUTO_UPDATE=1
      HOMEBREW_NO_ASK=1
      NONINTERACTIVE=1
    )
    if command -v arch >/dev/null 2>&1; then
      "${env_cmd[@]}" arch -x86_64 "$INTEL_BREW_BIN" "$@"
    else
      "${env_cmd[@]}" "$INTEL_BREW_BIN" "$@"
    fi
  else
    return 1
  fi
}

has_arm64_brew() {
  [ -x "$ARM64_BREW_BIN" ]
}

has_intel_brew() {
  [ -x "$INTEL_BREW_BIN" ]
}

if [ "$ACTION" = "record-state" ]; then
  PREV_INSTALLED=false
  PREV_INTEL_CASK_INSTALLED=false
  if has_arm64_brew; then
    if [ "$PACKAGE_TYPE" = "formula" ]; then
      if run_arm64_brew list --formula --versions "$PKG_NAME" >/dev/null 2>&1; then
        PREV_INSTALLED=true
      fi
    else
      if run_arm64_brew list --cask --versions "$PKG_NAME" >/dev/null 2>&1; then
        PREV_INSTALLED=true
      fi
    fi
  fi
  if [ "$PACKAGE_TYPE" = "cask" ] && has_intel_brew; then
    if run_intel_brew list --cask --versions "$PKG_NAME" >/dev/null 2>&1; then
      PREV_INTEL_CASK_INSTALLED=true
    fi
  fi

  echo "PREV_INSTALLED=${PREV_INSTALLED}" > "$STATE_FILE"
  echo "PREV_INTEL_CASK_INSTALLED=${PREV_INTEL_CASK_INSTALLED}" >> "$STATE_FILE"
  echo "PACKAGE_TYPE=${PACKAGE_TYPE}" >> "$STATE_FILE"
  echo "PACKAGE_NAME=${PKG_NAME}" >> "$STATE_FILE"

  TYPE_UPPER=$(echo "$PACKAGE_TYPE" | tr '[:lower:]' '[:upper:]')
  ENV_VAR_NAME="PREV_${TYPE_UPPER}_INSTALLED"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "${ENV_VAR_NAME}=${PREV_INSTALLED}" >> "$GITHUB_ENV"
  fi

  echo "[host-state] Recorded initial state for $PACKAGE_TYPE $PKG_NAME: PREV_INSTALLED=$PREV_INSTALLED"
  exit 0
fi

if [ "$ACTION" = "restore" ]; then
  PREV_INSTALLED=false
  PREV_INTEL_CASK_INSTALLED=false
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    echo "[host-state] Warning: State file $STATE_FILE not found; detecting current Apple Silicon status..."
    if has_arm64_brew; then
      if [ "$PACKAGE_TYPE" = "formula" ]; then
        if run_arm64_brew list --formula --versions "$PKG_NAME" >/dev/null 2>&1; then
          PREV_INSTALLED=true
        fi
      else
        if run_arm64_brew list --cask --versions "$PKG_NAME" >/dev/null 2>&1; then
          PREV_INSTALLED=true
        fi
      fi
    fi
  fi

  echo "=========================================="
  echo "[host-state] Restoring host state for $PACKAGE_TYPE $PKG_NAME..."
  echo "[host-state] Previously installed in Apple Silicon: $PREV_INSTALLED"
  echo "=========================================="

  INTEL_CASK_TOUCHED=false
  if [ "$PACKAGE_TYPE" = "cask" ]; then
    INTEL_CASK_NOW=false
    if has_intel_brew && run_intel_brew list --cask --versions "$PKG_NAME" >/dev/null 2>&1; then
      INTEL_CASK_NOW=true
    fi
    if [ "$INTEL_CASK_NOW" = "true" ] || [ "$PREV_INTEL_CASK_INSTALLED" != "$INTEL_CASK_NOW" ]; then
      INTEL_CASK_TOUCHED=true
    fi
  fi

  # 1. Clean up Intel Homebrew installation
  if has_intel_brew; then
    echo "[host-state] Removing Intel build from /usr/local..."
    if [ "$PACKAGE_TYPE" = "formula" ]; then
      run_intel_brew uninstall --ignore-dependencies "$PKG_NAME" 2>/dev/null || true
    elif [ "$INTEL_CASK_TOUCHED" = "true" ]; then
      run_intel_brew uninstall --cask --force "$PKG_NAME" 2>/dev/null || true
    fi
    run_intel_brew autoremove 2>/dev/null || true
  else
    echo "[host-state] Intel Homebrew not found; skipping /usr/local cleanup."
  fi

  # 2. Restore Apple Silicon Homebrew state
  if has_arm64_brew; then
    if [ "$PACKAGE_TYPE" = "cask" ] && [ "$INTEL_CASK_TOUCHED" != "true" ]; then
      echo "[host-state] Cask $PKG_NAME was not touched in Intel Homebrew; skipping Apple Silicon cask restore."
    elif [ "$PREV_INSTALLED" = "true" ]; then
      echo "[host-state] Reinstalling Apple Silicon version in /opt/homebrew..."
      if [ "$PACKAGE_TYPE" = "formula" ]; then
        run_arm64_brew reinstall "$PKG_NAME" || run_arm64_brew install "$PKG_NAME" || {
          echo "::warning::Failed to reinstall Apple Silicon formula $PKG_NAME"
        }
      else
        run_arm64_brew reinstall --cask --force "$PKG_NAME" || run_arm64_brew install --cask --force "$PKG_NAME" || {
          echo "::warning::Failed to reinstall Apple Silicon cask $PKG_NAME"
        }
      fi
    else
      echo "[host-state] Ensuring $PACKAGE_TYPE $PKG_NAME is not installed in Apple Silicon (/opt/homebrew)..."
      if [ "$PACKAGE_TYPE" = "formula" ]; then
        run_arm64_brew uninstall --ignore-dependencies "$PKG_NAME" 2>/dev/null || true
      else
        run_arm64_brew uninstall --cask --force "$PKG_NAME" 2>/dev/null || true
      fi
    fi
  else
    echo "[host-state] Apple Silicon Homebrew (/opt/homebrew) not present on this host; skipping arm64 restore."
  fi

  # Clean up state file
  rm -f "$STATE_FILE"
  echo "[host-state] Host state restoration complete for $PACKAGE_TYPE $PKG_NAME."
  exit 0
fi
