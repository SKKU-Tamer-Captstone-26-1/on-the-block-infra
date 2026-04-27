# CLAUDE.md — On the Block Infra

This file provides guidance for Claude Code when working in the `on-the-block-infra` repository.

## Project Overview

"On the Block" is a whiskey and cocktail community platform. Sungkyunkwan University Capstone Design Team 9, a 3-person team, targeting completion in 2-3 months.

## Role of This Repository

The infra repo manages all infrastructure and shared resources outside of service code:
- `proto/` — gRPC proto files (single source of truth referenced by all services)
- `docker-compose/` — local development environment (infra + other service containers)
- `scripts/` — utility scripts such as proto sync
- `docs/` — GCP configuration records, architecture documentation
- `k8s/` — K8s manifest files (future)

## Architecture

MSA structure, inter-service communication via gRPC. Kafka was removed due to ROI concerns relative to team size and timeline.
GCP infrastructure is provisioned via Console with configuration documented in the `docs/` directory.

### Services

| Service | Language | Role | DB | Repo |
|---------|----------|------|----|------|
| Auth (Identity & Commerce) | Java / Spring Boot | Authentication, JWT, payments | PostgreSQL + Redis | ontheblock-auth |
| Community (Real-time) | Go / gRPC | Chat, flash meetups, short-form content | DynamoDB | ontheblock-community |
| Recommend (Intelligent) | Python / FastAPI | Vector search, taste recommendations | Qdrant + PostgreSQL | ontheblock-recommend |
| Frontend | React | Web client | — | ontheblock-web |
| Gateway | Java / Spring Cloud Gateway | Routing, JWT first-pass validation | — | ontheblock-gateway |

### Communication

- External to internal: REST & gRPC (Flutter/React -> Gateway) -> gRPC (Gateway -> Service)
- Service to service: direct gRPC calls
- JWT: RS256 asymmetric keys. Gateway performs first-pass validation (signature + expiry), each service performs second-pass validation (Zero Trust)

## Local Development Environment (Container Registry Approach)

### Principle

When main branch is pushed in each service repo, GitHub Actions automatically builds a Docker image and pushes it to ghcr.io. During local development, run only your own service directly and spin up the rest as containers pulled from ghcr.io.

### Image Naming

```
ghcr.io/ontheblock/auth:latest
ghcr.io/ontheblock/community:latest
ghcr.io/ontheblock/recommend:latest
ghcr.io/ontheblock/gateway:latest
ghcr.io/ontheblock/web:latest
```

### Development Workflow (e.g., when developing Community)

```bash
cd ontheblock-infra/docker-compose

# Pull latest images + start infra/other service containers
docker-compose -f docker-compose.local.yml pull
docker-compose -f docker-compose.local.yml up -d postgres redis dynamodb qdrant auth gateway recommend

# Run only your own service locally
cd ../ontheblock-community
go run main.go
```

### docker-compose.local.yml Structure

Infrastructure (run directly):
- PostgreSQL (5432) — separate schemas for auth, community, recommend
- Redis (6379) — session/cache
- DynamoDB Local (8000) — chat data
- Qdrant (6333/6334) — vector search

Services (pulled from ghcr.io):
- auth, community, recommend, gateway — each references a ghcr.io image
- Environment variables injected via `environment` block or `.env` file in docker-compose

### Required Files in Each Service Repo

Every service repo root must contain:
- `Dockerfile` — multi-stage build recommended
- `.github/workflows/build-and-push.yml` — auto-push image to ghcr.io on main push

### GitHub Actions Workflow (placed in each service repo)

Trigger: push to main branch
Steps: checkout -> Docker build -> ghcr.io login -> push
Tags: `latest` + git SHA (`:latest`, `:abc1234`)

### Dockerfile Guide (by language)

Java (Spring Boot):
- Build: `gradle bootJar` or `mvn package`
- Runtime: `eclipse-temurin:21-jre-alpine`
- Separate build/runtime stages with multi-stage build

Go:
- Build: `CGO_ENABLED=0 go build -o server .`
- Runtime: `scratch` or `distroless`
- Image size in the single-digit MB range

Python (FastAPI):
- Runtime: `python:3.12-slim`
- Manage dependencies with `requirements.txt` or `poetry`

## Using buf

Proto file management uses the buf CLI. `buf.yaml` is located inside the `proto/` directory.

### Installation

```bash
# macOS
brew install bufbuild/buf/buf

# Windows (Scoop)
scoop install buf

# Windows (direct download)
# Download buf-Windows-x86_64.exe from https://github.com/bufbuild/buf/releases and add to PATH
```

### Key Commands

Lint check (run from the `proto/` directory):

```bash
cd proto
buf lint
```

Breaking change check (against main branch):

```bash
cd proto
buf breaking --against '.git#branch=main,subdir=proto'
```

Format proto files:

```bash
cd proto
buf format -w
```

### buf.yaml Configuration

Summary of `proto/buf.yaml` settings:
- `version: v2`
- `modules[0].name: buf.build/ontheblock/infra` — BSR module name
- `lint.use: STANDARD` — apply standard lint ruleset
- `lint.except: PACKAGE_DIRECTORY_NAME` — excluded because directory structure is `{service}/v1/`
- `breaking.use: FILE` — file-level backward compatibility check

### Proto Modification Procedure

1. Review existing contracts in the `proto/` directory
2. Modify the `.proto` file
3. `buf lint` — verify no lint errors
4. `buf breaking --against '.git#branch=main,subdir=proto'` — verify no breaking changes
5. If a breaking change is unavoidable, proceed only after full team consensus
6. Commit each file individually

## Proto Conventions

- Package: `ontheblock.{service}.v1`
- Directory: `proto/{service}/v1/{service}.proto`
- Common types: `proto/common/v1/common.proto`
- Java package: `com.ontheblock.{service}.v1`
- Go package: `github.com/ontheblock/infra/proto/{service}/v1;{service}v1`
- Versioning: directory level (`v1/`, `v2/`)
- First enum value must always be `_UNSPECIFIED = 0`
- Field names in snake_case, message names in PascalCase
- Proto schema changes require full team consensus before proceeding
- Always review the `proto/` directory and understand existing contracts before modifying any `.proto` file

## Auth Service API Design

Gateway bypass (called without JWT):
- `POST /auth/google` — Google ID Token -> verify -> find or create user -> issue app JWT
- `POST /auth/refresh` — Refresh token -> issue new token pair (with rotation)

Requires Gateway JWT filter:
- `GET /auth/me` — current user info
- `POST /auth/logout` — revoke all refresh tokens

Internal gRPC only:
- `ValidateToken` — called by other services to validate JWT (Zero Trust)

Internal methods:
- `verifyGoogleIdToken()` — verify ID Token using Google public keys
- `findOrCreateUser()` — look up by provider_id, create if not found (= auto registration)
- `generateTokenPair()` — generate access (15-30 min) + refresh (7-14 days) pair
- `saveRefreshToken()` — store only the bcrypt hash in DB
- `validateRefreshToken()` — hash comparison + expiry + revoked check
- `revokeOldRefreshToken()` / `revokeAllRefreshTokens()`

## DB Design Principles

- Independent schema per service (auth, community, recommend)
- Direct DB access between services is strictly forbidden; always communicate via gRPC
- Refresh tokens must never be stored as plaintext; only bcrypt hashes in DB
- Schemas are auto-created via init-db.sql

## Key Architecture Decision Records

- Kafka removed -> switched to gRPC: Operating Kafka with a 3-person team over 2-3 months was too costly. Decided on synchronous gRPC communication.
- Terraform not used: Learning cost too high relative to team size. Chose GCP Console provisioning with configuration documentation.
- Container registry approach: Instead of local builds, pull latest images from ghcr.io. GitHub Actions auto-builds and pushes on each service's main push.

## Universal Constraints

- Plain Text Only: Never use emojis, checkmarks, X marks, flags, or other visual symbols in terminal responses, commit messages, or generated markdown files.
- Contract-First: Always review `proto/` before writing any inter-service logic.
- Minimize log output: Write complex analysis results as markdown reports rather than dumping large output to the terminal.

## Git Commit Rules

Commit each file individually. Do not bundle multiple file changes into a single commit.

```
git add proto/auth/v1/auth.proto   # commit 1: proto change
git add docker-compose/docker-compose.local.yml  # commit 2: compose change
```
