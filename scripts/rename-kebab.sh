#!/usr/bin/env bash
# Rename all subdirectories under Sources/ and Widget/ from PascalCase/TitleCase
# to lowercase kebab-case, then regenerate the Xcode project via xcodegen.
#
# Usage: bash scripts/rename-kebab.sh
# Run from the klick-mobile-ios directory.
set -euo pipefail
cd "$(dirname "$0")/.."

to_kebab() {
  # PascalCase or TitleCase → kebab-case
  # e.g.  DesignSystem → design-system   App → app   FriendRequests → friend-requests
  echo "$1" \
    | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' \
    | sed -E 's/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[[:space:]]+/-/g; s/--+/-/g; s/^-|-$//g'
}

rename_dirs() {
  local base="$1"
  # Process deepest directories first (depth-first, post-order)
  while IFS= read -r -d '' dir; do
    parent="$(dirname "$dir")"
    name="$(basename "$dir")"
    kebab="$(to_kebab "$name")"
    if [ "$name" != "$kebab" ]; then
      echo "  $dir → $parent/$kebab"
      mv "$dir" "$parent/$kebab"
    fi
  done < <(find "$base" -mindepth 1 -type d -print0 | sort -rz)
}

echo "Renaming Sources/ …"
rename_dirs Sources

echo "Renaming Widget/ …"
rename_dirs Widget

# Update project.yml references (Sources → sources, etc.)
# Sources/ and Widget/ themselves are root-level; keep as-is since project.yml
# references them by name. Only sub-directories were renamed above.

echo "Regenerating Xcode project …"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
  echo "Done — project regenerated."
else
  echo "xcodegen not found; run 'brew install xcodegen' then 'xcodegen generate' manually."
fi
