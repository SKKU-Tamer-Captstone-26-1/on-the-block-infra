# Docker Compose — 로컬 개발 환경 가이드

> 이 디렉토리는 On The Block 프로젝트의 로컬 개발 인프라를 Docker Compose로 관리합니다.
> 아직 서비스가 확정되지 않은 시점이므로, 이 문서는 개념·명령어·설정 파일 구조를 먼저 정리합니다.

---

## 목차

1. [Docker Compose란?](#1-docker-compose란)
2. [핵심 개념](#2-핵심-개념)
3. [설정 파일 구조](#3-설정-파일-구조)
4. [자주 쓰는 명령어](#4-자주-쓰는-명령어)
5. [환경변수 관리](#5-환경변수-관리)
6. [파일 분리 전략 (override 패턴)](#6-파일-분리-전략-override-패턴)
7. [이 프로젝트에서 사용할 구성 예시](#7-이-프로젝트에서-사용할-구성-예시)

---

## 1. Docker Compose란?

**Docker Compose**는 여러 컨테이너를 하나의 YAML 파일로 선언하고, 단일 명령어로 올리고 내리는 도구입니다.

- 각 컨테이너를 **서비스(service)** 단위로 정의
- 서비스 간 네트워크·볼륨을 자동으로 구성
- 로컬 개발 환경을 팀 전체가 동일하게 재현 가능

```
docker compose up -d   # 전체 서비스 실행
docker compose down    # 전체 서비스 종료 및 네트워크 제거
```

---

## 2. 핵심 개념

| 개념 | 설명 |
|------|------|
| **service** | 하나의 컨테이너 단위. `image` 또는 `build`로 정의 |
| **image** | 사용할 Docker 이미지 (예: `postgres:16`) |
| **build** | Dockerfile 경로를 지정해 이미지를 직접 빌드 |
| **ports** | `호스트포트:컨테이너포트` 형태로 포트 노출 |
| **volumes** | 데이터 영속성 보장. 컨테이너가 삭제돼도 데이터 유지 |
| **networks** | 서비스 간 통신 채널. 기본적으로 compose 프로젝트 단위로 격리 |
| **environment** | 컨테이너 안에 주입할 환경변수 |
| **depends_on** | 서비스 시작 순서 의존성 (단, 헬스체크와 다름에 주의) |
| **healthcheck** | 컨테이너가 실제로 준비됐는지 확인하는 명령어 |

---

## 3. 설정 파일 구조

```yaml
# docker-compose.yml 기본 골격

services:
  서비스명:
    image: 이미지:태그          # 또는 build: ./경로
    container_name: 컨테이너명  # 생략 가능 (자동 생성됨)
    restart: unless-stopped     # 재시작 정책
    ports:
      - "호스트:컨테이너"
    environment:
      KEY: value
    env_file:
      - .env                    # 파일로 환경변수 주입
    volumes:
      - 볼륨명:/컨테이너/경로
      - ./호스트경로:/컨테이너경로  # 바인드 마운트
    networks:
      - 네트워크명
    depends_on:
      다른서비스:
        condition: service_healthy  # 헬스체크 통과 후 시작
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  볼륨명:                       # 명명된 볼륨 선언

networks:
  네트워크명:                   # 명명된 네트워크 선언
```

### 자주 쓰는 서비스 예시

#### PostgreSQL

```yaml
postgres:
  image: postgres:16-alpine
  ports:
    - "5432:5432"
  environment:
    POSTGRES_USER: ${DB_USER:-dev}
    POSTGRES_PASSWORD: ${DB_PASSWORD:-dev}
    POSTGRES_DB: ${DB_NAME:-on_the_block}
  volumes:
    - postgres_data:/var/lib/postgresql/data
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-dev}"]
    interval: 5s
    timeout: 5s
    retries: 5
```

#### Redis

```yaml
redis:
  image: redis:7-alpine
  ports:
    - "6379:6379"
  volumes:
    - redis_data:/data
  healthcheck:
    test: ["CMD", "redis-cli", "ping"]
    interval: 5s
    timeout: 3s
    retries: 5
```

#### 애플리케이션 서비스 (Dockerfile 빌드)

```yaml
backend:
  build:
    context: ../on-the-block-backend
    dockerfile: Dockerfile
    target: dev              # 멀티스테이지 빌드 타겟 지정
  ports:
    - "8080:8080"
  env_file:
    - .env
  volumes:
    - ../on-the-block-backend:/app   # 소스 핫리로드용 바인드 마운트
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy
```

---

## 4. 자주 쓰는 명령어

### 시작 / 종료

```bash
# 전체 서비스를 백그라운드로 실행
docker compose up -d

# 특정 서비스만 실행
docker compose up -d postgres redis

# 전체 서비스 종료 (컨테이너·네트워크 제거, 볼륨은 유지)
docker compose down

# 볼륨까지 함께 제거 (데이터 초기화)
docker compose down -v
```

### 상태 확인

```bash
# 실행 중인 서비스 목록과 상태
docker compose ps

# 특정 서비스 로그 스트리밍
docker compose logs -f backend

# 전체 로그 (최근 100줄)
docker compose logs --tail=100
```

### 재빌드 / 재시작

```bash
# 이미지 다시 빌드 후 재시작
docker compose up -d --build backend

# 특정 서비스만 재시작 (이미지 재빌드 없음)
docker compose restart backend

# 변경된 서비스만 재생성
docker compose up -d --force-recreate backend
```

### 컨테이너 접속

```bash
# 실행 중인 컨테이너에 쉘 접속
docker compose exec postgres sh
docker compose exec postgres psql -U dev on_the_block

# 새 컨테이너를 띄워서 명령 실행 후 제거
docker compose run --rm backend go test ./...
```

### 정리

```bash
# 사용하지 않는 이미지·컨테이너·캐시 전체 정리
docker system prune -f

# 볼륨까지 포함해서 정리 (주의: 데이터 삭제됨)
docker system prune -f --volumes
```

---

## 5. 환경변수 관리

### .env 파일 패턴

```
docker-compose/
├── docker-compose.yml
├── .env              ← 실제 값 (git 제외, .gitignore에 추가)
└── .env.example      ← 키 목록만 커밋 (팀원이 복사해서 값 채움)
```

**.env.example 예시:**

```dotenv
# Database
DB_USER=
DB_PASSWORD=
DB_NAME=on_the_block

# Redis
REDIS_PASSWORD=

# App
APP_PORT=8080
JWT_SECRET=
```

**.gitignore에 반드시 추가:**

```gitignore
docker-compose/.env
```

### compose 파일에서 변수 참조

```yaml
environment:
  POSTGRES_USER: ${DB_USER}          # .env 값 그대로 사용
  POSTGRES_PASSWORD: ${DB_PASSWORD:-secret}  # 없으면 기본값 'secret'
```

---

## 6. 파일 분리 전략 (override 패턴)

환경별로 설정을 달리할 때 **파일 분리 + merge** 방식을 씁니다.

```
docker-compose/
├── docker-compose.yml           ← 공통 기반 (서비스 정의)
├── docker-compose.override.yml  ← 로컬 개발용 덮어쓰기 (자동 적용)
└── docker-compose.prod.yml      ← 프로덕션용 (명시적으로 지정)
```

`docker-compose.override.yml`은 **`docker compose up` 시 자동으로 merge**됩니다.

```bash
# 로컬 개발 (base + override 자동 적용)
docker compose up -d

# 프로덕션 (base + prod 명시)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

**override 파일 예시 (로컬 개발용):**

```yaml
# docker-compose.override.yml
services:
  backend:
    volumes:
      - ../on-the-block-backend:/app   # 소스 핫리로드
    environment:
      LOG_LEVEL: debug
  postgres:
    ports:
      - "5432:5432"                    # 로컬에서 DB 직접 접속 허용
```

---

## 7. 이 프로젝트에서 사용할 구성 예시

> 서비스가 확정되면 아래 예시를 바탕으로 `docker-compose.yml`을 작성하세요.

```yaml
# docker-compose/docker-compose.yml (초안 예시)
services:

  postgres:
    image: postgres:16-alpine
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: ${DB_USER:-dev}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-dev}
      POSTGRES_DB: ${DB_NAME:-on_the_block}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-dev}"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  # backend:            ← 백엔드 레포가 확정되면 추가
  #   build:
  #     context: ../../on-the-block-backend

volumes:
  postgres_data:
  redis_data:
```

> **다음 단계:** 백엔드·프론트엔드 레포가 정해지면 각 서비스를 `services` 블록에 추가하고,
> `.env.example`을 채워 팀원과 공유하세요.
