#!/usr/bin/env bash
set -euo pipefail

# Inputs from environment or defaults
FORMULA_INPUT="${FORMULA_INPUT:-}"
CASK_INPUT="${CASK_INPUT:-}"
EVENT_NAME="${EVENT_NAME:-}"
EVENT_BEFORE="${EVENT_BEFORE:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"

TARGETS=()
CASK_TARGETS=()

if [ -n "$FORMULA_INPUT" ] || [ -n "$CASK_INPUT" ]; then
  if [ -n "$FORMULA_INPUT" ]; then
    if [ "$FORMULA_INPUT" = "all" ]; then
      for f in Formula/*.rb; do
        [ -f "$f" ] || continue
        TARGETS+=("$(basename "$f" .rb)")
      done
    else
      CLEANED=$(echo "$FORMULA_INPUT" | tr ',' ' ')
      for name in $CLEANED; do
        if [[ "$name" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]] && [ -f "Formula/${name}.rb" ]; then
          TARGETS+=("$name")
        else
          echo "::warning::Formula Formula/${name}.rb not found or invalid, skipping."
        fi
      done
    fi
  fi

  if [ -n "$CASK_INPUT" ]; then
    if [ "$CASK_INPUT" = "all" ]; then
      for c in Casks/*.rb; do
        [ -f "$c" ] || continue
        CASK_TARGETS+=("$(basename "$c" .rb)")
      done
    else
      CLEANED_CASKS=$(echo "$CASK_INPUT" | tr ',' ' ')
      for name in $CLEANED_CASKS; do
        if [[ "$name" =~ ^[a-zA-Z0-9._+-]+(@[a-zA-Z0-9._+-]+)?$ ]] && [ -f "Casks/${name}.rb" ]; then
          CASK_TARGETS+=("$name")
        else
          echo "::warning::Cask Casks/${name}.rb not found or invalid, skipping."
        fi
      done
    fi
  fi
elif [ "$EVENT_NAME" = "push" ]; then
  if [ -n "$EVENT_BEFORE" ] && [ "$EVENT_BEFORE" != "0000000000000000000000000000000000000000" ] && git cat-file -e "$EVENT_BEFORE" 2>/dev/null; then
    RAW_DIFF=$(git diff --name-only "$EVENT_BEFORE" HEAD 2>/dev/null || true)
  else
    RAW_DIFF=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
  fi
  CHANGED=$(echo "$RAW_DIFF" | grep -E '^(Formula/.*\.rb|Patches/)' | sed 's|^Formula/||;s|\.rb$||;s|^Patches/||;s|/.*||' | sort -u || true)

  for name in $CHANGED; do
    if [[ "$name" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]] && [ -f "Formula/${name}.rb" ]; then
      if grep -Fq 'root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/' "Formula/${name}.rb"; then
        if ! echo "$RAW_DIFF" | grep -Eq "^Patches/${name}/"; then
          echo "Skipping ${name}: bottle block already present for homebrew-nal."
          continue
        fi
      fi
      TARGETS+=("$name")
    fi
  done

  CHANGED_CASKS=$(echo "$RAW_DIFF" | grep -E '^Casks/.*\.rb$' | sed 's|^Casks/||;s|\.rb$||' | sort -u || true)
  for name in $CHANGED_CASKS; do
    if [[ "$name" =~ ^[a-zA-Z0-9._+-]+(@[a-zA-Z0-9._+-]+)?$ ]] && [ -f "Casks/${name}.rb" ]; then
      if grep -Fq 'https://github.com/Jaewoook/homebrew-nal/releases/download/cask-' "Casks/${name}.rb"; then
        echo "Skipping cask ${name}: mirrored binary URL already present for homebrew-nal."
        continue
      fi
      CASK_TARGETS+=("$name")
    fi
  done
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  JSON_ARRAY="[]"
  FORMULA_COUNT=0
else
  # Sort targets topologically so dependencies are built before dependents
  JSON_ARRAY=$(python3 - <<'EOF' "${TARGETS[@]}"
import sys, os, json, re

targets = sys.argv[1:]
target_set = set(targets)
adj = {t: set() for t in targets}

for t in targets:
    rb_path = f"Formula/{t}.rb"
    if not os.path.exists(rb_path):
        continue
    try:
        with open(rb_path, "r", encoding="utf-8") as f:
            content = f.read()
        matches = re.findall(r'depends_on\s+"(?:[^"]+/)?([^"]+)"', content)
        for m in matches:
            if m in target_set and m != t:
                adj[t].add(m)
    except Exception:
        pass

visited = {}
order = []

def dfs(node):
    if node in visited:
        return
    visited[node] = False
    for dep in sorted(adj.get(node, [])):
        dfs(dep)
    visited[node] = True
    order.append(node)

for t in sorted(targets):
    dfs(t)

print(json.dumps(order))
EOF
)
  FORMULA_COUNT=$(echo "$JSON_ARRAY" | jq '. | length')
fi

if [ ${#CASK_TARGETS[@]} -eq 0 ]; then
  CASK_JSON_ARRAY="[]"
  CASK_COUNT=0
else
  CASK_JSON_ARRAY=$(printf '%s\n' "${CASK_TARGETS[@]}" | jq -R . | jq -sc .)
  CASK_COUNT=$(echo "$CASK_JSON_ARRAY" | jq '. | length')
fi

COUNT=$(( FORMULA_COUNT + CASK_COUNT ))

echo "Formulas to build: $JSON_ARRAY (formula_count: $FORMULA_COUNT)"
echo "Casks to mirror:   $CASK_JSON_ARRAY (cask_count: $CASK_COUNT)"
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "formulas=$JSON_ARRAY" >> "$GITHUB_OUTPUT"
  echo "formula_count=$FORMULA_COUNT" >> "$GITHUB_OUTPUT"
  echo "casks=$CASK_JSON_ARRAY" >> "$GITHUB_OUTPUT"
  echo "cask_count=$CASK_COUNT" >> "$GITHUB_OUTPUT"
  echo "count=$COUNT" >> "$GITHUB_OUTPUT"
else
  echo "formulas=$JSON_ARRAY"
  echo "formula_count=$FORMULA_COUNT"
  echo "casks=$CASK_JSON_ARRAY"
  echo "cask_count=$CASK_COUNT"
  echo "count=$COUNT"
fi
