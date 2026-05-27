#!/usr/bin/env bash
set -euo pipefail

ROOT="imgs"
QUALITY="88"
EFFORT="6"
MIN_SAVINGS="1"
FORCE=0
KEEP_LARGER=0
REPLACE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: scripts/convert-images-to-webp.sh [options] [directory]

Convert PNG/JPEG/TIFF images to WebP while keeping visual quality high.
By default, the script writes .webp files next to originals and only keeps
the WebP when it is smaller than the source image.

Options:
  -q, --quality N        WebP quality, 0-100. Default: 88
  -e, --effort N         Encoder effort, 0-6. Default: 6
  --min-savings N        Minimum percent smaller to keep output. Default: 1
  --replace              Delete the original after a smaller WebP is created
  --keep-larger          Keep WebP even when it is not smaller
  -f, --force            Rebuild existing .webp files
  -n, --dry-run          Show what would be converted
  -h, --help             Show this help

Examples:
  scripts/convert-images-to-webp.sh
  scripts/convert-images-to-webp.sh --quality 90 --replace imgs
  scripts/convert-images-to-webp.sh --dry-run .

Install an encoder if needed:
  brew install webp
  brew install imagemagick
  brew install ffmpeg

If none of those command-line encoders exist, the script can also use
Python Pillow when it has WebP support.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quality)
      QUALITY="${2:-}"
      shift 2
      ;;
    -e|--effort)
      EFFORT="${2:-}"
      shift 2
      ;;
    --min-savings)
      MIN_SAVINGS="${2:-}"
      shift 2
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    --keep-larger)
      KEEP_LARGER=1
      shift
      ;;
    -f|--force)
      FORCE=1
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      ROOT="$1"
      shift
      ;;
  esac
done

if [[ ! -d "$ROOT" ]]; then
  echo "Directory not found: $ROOT" >&2
  exit 1
fi

if ! [[ "$QUALITY" =~ ^[0-9]+$ ]] || (( QUALITY < 0 || QUALITY > 100 )); then
  echo "--quality must be an integer from 0 to 100" >&2
  exit 2
fi

if ! [[ "$EFFORT" =~ ^[0-6]$ ]]; then
  echo "--effort must be an integer from 0 to 6" >&2
  exit 2
fi

if ! [[ "$MIN_SAVINGS" =~ ^[0-9]+$ ]] || (( MIN_SAVINGS < 0 || MIN_SAVINGS > 99 )); then
  echo "--min-savings must be an integer from 0 to 99" >&2
  exit 2
fi

ENCODER=""
PYTHON_BIN=""
if command -v cwebp >/dev/null 2>&1; then
  ENCODER="cwebp"
elif command -v magick >/dev/null 2>&1; then
  ENCODER="magick"
elif command -v convert >/dev/null 2>&1; then
  ENCODER="convert"
elif command -v ffmpeg >/dev/null 2>&1; then
  ENCODER="ffmpeg"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'from PIL import features; raise SystemExit(0 if features.check("webp") else 1)' >/dev/null 2>&1; then
  ENCODER="python-pillow"
  PYTHON_BIN="$(command -v python3)"
else
  if [[ "$DRY_RUN" -eq 0 ]]; then
    cat >&2 <<'MSG'
No WebP encoder found.

Install one of these, then rerun:
  brew install webp
  brew install imagemagick
  brew install ffmpeg

Or install Python Pillow with WebP support:
  python3 -m pip install Pillow
MSG
    exit 1
  fi
  ENCODER="dry-run"
fi

size_bytes() {
  if stat -f%z "$1" >/dev/null 2>&1; then
    stat -f%z "$1"
  else
    stat -c%s "$1"
  fi
}

human_bytes() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB", u, " ");
    i = 1;
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

encode_webp() {
  local src="$1"
  local dst="$2"

  case "$ENCODER" in
    cwebp)
      cwebp -quiet -q "$QUALITY" -m "$EFFORT" -alpha_q 92 -metadata icc "$src" -o "$dst"
      ;;
    magick)
      magick "$src" -quality "$QUALITY" -define webp:method="$EFFORT" -define webp:alpha-quality=92 "$dst"
      ;;
    convert)
      convert "$src" -quality "$QUALITY" -define webp:method="$EFFORT" -define webp:alpha-quality=92 "$dst"
      ;;
    ffmpeg)
      ffmpeg -hide_banner -loglevel error -y -i "$src" -compression_level "$EFFORT" -q:v "$((100 - QUALITY))" "$dst"
      ;;
    python-pillow)
      "$PYTHON_BIN" - "$src" "$dst" "$QUALITY" "$EFFORT" <<'PY'
import sys
from PIL import Image, ImageOps

src, dst, quality, effort = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

with Image.open(src) as image:
    image = ImageOps.exif_transpose(image)
    icc_profile = image.info.get("icc_profile")

    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGBA" if "A" in image.getbands() else "RGB")

    save_kwargs = {
        "format": "WEBP",
        "quality": quality,
        "method": effort,
        "alpha_quality": 92,
    }
    if icc_profile:
        save_kwargs["icc_profile"] = icc_profile

    image.save(dst, **save_kwargs)
PY
      ;;
  esac
}

converted=0
skipped=0
replaced=0
removed_larger=0
failed=0
source_total=0
kept_source_total=0
webp_total=0

echo "Root: $ROOT"
echo "Encoder: $ENCODER"
echo "Quality: $QUALITY, effort: $EFFORT"
echo

while IFS= read -r -d '' src; do
  dst="${src%.*}.webp"

  if [[ "$src" == "$dst" ]]; then
    ((skipped += 1))
    continue
  fi

  if [[ -e "$dst" && "$FORCE" -eq 0 && "$dst" -nt "$src" ]]; then
    if (( REPLACE == 1 )); then
      src_size="$(size_bytes "$src")"
      webp_size="$(size_bytes "$dst")"

      if (( webp_size < src_size )); then
        rm "$src"
        echo "replace existing: $src -> $dst ($(human_bytes "$src_size") -> $(human_bytes "$webp_size"))"
        ((replaced += 1))
        continue
      fi
    fi

    echo "skip existing: $dst"
    ((skipped += 1))
    continue
  fi

  src_size="$(size_bytes "$src")"
  ((source_total += src_size))

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "would convert: $src -> $dst"
    ((converted += 1))
    continue
  fi

  tmp="${dst}.tmp.$$"
  if ! encode_webp "$src" "$tmp"; then
    echo "failed: $src" >&2
    rm -f "$tmp"
    ((failed += 1))
    continue
  fi

  webp_size="$(size_bytes "$tmp")"
  keep_limit=$(( src_size * (100 - MIN_SAVINGS) / 100 ))

  if (( KEEP_LARGER == 0 && webp_size >= keep_limit )); then
    rm -f "$tmp"
    echo "not smaller enough: $src ($(human_bytes "$src_size") -> $(human_bytes "$webp_size"))"
    ((removed_larger += 1))
    continue
  fi

  mv "$tmp" "$dst"
  ((kept_source_total += src_size))
  ((webp_total += webp_size))
  ((converted += 1))

  saved=$((src_size - webp_size))
  percent="$(awk -v s="$src_size" -v w="$webp_size" 'BEGIN { printf "%.1f", (s - w) * 100 / s }')"
  echo "ok: $src -> $dst ($(human_bytes "$src_size") -> $(human_bytes "$webp_size"), saved ${percent}%)"

  if (( REPLACE == 1 && webp_size < src_size )); then
    rm "$src"
    ((replaced += 1))
  fi
done < <(
  find "$ROOT" -type f \( \
    -iname '*.png' -o \
    -iname '*.jpg' -o \
    -iname '*.jpeg' -o \
    -iname '*.tif' -o \
    -iname '*.tiff' \
  \) -print0
)

echo
echo "Done."
echo "Converted: $converted"
echo "Skipped: $skipped"
echo "Not kept because larger: $removed_larger"
echo "Replaced originals: $replaced"
echo "Failed: $failed"

if (( DRY_RUN == 0 && converted > 0 )); then
  saved_total=$((kept_source_total - webp_total))
  echo "Converted source total: $(human_bytes "$kept_source_total")"
  echo "WebP total kept: $(human_bytes "$webp_total")"
  echo "Approx. saved across kept conversions: $(human_bytes "$saved_total")"
fi

if (( failed > 0 )); then
  exit 1
fi
