#!/bin/sh
# 디자인 원본 검사: _sass/kit 자산이 기록한 해시와 같은지, 빌드 결과에 로컬 경로가 새지 않았는지.
# 사용: sh tools/design-check.sh [빌드 폴더, 기본 _site]
set -eu
cd "$(dirname "$0")/.."
site="${1:-_site}"

grep -v '^#' _sass/kit/SHA256SUMS | (cd _sass/kit && shasum -a 256 -c -)

[ -d "$site" ] || { echo "빌드 폴더 없음: $site (먼저 jekyll b)" >&2; exit 1; }
# 사이트에 kit 테마 CSS가 실제로 들어갔는지
grep -q -- '--kit-control-min' "$site/assets/css/jekyll-theme-chirpy.css" || { echo "kit 토큰이 CSS에 없음" >&2; exit 1; }
# 로컬 절대경로가 산출물에 있으면 실패
if grep -rIlE '/Users/|/home/|file://|claude-kit/skills/' "$site" --include='*.html' --include='*.css' --include='*.js' --include='*.xml' --include='*.json' --include='*.map'; then
  echo "빌드 결과에 로컬 경로가 있음" >&2; exit 1
fi
echo "design-check: OK"
