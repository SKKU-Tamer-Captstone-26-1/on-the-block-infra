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

#### `buf.gen.yaml` — Go 서비스용

```yaml
version: v2

inputs:
  - module: buf.build/on-the-block/infra
    paths:
      - chat/v1 #infra 레포에서 원하는 도메인 내역을 해당 paths에 추가하면 해당 path 내용만 복사됨
      - common/v1 #common에 공통사항 (jwt, oauth2 관련 인증 등)을 추가할 예정이라 항상 추가해둘 것

plugins:
  - remote: buf.build/protocolbuffers/go  
    out: proto
    opt:
      - paths=source_relative

  - remote: buf.build/grpc/go
    out: proto
    opt:
      - paths=source_relative
      - require_unimplemented_servers=false
```

#### `buf.gen.yaml` — Spring 서비스용

```yaml
version: v2

inputs:
  - module: buf.build/on-the-block/infra
    paths:
      - board/v1  #infra 레포에서 원하는 도메인 내역을 해당 paths에 추가하면 해당 path 내용만 복사됨
      - common/v1 #common에 공통사항 (jwt, oauth2 관련 인증 등)을 추가할 예정이라 항상 추가해둘 것
      - auth/v1   #auth gRPC 호출이 필요한 서비스만 추가

plugins:
  - remote: buf.build/protocolbuffers/java
    out: build/generated-sources/proto/java
  - remote: buf.build/grpc/java:v1.65.1
    out: build/generated-sources/proto/java
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
