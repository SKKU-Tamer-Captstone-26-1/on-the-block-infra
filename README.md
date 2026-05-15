# on-the-block-infra

On The Block 프로젝트의 인프라 레포입니다.  
proto 파일을 관리하고 [Buf Schema Registry(BSR)](https://buf.build)를 통해 각 서비스 레포에 배포합니다.

---

## 레포 구조

```
on-the-block-infra/
├── proto/                   ← .proto 파일 작성 위치
│   ├── buf.yaml             ← Buf 모듈 설정
│   ├── auth/v1/auth.proto
│   ├── board/v1/board.proto
│   ├── chat/v1/chat.proto
│   ├── common/v1/common.proto
│   └── recommend/v1/recommend.proto
├── buf.gen.yaml             ← Go 코드 생성 설정 (로컬 검증용)
├── buf.gen.spring.yaml      ← Spring(Java) 코드 생성 설정 (로컬 검증용)
├── docker-compose/          ← 로컬 개발 환경 가이드
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

현재 BSR의 경우 public으로 레포를 열어둬서 BSR에서의 회원가입, organization 가입은 하지 않아도 아래 2단계로 넘어갈 수 있습니다.

---

### 2단계 — 서비스 레포에 buf 설정 추가

각 서비스 레포 루트에 아래 두 파일을 참조해서 추가합니다.
기본적으로는 담당자가 설정 파일 확인을 모든 레포에 대해서 할 예정입니다.

#### `buf.gen.yaml` — Go 서비스용 (gateway-service 기준)

```yaml
version: v2

inputs:
  - directory: proto

plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt:
      - paths=source_relative

  - remote: buf.build/grpc/go
    out: gen/go
    opt:
      - paths=source_relative
      - require_unimplemented_servers=false
```

> Go 서비스는 `proto/` 디렉토리에 필요한 `.proto` 파일을 직접 복사한 뒤 `buf generate`로 코드를 생성합니다.

#### `buf.gen.yaml` — Spring 서비스용 (board-service 기준)

```yaml
version: v2

inputs:
  - module: buf.build/on-the-block/infra
    paths:
      - board/v1   # 해당 서비스가 사용하는 도메인만 추가
      - common/v1  # 공통 타입 (페이지네이션 등)
      - auth/v1    # JWT claims 검증용 (필요한 서비스만 추가)

plugins:
  - remote: buf.build/protocolbuffers/java
    out: build/generated-sources/proto/java
  - remote: buf.build/grpc/java:v1.65.1
    out: build/generated-sources/proto/java
```

> Spring 서비스는 BSR에서 직접 모듈을 참조합니다. `paths`에는 해당 서비스가 실제로 사용하는 proto 경로만 추가하세요.

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
