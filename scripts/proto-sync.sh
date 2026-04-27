#!/usr/bin/env bash
# proto-sync.sh: 생성된 코드를 각 서비스 레포로 복사합니다.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN_DIR="$REPO_ROOT/gen/go"

# 동기화 대상 서비스 레포 경로 (필요에 따라 추가)
declare -A TARGETS=(
  # ["서비스명"]="../레포-경로/내부/proto-위치"
  # ["backend"]="../on-the-block-backend/internal/proto"
)

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "TARGETS가 비어 있습니다. proto-sync.sh 상단의 TARGETS를 설정하세요."
  exit 1
fi

echo ">> proto 동기화 시작..."

for service in "${!TARGETS[@]}"; do
  dest="${TARGETS[$service]}"
  echo "  -> $service: $GEN_DIR → $dest"
  mkdir -p "$dest"
  rsync -av --delete "$GEN_DIR/" "$dest/"
done

echo ">> 동기화 완료."
