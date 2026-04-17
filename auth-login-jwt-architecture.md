# gRPC 기반 인증 서비스 구현 가이드 (On the Block)

> auth-service는 REST 엔드포인트를 노출하지 않습니다. 모든 통신은 gRPC(포트 9090)로만 이루어집니다.
> Gateway가 HTTP -> gRPC 변환을 담당합니다.

---

## 목차

1. [전체 MSA 구조 개요](#1-전체-msa-구조-개요)
2. [프로젝트 셋업](#2-프로젝트-셋업)
3. [Proto 파일 정의](#3-proto-파일-정의)
4. [내부 구조 및 파일 목록](#4-내부-구조-및-파일-목록)
5. [gRPC 서비스 구현 골격](#5-grpc-서비스-구현-골격)
6. [Google 소셜 로그인 내부 로직](#6-google-소셜-로그인-내부-로직)
7. [어드민 로그인 내부 로직](#7-어드민-로그인-내부-로직)
8. [관리형 계정 생성 (ROLE_BAR / ROLE_REQUE)](#8-관리형-계정-생성-role_bar--role_reque)
9. [JWT 토큰 로직 (RS256)](#9-jwt-토큰-로직-rs256)
10. [토큰 갱신 흐름](#10-토큰-갱신-흐름)
11. [토큰 검증 흐름 (Zero Trust)](#11-토큰-검증-흐름-zero-trust)
12. [유저 엔티티 및 권한](#12-유저-엔티티-및-권한)
13. [환경 설정](#13-환경-설정)

---

## 1. 전체 MSA 구조 개요

```
React / Flutter
      |
      | REST / gRPC-Web
      v
  [Gateway]  -- JWT 1차 검증 (서명 + 만료, Public Key)
      |         HTTP -> gRPC 변환, 라우팅
      | gRPC
      v
 [auth-service]  포트 9090
      |
      +-- PostgreSQL (auth 스키마)
      +-- Redis (리프레시 토큰 캐시)

타 마이크로서비스 (Community / Recommend)
      |
      | gRPC (ValidateToken 직접 호출, Zero Trust 2차 검증)
      v
 [auth-service]
```

### JWT 검증 2단계

| 단계 | 위치 | 검증 내용 |
|------|------|---------|
| 1차 | Gateway | Public Key로 서명 검증 + 만료 확인 |
| 2차 | 각 서비스 | ValidateToken gRPC 호출 -> claims(userId, role) 확인 |

### 엔드포인트 요약

| HTTP (Gateway) | gRPC RPC | JWT 필요 | 설명 |
|----------------|----------|---------|------|
| POST /auth/google | GoogleLogin | 불필요 | Google ID Token -> 앱 JWT 발급 |
| POST /auth/admin | AdminLogin | 불필요 | username/password -> JWT 발급 |
| POST /auth/refresh | RefreshToken | 불필요 | 리프레시 토큰 로테이션 |
| GET /auth/me | GetMe | 필요 | 현재 유저 정보 조회 |
| POST /auth/logout | Logout | 필요 | 리프레시 토큰 전체 폐기 |
| POST /auth/admin/users | AdminCreateUser | 필요 (ROLE_ADMIN) | BAR/REQUE 계정 생성 |
| 내부 gRPC 전용 | ValidateToken | - | 타 서비스 Zero Trust 검증 |

---

## 2. 프로젝트 셋업

### build.gradle

```gradle
plugins {
    id 'java'
    id 'org.springframework.boot' version '3.x.x'
    id 'com.google.protobuf' version '0.9.4'
}

dependencies {
    // gRPC
    implementation 'net.devh:grpc-server-spring-boot-starter:3.x.x'
    implementation 'io.grpc:grpc-protobuf:1.x.x'
    implementation 'io.grpc:grpc-stub:1.x.x'
    implementation 'com.google.protobuf:protobuf-java:3.x.x'

    // JWT (RS256)
    implementation 'io.jsonwebtoken:jjwt-api:0.12.x'
    runtimeOnly   'io.jsonwebtoken:jjwt-impl:0.12.x'
    runtimeOnly   'io.jsonwebtoken:jjwt-jackson:0.12.x'

    // Google ID Token 검증
    implementation 'com.google.auth:google-auth-library-oauth2-http:1.x.x'

    // DB / Cache
    implementation 'org.springframework.boot:spring-boot-starter-data-jpa'
    implementation 'org.springframework.boot:spring-boot-starter-data-redis'
    runtimeOnly   'org.postgresql:postgresql'

    // 보안 (BCrypt)
    implementation 'org.springframework.security:spring-security-crypto'
    implementation 'org.springframework.boot:spring-boot-starter-validation'
}

protobuf {
    protoc { artifact = 'com.google.protobuf:protoc:3.x.x' }
    plugins {
        grpc { artifact = 'io.grpc:protoc-gen-grpc-java:1.x.x' }
    }
    generateProtoTasks {
        all()*.plugins { grpc {} }
    }
}
```

### application.yml

```yaml
grpc:
  server:
    port: 9090

spring:
  datasource:
    url: jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}?currentSchema=auth
    username: ${DB_USER}
    password: ${DB_PASSWORD}
  data:
    redis:
      host: ${REDIS_HOST}
      port: 6379
  jpa:
    hibernate:
      ddl-auto: validate

jwt:
  private-key: ${JWT_PRIVATE_KEY}   # RS256 PEM 개인키 (auth-service 전용)
  public-key: ${JWT_PUBLIC_KEY}     # RS256 PEM 공개키 (Gateway, 타 서비스에도 배포)
  access-token-expiration: 30       # 분 (운영: 15~30분)
  refresh-token-expiration: 10080   # 분 (7일)

google:
  client-id: ${GOOGLE_CLIENT_ID}    # ID Token aud 검증에 사용
```

---

## 3. Proto 파일 정의

실제 파일 위치: `proto/auth/v1/auth.proto` (infra 레포 단일 출처)

```protobuf
syntax = "proto3";

package ontheblock.auth.v1;

option java_package = "com.ontheblock.auth.v1";
option java_multiple_files = true;
option go_package = "github.com/ontheblock/infra/proto/auth/v1;authv1";

import "google/protobuf/timestamp.proto";

// AuthService exposes internal gRPC endpoints consumed by Gateway and other services.
// REST endpoints (POST /auth/google, POST /auth/admin, POST /auth/refresh, etc.) are handled by
// Gateway which translates HTTP -> gRPC calls to this service.
service AuthService {
  // GoogleLogin verifies a Google ID Token, finds or creates the user,
  // and returns a token pair. Called by Gateway for POST /auth/google.
  rpc GoogleLogin(GoogleLoginRequest) returns (GoogleLoginResponse);

  // AdminLogin authenticates an admin user with username and password,
  // and returns a token pair. Called by Gateway for POST /auth/admin.
  rpc AdminLogin(AdminLoginRequest) returns (AuthTokenResponse);

  // AdminCreateUser creates a managed user account (ROLE_BAR or ROLE_REQUE).
  // Only callable by ROLE_ADMIN. Called by Gateway for POST /auth/admin/users (JWT required).
  rpc AdminCreateUser(AdminCreateUserRequest) returns (AdminCreateUserResponse);

  // RefreshToken rotates the refresh token and returns a new token pair.
  // Called by Gateway for POST /auth/refresh.
  rpc RefreshToken(RefreshTokenRequest) returns (AuthTokenResponse);

  // GetMe returns the authenticated user's profile.
  // Called by Gateway for GET /auth/me (JWT required).
  rpc GetMe(GetMeRequest) returns (UserResponse);

  // Logout revokes all refresh tokens for the user.
  // Called by Gateway for POST /auth/logout (JWT required).
  rpc Logout(LogoutRequest) returns (LogoutResponse);

  // ValidateToken validates a JWT and returns the claims.
  // Called by other services for Zero Trust secondary validation.
  rpc ValidateToken(ValidateTokenRequest) returns (ValidateTokenResponse);
}

// --- GoogleLogin ---

message GoogleLoginRequest {
  string id_token = 1; // Google ID Token from client
}

message GoogleLoginResponse {
  string access_token = 1;
  string refresh_token = 2;
  google.protobuf.Timestamp access_token_expires_at = 3;
  google.protobuf.Timestamp refresh_token_expires_at = 4;
  UserResponse user = 5;
  bool is_new_user = 6; // true if the user was created during this login
}

// --- AdminLogin ---

message AdminLoginRequest {
  string username = 1;
  string password = 2;
}

// --- AdminCreateUser ---

message AdminCreateUserRequest {
  string username = 1;
  string password = 2;
  Role role = 3; // must be ROLE_BAR or ROLE_REQUE; ROLE_ADMIN rejected by service layer
}

message AdminCreateUserResponse {
  UserResponse user = 1;
}

// --- RefreshToken ---

message RefreshTokenRequest {
  string refresh_token = 1;
}

// --- GetMe ---

message GetMeRequest {
  string user_id = 1;
}

// --- Logout ---

message LogoutRequest {
  string user_id = 1;
}

message LogoutResponse {}

// --- ValidateToken ---

message ValidateTokenRequest {
  string access_token = 1;
}

message ValidateTokenResponse {
  bool valid = 1;
  string user_id = 2;
  string email = 3;
  Role role = 4;
  google.protobuf.Timestamp expires_at = 5;
  string reason = 6; // failure reason: TOKEN_EXPIRED, TOKEN_INVALID, etc.
}

// --- Shared types ---

// AuthTokenResponse is used for token operations that do not involve a new social login
// (e.g. RefreshToken). For GoogleLogin use GoogleLoginResponse which includes is_new_user.
message AuthTokenResponse {
  string access_token = 1;
  string refresh_token = 2;
  google.protobuf.Timestamp access_token_expires_at = 3;
  google.protobuf.Timestamp refresh_token_expires_at = 4;
  UserResponse user = 5;
}

message UserResponse {
  string user_id = 1;
  string email = 2;
  string nickname = 3;
  string profile_image_url = 4;
  Role role = 5;
  google.protobuf.Timestamp created_at = 6;
}

enum Role {
  ROLE_UNSPECIFIED = 0;
  ROLE_NORMAL = 1;   // 구글 소셜 로그인 유저
  ROLE_ADMIN = 2;    // 슈퍼 어드민 (username/password)
  ROLE_BAR = 3;      // 바/업장 관리자 (어드민이 생성)
  ROLE_REQUE = 4;    // 리케 (어드민이 생성)
}

enum Provider {
  PROVIDER_UNSPECIFIED = 0;
  PROVIDER_GOOGLE = 1;
}
```

---

## 4. 내부 구조 및 파일 목록

### gRPC 레이어

| 파일 | 역할 |
|------|------|
| `grpc/AuthGrpcService.java` | `AuthServiceGrpc.AuthServiceImplBase` 구현체, 각 RPC를 서비스 레이어로 위임 |

### 인증 / JWT

| 파일 | 역할 |
|------|------|
| `security/JwtService.java` | RS256 키 쌍으로 Access/Refresh Token 생성 및 검증 |
| `security/RsaKeyProvider.java` | PEM 문자열 -> RSAPrivateKey / RSAPublicKey 변환 |

### Google OAuth2

| 파일 | 역할 |
|------|------|
| `oauth/GoogleTokenVerifier.java` | Google ID Token 검증 (google-auth-library 사용) |
| `oauth/GoogleOAuth2UserInfo.java` | ID Token claims에서 유저 정보 추출 |

### 사용자 도메인

| 파일 | 역할 |
|------|------|
| `domain/user/entity/User.java` | 유저 엔티티 |
| `domain/user/entity/RefreshToken.java` | 리프레시 토큰 엔티티 (bcrypt 해시 저장) |
| `domain/user/UserRepository.java` | 유저 조회 (provider+provider_id, username 등) |
| `domain/user/RefreshTokenRepository.java` | 리프레시 토큰 CRUD |

### 서비스 레이어

| 파일 | 역할 |
|------|------|
| `service/GoogleLoginService.java` | ID Token 검증 -> findOrCreateUser -> 토큰 발급 |
| `service/AdminAuthService.java` | 어드민 로그인 / 관리형 계정 생성 |
| `service/TokenService.java` | 토큰 생성, 갱신, 폐기 |

### 설정

| 파일 | 역할 |
|------|------|
| `config/SecurityConfig.java` | BCryptPasswordEncoder 빈, HTTP 완전 차단 |
| `config/RedisConfig.java` | RedisTemplate 설정 |

---

## 5. gRPC 서비스 구현 골격

```java
@GrpcService
public class AuthGrpcService extends AuthServiceGrpc.AuthServiceImplBase {

    private final GoogleLoginService googleLoginService;
    private final AdminAuthService adminAuthService;
    private final TokenService tokenService;
    private final UserRepository userRepository;

    @Override
    public void googleLogin(GoogleLoginRequest req, StreamObserver<GoogleLoginResponse> obs) {
        try {
            GoogleLoginResult result = googleLoginService.login(req.getIdToken());
            obs.onNext(toProto(result));
            obs.onCompleted();
        } catch (InvalidIdTokenException e) {
            obs.onError(Status.UNAUTHENTICATED
                .withDescription("Invalid Google ID Token").asRuntimeException());
        }
    }

    @Override
    public void adminLogin(AdminLoginRequest req, StreamObserver<AuthTokenResponse> obs) {
        try {
            TokenPair pair = adminAuthService.login(req.getUsername(), req.getPassword());
            obs.onNext(toProto(pair));
            obs.onCompleted();
        } catch (AuthException e) {
            obs.onError(Status.UNAUTHENTICATED
                .withDescription(e.getMessage()).asRuntimeException());
        }
    }

    @Override
    public void adminCreateUser(AdminCreateUserRequest req, StreamObserver<AdminCreateUserResponse> obs) {
        try {
            User user = adminAuthService.createManagedUser(
                req.getUsername(), req.getPassword(), req.getRole());
            obs.onNext(AdminCreateUserResponse.newBuilder().setUser(toProto(user)).build());
            obs.onCompleted();
        } catch (DuplicateUsernameException e) {
            obs.onError(Status.ALREADY_EXISTS
                .withDescription("Username already exists").asRuntimeException());
        } catch (InvalidRoleException e) {
            obs.onError(Status.INVALID_ARGUMENT
                .withDescription("Role must be ROLE_BAR or ROLE_REQUE").asRuntimeException());
        }
    }

    @Override
    public void refreshToken(RefreshTokenRequest req, StreamObserver<AuthTokenResponse> obs) {
        try {
            TokenPair pair = tokenService.refresh(req.getRefreshToken());
            obs.onNext(toProto(pair));
            obs.onCompleted();
        } catch (InvalidRefreshTokenException e) {
            obs.onError(Status.UNAUTHENTICATED
                .withDescription(e.getMessage()).asRuntimeException());
        }
    }

    @Override
    public void validateToken(ValidateTokenRequest req, StreamObserver<ValidateTokenResponse> obs) {
        // 예외를 던지지 않고 valid=false + reason으로 반환
        ValidateTokenResponse response = tokenService.validate(req.getAccessToken());
        obs.onNext(response);
        obs.onCompleted();
    }

    @Override
    public void logout(LogoutRequest req, StreamObserver<LogoutResponse> obs) {
        tokenService.revokeAll(req.getUserId());
        obs.onNext(LogoutResponse.getDefaultInstance());
        obs.onCompleted();
    }

    @Override
    public void getMe(GetMeRequest req, StreamObserver<UserResponse> obs) {
        User user = userRepository.findById(req.getUserId())
            .orElseThrow(() -> Status.NOT_FOUND.asRuntimeException());
        obs.onNext(toProto(user));
        obs.onCompleted();
    }
}
```

### SecurityConfig (HTTP 완전 차단)

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(AbstractHttpConfigurer::disable)
            .sessionManagement(s -> s.sessionCreationPolicy(STATELESS))
            .formLogin(AbstractHttpConfigurer::disable)
            .httpBasic(AbstractHttpConfigurer::disable)
            .authorizeHttpRequests(auth -> auth.anyRequest().denyAll());
        return http.build();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
}
```

---

## 6. Google 소셜 로그인 내부 로직

```
gRPC GoogleLogin RPC 수신 (id_token)
  └─ GoogleLoginService.login(idToken)
       ├─ GoogleTokenVerifier.verify(idToken)
       │    ├─ GoogleIdTokenVerifier로 Google 공개키 기반 서명 검증
       │    ├─ aud(client_id) 일치 확인
       │    └─ 실패 -> InvalidIdTokenException -> UNAUTHENTICATED
       ├─ claims에서 추출: sub(provider_id), email, name, picture
       ├─ userRepository.findByProviderAndProviderId(GOOGLE, sub)
       │    ├─ 존재 -> 기존 유저 로드 (isNewUser = false)
       │    └─ 없음 -> User 신규 생성 (isNewUser = true)
       │         ├─ role = ROLE_NORMAL
       │         ├─ provider = PROVIDER_GOOGLE
       │         ├─ provider_id = Google sub
       │         ├─ email, nickname = Google 이름, profile_image_url
       │         └─ hashed_password = null (소셜 전용 계정)
       ├─ TokenService.generatePair(user)
       │    ├─ createAccessToken()  -> RS256 서명, 만료 30분
       │    └─ createRefreshToken() -> RS256 서명, 만료 7일
       ├─ TokenService.saveRefreshToken(userId, rawRefreshToken)
       │    ├─ BCrypt.hash(rawToken) -> PostgreSQL 저장
       │    └─ Redis: refresh:{userId} -> 해시값 (TTL: 7일)
       └─ GoogleLoginResponse 반환 (is_new_user 포함)
```

---

## 7. 어드민 로그인 내부 로직

```
gRPC AdminLogin RPC 수신 (username, password)
  └─ AdminAuthService.login(username, password)
       ├─ userRepository.findByUsername(username)
       │    └─ 없으면 -> UNAUTHENTICATED
       ├─ user.getRole()이 ROLE_ADMIN / ROLE_BAR / ROLE_REQUE인지 확인
       │    └─ ROLE_NORMAL이면 -> UNAUTHENTICATED (소셜 전용 계정)
       ├─ passwordEncoder.matches(password, user.getHashedPassword())
       │    └─ 불일치 -> UNAUTHENTICATED
       ├─ TokenService.generatePair(user)
       └─ TokenService.saveRefreshToken(userId, rawRefreshToken)
       └─ AuthTokenResponse 반환
```

---

## 8. 관리형 계정 생성 (ROLE_BAR / ROLE_REQUE)

> Gateway가 JWT claims에서 role=ROLE_ADMIN을 확인한 후 이 RPC를 호출합니다.
> 생성된 ROLE_BAR / ROLE_REQUE 계정은 이후 AdminLogin RPC로 로그인합니다.

```
gRPC AdminCreateUser RPC 수신 (username, password, role)
  └─ AdminAuthService.createManagedUser(username, password, role)
       ├─ role이 ROLE_BAR 또는 ROLE_REQUE인지 검증
       │    └─ 그 외 -> InvalidRoleException -> INVALID_ARGUMENT
       ├─ userRepository.existsByUsername(username)
       │    └─ 중복 -> DuplicateUsernameException -> ALREADY_EXISTS
       ├─ User 생성
       │    ├─ username = 입력값
       │    ├─ hashed_password = BCrypt.hash(password)
       │    ├─ role = 입력 role (ROLE_BAR 또는 ROLE_REQUE)
       │    └─ provider = null (소셜 계정 아님)
       ├─ userRepository.save(user)
       └─ AdminCreateUserResponse(UserResponse) 반환
```

### Role 별 계정 생성 경로 요약

| Role | 생성 방식 | 로그인 방식 |
|------|---------|-----------|
| ROLE_NORMAL | GoogleLogin 첫 호출 시 자동 생성 | GoogleLogin RPC |
| ROLE_ADMIN | 운영팀 직접 DB 시딩 / 초기화 스크립트 | AdminLogin RPC |
| ROLE_BAR | ROLE_ADMIN이 AdminCreateUser 호출 | AdminLogin RPC |
| ROLE_REQUE | ROLE_ADMIN이 AdminCreateUser 호출 | AdminLogin RPC |

---

## 9. JWT 토큰 로직 (RS256)

### 키 관리

| 키 | 보유자 | 용도 |
|----|--------|------|
| Private Key (PEM) | auth-service 전용 | Access/Refresh Token 서명 |
| Public Key (PEM) | auth-service, Gateway, 타 서비스 모두 | 서명 검증 |

### JWT Payload 구조

```json
{
  "sub":   "<user_id>",
  "email": "<email>",
  "role":  "ROLE_NORMAL",
  "type":  "ACCESS",
  "jti":   "<UUID>",
  "iat":   1234567890,
  "exp":   1234567890
}
```

`type` 필드로 Access / Refresh 토큰을 구분합니다. Refresh Token을 Access Token 자리에 사용하는 것을 서비스 레이어에서 차단합니다.

### 주요 메서드 (JwtService.java)

| 메서드 | 설명 |
|--------|------|
| `createAccessToken(User)` | RS256 서명, 만료 30분, type=ACCESS |
| `createRefreshToken(User)` | RS256 서명, 만료 7일, type=REFRESH |
| `parseClaims(token)` | 서명 검증 + claims 추출 (예외: ExpiredJwtException, JwtException) |
| `validate(token)` | valid/reason 포함 ValidateTokenResponse 반환 |

### 리프레시 토큰 저장 규칙

- DB(`refresh_tokens` 테이블): `BCrypt.hash(rawToken)` 저장 (평문 절대 금지)
- Redis `refresh:{userId}` -> 해시값 (TTL = 리프레시 만료와 동일)
- 토큰 갱신 시: 기존 토큰 폐기 후 신규 토큰 저장 (rotation)

---

## 10. 토큰 갱신 흐름

```
gRPC RefreshToken RPC 수신 (refresh_token)
  └─ TokenService.refresh(rawRefreshToken)
       ├─ JwtService.parseClaims(rawRefreshToken)
       │    ├─ 만료 -> UNAUTHENTICATED (reason: TOKEN_EXPIRED)
       │    └─ 서명 오류 -> UNAUTHENTICATED (reason: TOKEN_INVALID)
       ├─ claims.type == "REFRESH" 확인
       │    └─ ACCESS이면 -> UNAUTHENTICATED
       ├─ Redis에서 refresh:{userId} 해시 조회
       │    └─ 없음 -> UNAUTHENTICATED (이미 폐기된 토큰)
       ├─ BCrypt.matches(rawToken, storedHash) 확인
       │    └─ 불일치 -> UNAUTHENTICATED (탈취 의심)
       ├─ 기존 리프레시 토큰 폐기 (DB + Redis)
       ├─ TokenService.generatePair(user)
       └─ TokenService.saveRefreshToken() -> 신규 토큰 저장
       └─ AuthTokenResponse 반환
```

---

## 11. 토큰 검증 흐름 (Zero Trust)

### Gateway 1차 검증

```
클라이언트 요청 (Authorization: Bearer <access_token>)
  └─ Gateway JWT 필터
       ├─ Public Key로 서명 검증
       ├─ 만료 확인
       ├─ 실패 -> 401 반환 (auth-service 미호출)
       └─ 성공 -> X-User-Id, X-User-Role 헤더 주입 후 대상 서비스로 전달
```

### 각 서비스 2차 검증 (Zero Trust)

```java
// gRPC Interceptor 또는 서비스 레이어 진입 시
ValidateTokenResponse res = authStub.validateToken(
    ValidateTokenRequest.newBuilder().setAccessToken(token).build()
);
if (!res.getValid()) {
    throw new UnauthorizedException(res.getReason());
}
// res.getUserId(), res.getRole() 사용
```

타 서비스 gRPC 클라이언트 설정:

```yaml
grpc:
  client:
    auth-service:
      address: static://auth-service:9090
      negotiation-type: plaintext
```

---

## 12. 유저 엔티티 및 권한

### User 엔티티 주요 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `user_id` | UUID | PK |
| `username` | VARCHAR | 어드민/BAR/REQUE 로그인 아이디 (ROLE_NORMAL은 null) |
| `hashed_password` | VARCHAR | BCrypt 해시 (ROLE_NORMAL은 null) |
| `provider` | ENUM | PROVIDER_GOOGLE / null |
| `provider_id` | VARCHAR | Google sub (소셜 유저 고유 식별자) |
| `email` | VARCHAR | 이메일 |
| `nickname` | VARCHAR | 닉네임 |
| `profile_image_url` | VARCHAR | 프로필 이미지 |
| `role` | ENUM | ROLE_NORMAL / ROLE_ADMIN / ROLE_BAR / ROLE_REQUE |
| `created_at` | TIMESTAMP | 생성일 |

### Role 별 로그인 방식 정리

| Role | 로그인 RPC | 계정 생성 방식 |
|------|-----------|--------------|
| ROLE_NORMAL | GoogleLogin | 첫 소셜 로그인 시 자동 생성 |
| ROLE_ADMIN | AdminLogin | 운영팀 직접 DB 시딩 |
| ROLE_BAR | AdminLogin | ROLE_ADMIN이 AdminCreateUser로 생성 |
| ROLE_REQUE | AdminLogin | ROLE_ADMIN이 AdminCreateUser로 생성 |

---

## 13. 환경 설정

### 토큰 만료 설정

| 항목 | 운영 | 개발 |
|------|------|------|
| Access Token | 30분 | 1440분 (1일) |
| Refresh Token | 10080분 (7일) | 10080분 (7일) |

### 주요 환경변수

| 변수 | 설명 |
|------|------|
| `JWT_PRIVATE_KEY` | RS256 PEM 개인키 (auth-service 전용, 절대 외부 노출 금지) |
| `JWT_PUBLIC_KEY` | RS256 PEM 공개키 (Gateway, 타 서비스에도 동일 값 배포) |
| `GOOGLE_CLIENT_ID` | Google OAuth2 클라이언트 ID (ID Token aud 검증에 사용) |
| `DB_HOST` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` | PostgreSQL 접속 정보 |
| `REDIS_HOST` | Redis 호스트 |
| `ADMIN_INITIAL_USERNAME` | 초기 ROLE_ADMIN 계정 아이디 |
| `ADMIN_INITIAL_PASSWORD` | 초기 ROLE_ADMIN 비밀번호 (BCrypt 해싱 후 저장) |

> JWT Private Key는 절대 application.yml에 하드코딩하지 마세요. GCP Secret Manager 또는 환경변수로만 주입하세요.

> Refresh Token은 평문을 DB에 저장하지 않습니다. BCrypt 해시만 저장합니다.
