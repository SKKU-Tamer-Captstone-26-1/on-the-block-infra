# on-the-block-infra

On The Block 프로젝트의 인프라 레포입니다.  
proto 파일을 관리하고 [Buf Schema Registry(BSR)](https://buf.build)를 통해 각 서비스 레포에 배포합니다.

---

## 레포 구조

```
on-the-block-infra/
├── proto/on_the_block/v1/   ← .proto 파일 작성 위치
├── buf.yaml                 ← Buf 모듈 설정
├── buf.gen.yaml             ← Go 코드 생성 설정
├── buf.gen.spring.yaml      ← Spring(Java) 코드 생성 설정
├── docker-compose/          ← 로컬 개발 환경 가이드
├── scripts/                 ← 유틸리티 스크립트
└── .github/workflows/
    └── buf-push.yml         ← proto 변경 시 BSR 자동 배포
```

---

## 팀원 온보딩

### 1단계 — buf CLI 설치

**Mac**
```bash
brew install bufbuild/buf/buf
```

**Windows**
```powershell
# winget 사용
winget install bufbuild.buf

# 또는 scoop 사용
scoop install buf
```

설치 확인:
```bash
buf --version
```

---

### 2단계 — 서비스 레포에 buf 설정 추가

각 서비스 레포 루트에 아래 두 파일을 추가합니다.

#### `buf.yaml` (의존성 선언)

```yaml
version: v2
deps:
  - buf.build/on-the-block/api
```

#### `buf.gen.yaml` — Go 서비스용

```yaml
version: v2

inputs:
  - module: buf.build/on-the-block/api

plugins:
  - remote: buf.build/protocolbuffers/go
    out: pkg/proto/gen
    opt:
      - paths=source_relative
  - remote: buf.build/grpc/go
    out: pkg/proto/gen
    opt:
      - paths=source_relative
      - require_unimplemented_servers=false
```

#### `buf.gen.yaml` — Spring 서비스용

```yaml
version: v2

inputs:
  - module: buf.build/on-the-block/api

plugins:
  - remote: buf.build/protocolbuffers/java
    out: src/main/java
  - remote: buf.build/grpc/java
    out: src/main/java
```

---

### 3단계 — 의존성 잠금 및 코드 생성

```bash
# 처음 한 번만: 의존성 버전 잠금
buf dep update

# proto 코드 생성 (이후 매번 실행)
buf generate
```

---

## proto 수정 워크플로우 (인프라 담당자)

```
proto/ 파일 수정
    ↓
PR → main 머지
    ↓
GitHub Actions 자동 실행 (buf push → buf.build 업로드)
    ↓
각 서비스 팀원이 buf generate 실행
```

---

## 최초 설정 (레포 관리자)

BSR을 처음 세팅할 때 한 번만 수행합니다.

1. [buf.build](https://buf.build) 가입
2. 조직 `on-the-block` 생성
3. 모듈 `api` 생성 → `buf.build/on-the-block/api`
4. Settings → API Tokens에서 토큰 발급
5. GitHub 레포 Settings → Secrets → `BUF_TOKEN` 등록

이후로는 `main` 브랜치에 proto 변경이 머지되면 CI가 자동으로 BSR에 배포합니다.
