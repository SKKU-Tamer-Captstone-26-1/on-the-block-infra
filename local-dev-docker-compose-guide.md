# 로컬 개발 환경 Docker Compose 가이드

> 각 마이크로서비스의 gRPC/HTTP 포트를 고정 관리하는 로컬 개발 환경 표준입니다.
> 로컬은 Docker Compose, 스테이징/프로덕션은 쿠버네티스를 사용합니다.

---

## 포트 할당표

서비스마다 포트를 고정 배정합니다. 새 서비스 추가 시 이 표에 먼저 등록합니다.

| 서비스 | gRPC 포트 | HTTP 포트 (필요 시) | 비고 |
|--------|-----------|-------------------|------|
| auth-service | 9090 | - |  |
| user-service | 9091 | - | |
| notification-service | 9092 | - | |
| board-service | 9093 | - | |
| api-gateway | 9099 | 8080 | 외부 진입점 |
| MySQL | - | 3306 | |
| Redis | - | 6379 | |

> 포트 추가/변경 시 이 표를 먼저 수정하고 해당 서비스 docker-compose.yml에 반영합니다.

---

## 구조

각 서비스 레포지토리 루트에 `docker-compose.yml`을 둡니다.

```
auth-service/
└── docker-compose.yml

user-service/
└── docker-compose.yml

api-gateway/
└── docker-compose.yml
```

서비스끼리 통신할 때는 **Docker 외부 네트워크(`msa-network`)를 공유**합니다.
네트워크는 한 번만 수동으로 만들어두면 됩니다.

```bash
docker network create msa-network
```

---

## 각 서비스 docker-compose.yml 예시

### auth-service

```yaml
# auth-service/docker-compose.yml
services:
  auth-service:
    build: .
    container_name: auth-service
    environment:
      - SPRING_PROFILES_ACTIVE=local
      - JWT_SECRET_KEY=${JWT_SECRET_KEY}
      - ADMIN_INITIAL_PASSWORD=${ADMIN_INITIAL_PASSWORD}
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/seniorvibe
    ports:
      - "9090:9090"   # 로컬에서 grpcurl로 직접 테스트할 때 사용
    networks:
      - msa-network
    depends_on:
      - mysql

  mysql:
    image: mysql:8.0
    container_name: auth-mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: seniorvibe
    ports:
      - "3306:3306"
    volumes:
      - auth-mysql-data:/var/lib/mysql
    networks:
      - msa-network

networks:
  msa-network:
    external: true   # docker network create msa-network 으로 미리 생성

volumes:
  auth-mysql-data:
```

### api-gateway (예시)

```yaml
# api-gateway/docker-compose.yml
services:
  api-gateway:
    build: .
    container_name: api-gateway
    environment:
      - SPRING_PROFILES_ACTIVE=local
      - AUTH_SERVICE_ADDRESS=auth-service:9090
      - USER_SERVICE_ADDRESS=user-service:9091
    ports:
      - "8080:8080"   # 외부 진입점 — Flutter, Admin 웹이 여기로 붙음
    networks:
      - msa-network

networks:
  msa-network:
    external: true
```

---

## 서비스 간 통신

컨테이너 내부에서는 **서비스 이름:포트**로 통신합니다. 호스트 포트 매핑 없이도 동작합니다.

```
api-gateway → auth-service:9090   (Docker 내부 네트워크)
api-gateway → user-service:9091
auth-service → mysql:3306
```

호스트(내 맥/윈도우)에서 직접 찍을 때만 `localhost:{호스트포트}`를 씁니다.

```bash
# 로컬에서 auth-service gRPC 직접 테스트
grpcurl -plaintext localhost:9090 auth.AuthService/ValidateToken
```

---

## 기동 / 종료

```bash
# 서비스 단독 기동 (해당 서비스 디렉터리에서)
docker compose up -d

# 로그 확인
docker compose logs -f auth-service

# 종료
docker compose down

# DB 볼륨까지 초기화
docker compose down -v
```

전체 스택을 한 번에 올리고 싶으면 루트에 별도 `docker-compose.local.yml`을 만들어 각 서비스를 include하는 방식도 가능합니다.

---

## 환경변수 관리

각 서비스 루트에 `.env` 파일을 두고 `docker-compose.yml`이 자동으로 읽게 합니다.
`.env`는 `.gitignore`에 추가하고, `.env.example`만 커밋합니다.

```bash
# auth-service/.env.example
JWT_SECRET_KEY=
ADMIN_INITIAL_PASSWORD=
DB_ROOT_PASSWORD=
```

---

## 로컬 vs 프로덕션 비교

| 항목 | 로컬 (Docker Compose) | 프로덕션 (쿠버네티스) |
|------|----------------------|-------------------|
| 오케스트레이션 | docker compose up | kubectl / Helm |
| 서비스 디스커버리 | 컨테이너 이름 (DNS) | Service / Ingress |
| 포트 관리 | 이 문서의 포트 할당표 | ClusterIP 내부 통신 |
| 스케일링 | 단일 인스턴스 | HPA 자동 스케일 |


---

맞아요. 서비스마다 DB를 따로 띄우면 포트도 겹칩니다.

방법이 두 가지입니다.

**방법 A: DB도 포트 고정 배정**
```
auth-service  MySQL → 3306
user-service  MySQL → 3307
notification  MySQL → 3308
```
단순하지만 서비스 늘어날수록 관리할 포트가 많아집니다.

**방법 B: DB는 호스트 포트 노출 안 함 (권장)**
```yaml
# auth-service/docker-compose.yml
services:
  auth-service:
    ports:
      - "9090:9090"   # 노출
  mysql:
    # ports 없음 → 호스트에서 직접 접근 불가
    # auth-service 컨테이너에서만 mysql:3306으로 접근
```
DB는 어차피 해당 서비스 컨테이너에서만 쓰니까 호스트에 노출할 이유가 없습니다. DB 직접 들여다봐야 할 때만 임시로 포트 열면 됩니다.

MSA에서 **DB는 서비스당 하나, 외부 노출 안 함**이 원칙이라 방법 B가 맞습니다. 문서 포트 할당표에서 DB 포트 칸 빼도 될 것 같아요.