#!/usr/bin/env bash
set -euo pipefail

# Inputs from environment or defaults
FORMULA_INPUT="${FORMULA_INPUT:-}"
EVENT_NAME="${EVENT_NAME:-}"
EVENT_BEFORE="${EVENT_BEFORE:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

TARGETS=()

if [ -n "$FORMULA_INPUT" ]; then
  if [ "$FORMULA_INPUT" = "all" ]; then
    for f in Formula/*.rb; do
      [ -f "$f" ] || continue
      TARGETS+=("$(basename "$f" .rb)")
    done
  else
    CLEANED=$(echo "$FORMULA_INPUT" | tr ',' ' ')
    for name in $CLEANED; do
      if [ -f "Formula/${name}.rb" ]; then
        TARGETS+=("$name")
      else
        echo "::warning::Formula Formula/${name}.rb not found, skipping."
      fi
    done
  fi
elif [ "$EVENT_NAME" = "push" ]; then
  if [ -n "$EVENT_BEFORE" ] && [ "$EVENT_BEFORE" != "0000000000000000000000000000000000000000" ]; then
    CHANGED=$(git diff --name-only "$EVENT_BEFORE" HEAD 2>/dev/null | grep -E '^(Formula/.*\.rb|Patches/)' | sed 's|^Formula/||;s|\.rb$||;s|^Patches/||;s|/.*||' | sort -u || true)
  else
    CHANGED=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -E '^(Formula/.*\.rb|Patches/)' | sed 's|^Formula/||;s|\.rb$||;s|^Patches/||;s|/.*||' | sort -u || true)
  fi

  for name in $CHANGED; do
    if [ -f "Formula/${name}.rb" ]; then
      TARGETS+=("$name")
    fi
  done
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  JSON_ARRAY="[]"
  COUNT=0
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
  COUNT=$(echo "$JSON_ARRAY" | jq '. | length')
fi

echo "Formulas to build: $JSON_ARRAY (count: $COUNT)"
echo "formulas=$JSON_ARRAY" >> "$GITHUB_OUTPUT"
echo "count=$COUNT" >> "$GITHUB_OUTPUT"
