#!/usr/bin/env bash
#
# Tạo GitHub Issues từ planning/issues/*.md
#
# Mỗi file issue có frontmatter:
#   ---
#   title: "S1-01: ..."
#   labels: infra,module:warehouse,sprint:1,size:L
#   ---
#   <body markdown>
#
# Dùng:
#   bash planning/scripts/create-issues.sh            # tạo label + issue
#   bash planning/scripts/create-issues.sh --dry-run  # chỉ in ra, không tạo gì
#
# Yêu cầu: gh CLI đã cài + `gh auth login`. Chạy ở thư mục gốc repo (có remote GitHub).

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_DIR="$SCRIPT_DIR/../issues"

if ! command -v gh >/dev/null 2>&1; then
  echo "✗ Chưa có 'gh'. Cài GitHub CLI rồi 'gh auth login' trước." >&2
  exit 1
fi

# Trích giá trị 1 khóa frontmatter (title|labels) từ file.
frontmatter() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---[ \t]*$/ { n++; next }
    n==1 && $0 ~ "^"k":" {
      sub("^"k":[ \t]*", ""); gsub(/^"|"$/, ""); print; exit
    }
  ' "$file"
}

# Body = phần sau khối frontmatter thứ 2.
body() {
  awk '/^---[ \t]*$/ { n++; next } n>=2 { print }' "$1"
}

# Gom mọi label để tạo trước (idempotent).
echo "==> Thu thập label..."
declare -A LABELS=()
for f in "$ISSUE_DIR"/*.md; do
  IFS=',' read -ra ls <<< "$(frontmatter "$f" labels)"
  for l in "${ls[@]}"; do
    l="$(echo "$l" | xargs)"   # trim
    [[ -n "$l" ]] && LABELS["$l"]=1
  done
done

echo "==> Tạo label (bỏ qua nếu đã tồn tại)..."
for l in "${!LABELS[@]}"; do
  if $DRY_RUN; then
    echo "  [dry-run] gh label create '$l'"
  else
    gh label create "$l" --force >/dev/null 2>&1 || true
  fi
done

echo "==> Tạo issue..."
for f in $(ls "$ISSUE_DIR"/*.md | sort); do
  title="$(frontmatter "$f" title)"
  labels="$(frontmatter "$f" labels)"
  tmp="$(mktemp)"
  body "$f" > "$tmp"
  if $DRY_RUN; then
    echo "  [dry-run] gh issue create --title \"$title\" --label \"$labels\" --body-file $(basename "$f")"
  else
    gh issue create --title "$title" --label "$labels" --body-file "$tmp" \
      && echo "  ✓ $title"
  fi
  rm -f "$tmp"
done

echo "Xong."
