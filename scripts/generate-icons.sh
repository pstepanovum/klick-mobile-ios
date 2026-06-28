#!/usr/bin/env bash
# Convert the brand SVG icon set (design/icons/{Bold,Line}) into PDF template images inside
# Assets.xcassets, so `Image("ic_<name>")` can be tinted like SF Symbols.
#
# Requires one of: rsvg-convert (brew install librsvg) or cairosvg (pip install cairosvg).
# After running, swap `KlicIcon.symbol` usage for the generated `ic_<name>` assets.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="design/icons"
OUT="Resources/Assets.xcassets/Icons"
mkdir -p "$OUT"

convert() { # $1=svg  $2=pdf
  if command -v rsvg-convert >/dev/null; then rsvg-convert -f pdf -o "$2" "$1"
  elif command -v cairosvg  >/dev/null; then cairosvg "$1" -o "$2"
  else echo "Install librsvg (brew install librsvg) or cairosvg." >&2; exit 1
  fi
}

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g'; }

for variant in Bold Line; do
  for svg in "$SRC/$variant"/*.svg; do
    name="ic_$(slug "$variant")_$(slug "$(basename "$svg" .svg)")"
    set="$OUT/$name.imageset"; mkdir -p "$set"
    convert "$svg" "$set/$name.pdf"
    cat > "$set/Contents.json" <<JSON
{ "images":[{"idiom":"universal","filename":"$name.pdf"}],
  "info":{"author":"xcode","version":1},
  "properties":{"preserves-vector-representation":true,"template-rendering-intent":"template"} }
JSON
  done
done
echo "Generated template icons into $OUT"
