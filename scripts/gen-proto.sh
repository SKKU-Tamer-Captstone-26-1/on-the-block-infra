#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">> buf로 코드 생성 시작..."
cd "$REPO_ROOT"

buf generate

echo ">> 생성 완료: gen/ 디렉토리를 확인하세요."
