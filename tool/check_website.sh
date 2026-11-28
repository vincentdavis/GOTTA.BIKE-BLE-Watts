#!/usr/bin/env bash
# Checks website/ before it goes live. Cloudflare Pages runs this as the
# build command (see website/README.md), so a deploy fails while any
# [PLACEHOLDER] is left or a page links to a local file that doesn't exist.
set -euo pipefail
cd "$(dirname "$0")/../website"

status=0
if grep -nE '\[[A-Z][A-Z0-9 ,.()'"'"'-]{2,}\]' -- *.html; then
  echo "error: fill in the [PLACEHOLDERS] above before publishing." >&2
  status=1
fi

# Every local href/src must exist (external links and anchors are skipped).
for page in *.html; do
  while IFS= read -r ref; do
    case "$ref" in
      '' | http://* | https://* | mailto:* | /* | '['*) continue ;;
    esac
    if [ ! -e "$ref" ]; then
      echo "error: $page links to missing file: $ref" >&2
      status=1
    fi
  done < <(grep -oE '(href|src)="[^"#]*' "$page" | sed -E 's/^(href|src)="//')
done

[ "$status" -eq 0 ] && echo "website OK"
exit "$status"
