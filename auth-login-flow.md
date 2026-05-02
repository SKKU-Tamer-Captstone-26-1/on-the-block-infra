# 인증 서비스 로그인 플로우 구현 가이드

> auth-service 개발자를 위한 문서입니다.
> 전체 아키텍처는 `auth-login-jwt-architecture.md`를 참고하세요.
> Proto 정의 원본: `proto/auth/v1/auth.proto`

---

## 목차

1. [로그인 플로우 개요](#1-로그인-플로우-개요)
2. [Google 소셜 로그인](#2-google-소셜-로그인)
3. [어드민 로그인](#3-어드민-로그인)
4. [관리형 계정 생성 (ROLE_BAR / ROLE_REQUE)](#4-관리형-계정-생성-role_bar--role_reque)
5. [토큰 갱신](#5-토큰-갱신)
6. [로그아웃](#6-로그아웃)
7. [구현 체크리스트](#7-구현-체크리스트)

---

## 1. 로그인 플로우 개요

### 로그인 유형별 RPC 및 엔드포인트

| 로그인 유형 | gRPC RPC | Gateway HTTP | JWT 필요 | 응답 타입 |
|-----------|----------|-------------|---------|---------|
| Google 소셜 | GoogleLogin | POST /auth/google | 불필요 | GoogleLoginResponse |
| 어드민/BAR/REQUE | AdminLogin | POST /auth/admin | 불필요 | AuthTokenResponse |
| 관리형 계정 생성 | AdminCreateUser | POST /auth/admin/users | 필요 (ROLE_ADMIN) | AdminCreateUserResponse |
| 토큰 갱신 | RefreshToken | POST /auth/refresh | 불필요 | AuthTokenResponse |
| 로그아웃 | Logout | POST /auth/logout | 필요 | LogoutResponse |

### 계정 유형별 흐름 요약

```
ROLE_NORMAL  -> Google 앱에서 ID Token 수신 -> GoogleLogin RPC
                                                 -> 신규면 DB에 유저 생성 후 JWT 발급
                                                 -> 기존이면 바로 JWT 발급

ROLE_ADMIN   -> 운영팀이 DB에 직접 시딩
                -> AdminLogin RPC (username/password) -> JWT 발급

ROLE_BAR     -> ROLE_ADMIN이 AdminCreateUser RPC로 계정 생성
ROLE_REQUE      -> 이후 AdminLogin RPC (username/password) -> JWT 발급
```

---

## 2. Google 소셜 로그인

### 관련 Proto

```protobuf
rpc GoogleLogin(GoogleLoginRequest) returns (GoogleLoginResponse);

message GoogleLoginRequest {
  string id_token = 1; // 클라이언트 Google SDK에서 받은 ID Token
}

message GoogleLoginResponse {
  string access_token = 1;
  string refresh_token = 2;
  google.protobuf.Timestamp access_token_expires_at = 3;
  google.protobuf.Timestamp refresh_token_expires_at = 4;
  UserResponse user = 5;
  bool is_new_user = 6; // 이 로그인으로 유저가 처음 생성된 경우 true
}
```

### 처리 흐름

```
1. 클라이언트 -> POST /auth/google  { "id_token": "<Google ID Token>" }
2. Gateway -> gRPC GoogleLogin(id_token)
3. GoogleTokenVerifier.verify(idToken)
   - Google 공개키로 서명 검증
   - aud == GOOGLE_CLIENT_ID 확인
   - 실패 -> gRPC UNAUTHENTICATED
4. claims에서 sub(provider_id), email, name, picture 추출
5. userRepository.findByProviderAndProviderId(GOOGLE, sub)
   - 존재: 기존 유저 로드 (isNewUser = false)
   - 없음: User 신규 생성 후 저장 (isNewUser = true)
       role = ROLE_NORMAL
       provider = PROVIDER_GOOGLE
       provider_id = sub
       hashed_password = null
6. generateTokenPair(user)
   - accessToken:  RS256, exp = now + 30분
   - refreshToken: RS256, exp = now + 7일
7. saveRefreshToken(userId, rawRefreshToken)
   - DB: BCrypt.hash(rawToken) 저장
   - Redis: refresh:{userId} = hash (TTL 7일)
8. GoogleLoginResponse 반환
```

### 구현 핵심 포인트

- `GoogleIdTokenVerifier`는 Google 공개키를 캐시합니다. 매 요청마다 네트워크를 호출하지 않습니다.
- `sub` 값이 Google 계정의 영구 식별자입니다. `email`은 변경될 수 있으므로 PK로 사용하지 마세요.
- `is_new_user = true`이면 클라이언트에서 온보딩 화면을 표시할 수 있습니다.

```java
// GoogleTokenVerifier.java 구현 예시
GoogleIdTokenVerifier verifier = new GoogleIdTokenVerifier.Builder(
        new NetHttpTransport(), GsonFactory.getDefaultInstance())
    .setAudience(Collections.singletonList(googleClientId))
    .build();

GoogleIdToken idToken = verifier.verify(rawIdToken);
if (idToken == null) throw new InvalidIdTokenException();

Payload payload = idToken.getPayload();
String providerId = payload.getSubject();
String email      = payload.getEmail();
String name       = (String) payload.get("name");
String picture    = (String) payload.get("picture");
```

### 오류 응답

| 원인 | gRPC Status | reason |
|------|------------|--------|
| ID Token 서명 불일치 | UNAUTHENTICATED | - |
| ID Token 만료 | UNAUTHENTICATED | - |
| aud 불일치 | UNAUTHENTICATED | - |

---

## 3. 어드민 로그인

### 관련 Proto

```protobuf
rpc AdminLogin(AdminLoginRequest) returns (AuthTokenResponse);

message AdminLoginRequest {
  string username = 1;
  string password = 2;
}

// AuthTokenResponse (GoogleLoginResponse에서 is_new_user 제외한 공용 타입)
message AuthTokenResponse {
  string access_token = 1;
  string refresh_token = 2;
  google.protobuf.Timestamp access_token_expires_at = 3;
  google.protobuf.Timestamp refresh_token_expires_at = 4;
  UserResponse user = 5;
}
```

### 처리 흐름

```
1. 클라이언트 -> POST /auth/admin  { "username": "...", "password": "..." }
2. Gateway -> gRPC AdminLogin(username, password)
3. userRepository.findByUsername(username)
   - 없으면 -> UNAUTHENTICATED
4. user.role 확인
   - ROLE_NORMAL이면 -> UNAUTHENTICATED (소셜 전용 계정)
   - ROLE_ADMIN / ROLE_BAR / ROLE_REQUE 만 통과
5. BCrypt.matches(password, user.hashedPassword)
   - 불일치 -> UNAUTHENTICATED
6. generateTokenPair(user) + saveRefreshToken()
7. AuthTokenResponse 반환
```

### 구현 핵심 포인트

- username 미존재와 비밀번호 불일치를 **동일한 오류 메시지**로 응답합니다. (계정 존재 여부 노출 방지)
- ROLE_BAR, ROLE_REQUE도 이 RPC로 로그인합니다. 별도 RPC가 없습니다.

### 초기 ROLE_ADMIN 계정 생성

운영 배포 전 DB에 직접 시딩하거나 초기화 스크립트로 생성합니다.

```sql
INSERT INTO auth.users (user_id, username, hashed_password, role)
VALUES (gen_random_uuid(), 'admin', '<BCrypt hash>', 'ROLE_ADMIN');
```

또는 `ApplicationRunner`로 환경변수 기반 자동 생성:

```java
@Component
public class AdminInitializer implements ApplicationRunner {
    @Override
    public void run(ApplicationArguments args) {
        String username = env.getProperty("ADMIN_INITIAL_USERNAME");
        String password = env.getProperty("ADMIN_INITIAL_PASSWORD");
        if (!userRepository.existsByUsername(username)) {
            userRepository.save(User.ofAdmin(username, passwordEncoder.encode(password)));
        }
    }
}
```

### 오류 응답

| 원인 | gRPC Status |
|------|------------|
| username 없음 또는 비밀번호 불일치 | UNAUTHENTICATED |
| ROLE_NORMAL 계정으로 시도 | UNAUTHENTICATED |

---

## 4. 관리형 계정 생성 (ROLE_BAR / ROLE_REQUE)

### 관련 Proto

```protobuf
rpc AdminCreateUser(AdminCreateUserRequest) returns (AdminCreateUserResponse);

message AdminCreateUserRequest {
  string username = 1;
  string password = 2;
  Role role = 3; // ROLE_BAR 또는 ROLE_REQUE만 허용
}

message AdminCreateUserResponse {
  UserResponse user = 1;
}

enum Role {
  ROLE_UNSPECIFIED = 0;
  ROLE_NORMAL = 1;
  ROLE_ADMIN  = 2;
  ROLE_BAR    = 3;
  ROLE_REQUE  = 4;
}
```

### 처리 흐름

```
1. ROLE_ADMIN 계정으로 로그인된 클라이언트
   -> POST /auth/admin/users  { "username": "bar_owner_1", "password": "...", "role": "ROLE_BAR" }
2. Gateway JWT 필터: role == ROLE_ADMIN 확인 후 gRPC 전달
3. gRPC AdminCreateUser(username, password, role)
4. role 검증
   - ROLE_BAR 또는 ROLE_REQUE만 허용
   - 그 외 -> INVALID_ARGUMENT
5. userRepository.existsByUsername(username)
   - 중복 -> ALREADY_EXISTS
6. User 생성
   - hashed_password = BCrypt.hash(password)
   - role = 입력 role
   - provider = null (소셜 계정 아님)
7. userRepository.save(user)
8. AdminCreateUserResponse(UserResponse) 반환
```

### 구현 핵심 포인트

- ROLE_ADMIN 권한 확인은 Gateway가 JWT claims를 보고 처리합니다. auth-service에서 재검증할 경우 호출자의 userId를 통해 DB role을 확인합니다.
- 생성된 계정의 초기 비밀번호는 관리자가 안전한 채널로 전달합니다.
- 비밀번호 변경 기능은 별도 RPC로 추후 추가합니다.

### 오류 응답

| 원인 | gRPC Status |
|------|------------|
| role이 ROLE_BAR / ROLE_REQUE 아님 | INVALID_ARGUMENT |
| username 중복 | ALREADY_EXISTS |
| 호출자가 ROLE_ADMIN 아님 | PERMISSION_DENIED |

---

## 5. 토큰 갱신

### 관련 Proto

```protobuf
rpc RefreshToken(RefreshTokenRequest) returns (AuthTokenResponse);

message RefreshTokenRequest {
  string refresh_token = 1;
}
```

### 처리 흐름

```
1. 클라이언트 -> POST /auth/refresh  { "refresh_token": "<RT>" }
2. Gateway -> gRPC RefreshToken(refresh_token)
3. JwtService.parseClaims(rawRefreshToken)
   - 만료 -> UNAUTHENTICATED (reason: TOKEN_EXPIRED)
   - 서명 오류 -> UNAUTHENTICATED (reason: TOKEN_INVALID)
4. claims.type == "REFRESH" 확인
   - ACCESS이면 -> UNAUTHENTICATED
5. Redis에서 refresh:{userId} 해시 조회
   - 없음 -> UNAUTHENTICATED (로그아웃된 토큰)
6. BCrypt.matches(rawToken, storedHash)
   - 불일치 -> UNAUTHENTICATED (탈취 의심, 전체 세션 폐기 고려)
7. 기존 토큰 폐기 (DB + Redis)
8. generateTokenPair(user) + saveRefreshToken()
9. AuthTokenResponse 반환 (새 토큰 쌍)
```

### 구현 핵심 포인트

- 리프레시 토큰은 1회 사용 후 즉시 폐기합니다 (rotation). 재사용 시도는 탈취로 간주할 수 있습니다.
- BCrypt 불일치가 발생하면 해당 userId의 모든 리프레시 토큰을 폐기하고 재로그인을 요구하는 것을 검토하세요.
- Access Token 만료 전에 갱신을 시도하더라도 정상 처리합니다.

---

## 6. 로그아웃

### 관련 Proto

```protobuf
rpc Logout(LogoutRequest) returns (LogoutResponse);

message LogoutRequest  { string user_id = 1; }
message LogoutResponse {}
```

### 처리 흐름

```
1. 클라이언트 -> POST /auth/logout (Authorization: Bearer <AT>)
2. Gateway JWT 필터: 서명 검증 + user_id 추출 후 헤더 주입
3. gRPC Logout(user_id)
4. refreshTokenRepository.deleteAllByUserId(userId)
5. Redis: DEL refresh:{userId}
6. LogoutResponse 반환
```

### 구현 핵심 포인트

- Access Token은 서버에서 즉시 무효화할 수 없습니다 (Stateless). 만료까지 유효합니다.
- Refresh Token 폐기만으로 사실상 세션을 종료합니다.
- Access Token 블랙리스트가 필요하면 Redis에 `blacklist:{jti}` 키로 만료 시각까지 저장합니다.

---

## 7. 구현 체크리스트

### Google 소셜 로그인

- [ ] `GoogleIdTokenVerifier` 빈 등록 (`GOOGLE_CLIENT_ID` 환경변수 주입)
- [ ] `verifyGoogleIdToken()` - 서명 + aud 검증
- [ ] `findOrCreateUser()` - provider + provider_id 기반 조회/생성
- [ ] `generateTokenPair()` - RS256 accessToken (30분) + refreshToken (7일)
- [ ] `saveRefreshToken()` - BCrypt 해시 DB 저장 + Redis TTL 설정
- [ ] `GoogleLoginResponse` 빌더 (is_new_user 포함)

### 어드민 로그인

- [ ] `findByUsername()` 조회
- [ ] role이 ROLE_NORMAL이면 거부
- [ ] `BCrypt.matches()` 비밀번호 검증
- [ ] 초기 ROLE_ADMIN 계정 자동 생성 로직 (ApplicationRunner)

### 관리형 계정 생성

- [ ] role == ROLE_BAR || ROLE_REQUE 검증
- [ ] username 중복 확인
- [ ] `BCrypt.hash(password)` 저장
- [ ] 호출자 ROLE_ADMIN 검증 (Gateway 또는 서비스 레이어)

### 토큰 / 공통

- [ ] RS256 키 쌍 생성 및 PEM 환경변수 주입
- [ ] `JwtService` - createAccessToken / createRefreshToken / parseClaims / validate
- [ ] `RsaKeyProvider` - PEM -> RSAPrivateKey / RSAPublicKey 변환
- [ ] `RefreshToken` 엔티티 및 Repository
- [ ] Redis `refresh:{userId}` TTL 설정
- [ ] 토큰 갱신 rotation 구현
- [ ] 로그아웃 시 DB + Redis 동시 폐기
- [ ] `ValidateToken` RPC - valid=false + reason 반환 (예외 미사용)
- [ ] SecurityConfig - HTTP 완전 차단


### proto 수정사항
AdminLoginRequest 삭제
AuthTokenResponse 삭제
AdminLogin RPC 삭제
RefreshToken 응답 타입 변경 (AuthTokenResponse → RefreshTokenResponse)
GetMe 응답 타입 변경 (UserResponse → GetMeResponse)