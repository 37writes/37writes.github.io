---
title: "Docker 운영 입문: 로그 확인, 안전한 업데이트, 데이터 지키기, 느릴 때 찾는 법"
date: 2026-11-18 19:25:00 +0900
categories: [개발 도구, Docker]
tags: [docker, windows, docker-compose, troubleshooting, backup, open-webui, ollama]
description: "Windows의 Docker Desktop에서 Open WebUI를 운영하며 쓰는 로그·상태 명령, down과 down -v의 차이, 업데이트와 볼륨 백업·복원, 포트 충돌과 unhealthy, 응답 지연을 찾는 순서를 임시 자원으로 검증한 결과와 함께 정리합니다."
---

> **시리즈: Windows에서 Docker 처음 배우기**
> 1. Docker란 무엇인가: 이미지와 컨테이너 (예정)
> 2. Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop (예정)
> 3. 무엇이 어느 폴더에 생기나: 이미지·컨테이너·볼륨의 실제 위치 (예정)
> 4. docker-compose.yml 한 줄씩 읽기: Open WebUI 띄우기 (예정)
> 5. 컨테이너에서 Windows의 Ollama 연결하기: localhost와 host.docker.internal (예정)
> 6. **Docker 운영과 문제 해결: 로그, 업데이트, 데이터 지키기** ← 지금 글

컨테이너를 한 번 띄우는 것과 계속 쓰는 것은 다른 일입니다. 며칠 지나면 이런 순간이 옵니다.

- 화면이 안 열리는데 어디부터 봐야 할지 모르겠습니다.
- 인터넷에서 찾은 정리 명령을 실행해도 대화 기록이 안전한지 확신이 없습니다.
- 새 버전으로 올리고 싶은데 데이터가 사라질까 걱정됩니다.
- 분명 GPU는 충분한데 답변이 한참 뒤에 나옵니다.

이 글은 Windows에서 도는 Ollama와 Docker 컨테이너로 띄운 Open WebUI를 예제로, 이 네 가지에 답합니다. 앞 편을 읽지 않아도 따라올 수 있게 썼습니다.

삭제·업데이트·백업 명령은 운영 중인 컨테이너가 아니라 **이름이 다른 임시 컨테이너와 임시 볼륨**에서 직접 실행해 결과를 확인했습니다. 확인 환경은 Docker 29.9.3, Compose 5.7.0입니다. PC 전체를 대상으로 하는 `prune` 계열과 실제 재부팅은 실행하지 않았고, 이 부분은 공식 문서 기준으로 적었습니다.

## 예제 환경

명령은 모두 Windows PowerShell에서 실행합니다. compose 파일은 `D:\Dev\server\docker-compose.yml`에 있고, 내용은 다음과 같습니다.

```yaml
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "127.0.0.1:3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
      - DEFAULT_MODELS=gemma4:12b-it-qat
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - webui-data:/app/backend/data
    restart: unless-stopped

volumes:
  webui-data:
```

운영할 때 기억할 이름은 세 가지입니다.

| 이름 | 값 | 뜻 |
|---|---|---|
| 서비스·컨테이너 | `open-webui` | 이 예제는 둘의 이름이 같습니다 |
| 볼륨 | `server_webui-data` | Docker가 관리하는 데이터 저장 공간. 폴더 이름 `server`가 앞에 붙었습니다 |
| 컨테이너 안 데이터 위치 | `/app/backend/data` | 계정, 대화, 업로드 파일이 있는 곳 |

**컨테이너**는 지웠다가 이미지로 다시 만들 수 있는 실행 단위이고, **볼륨**은 컨테이너가 사라져도 남는 데이터 공간입니다. 운영에서 지켜야 할 것은 대부분 볼륨입니다.

`docker compose ...` 명령은 compose 파일이 있는 폴더에서 실행합니다.

```powershell
cd D:\Dev\server
```

## 매일 쓰는 명령 7개

| 명령 | 무엇을 하는가 | 정상이면 |
|---|---|---|
| `docker compose ps` | 컨테이너 상태와 포트 확인 | `Up ... (healthy)` |
| `docker compose logs -f --tail 100 open-webui` | 최근 로그 100줄을 보고 이어서 따라감 | 새 오류가 계속 나오지 않음 |
| `docker exec open-webui curl -fsS http://localhost:8080/health` | 컨테이너 안에서 명령 실행 | `{"status":true}` |
| `docker stats --no-stream open-webui` | CPU·메모리 사용량을 한 번 출력 | 메모리가 한도에 붙어 있지 않음 |
| `docker compose restart open-webui` | 같은 컨테이너를 다시 시작 | 잠시 뒤 다시 `healthy` |
| `docker compose stop` | 컨테이너를 지우지 않고 멈춤 | `docker compose ps -a`에 `Exited` |
| `docker compose start` | 멈춘 컨테이너를 다시 시작 | 다시 `Up` |

먼저 볼 것은 `ps`입니다. 제 환경의 출력에서 필요한 열만 고르면 이렇습니다.

```text
NAME         SERVICE      STATUS                 PORTS
open-webui   open-webui   Up 7 hours (healthy)   127.0.0.1:3000->8080/tcp
```

세 가지를 읽습니다. `Up`이면 프로세스가 살아 있고, `(healthy)`면 이미지에 정의된 상태 검사를 통과했고, `127.0.0.1:3000->8080/tcp`면 이 PC의 3000번으로 들어온 요청이 컨테이너의 8080번으로 전달됩니다.

`docker compose` 명령에는 **서비스 이름**을, `docker` 명령에는 **컨테이너 이름**을 씁니다. 이 예제는 이름이 같아서 어느 쪽이든 `open-webui`입니다. `logs -f`는 `Ctrl+C`로 빠져나오면 되고, 이때 컨테이너는 멈추지 않습니다.

`docker stop`은 프로세스에 종료 신호(SIGTERM)를 보내고, Linux 컨테이너 기준 기본 10초 안에 끝나지 않으면 강제 종료(SIGKILL)합니다. 그래서 전원을 뽑듯 끄는 것보다 `stop`이 안전합니다.

## 무엇이 무엇을 지우는가

정리 명령은 이름이 비슷하지만 지우는 대상이 다릅니다. 위험도는 **되돌리기 어려운 데이터가 사라지는가**를 기준으로 표시했습니다.

| 위험 | 명령 | 지우는 것 | 남는 것 |
|---|---|---|---|
| 낮음 | `docker compose stop` | 없음 (멈추기만 함) | 전부 |
| 낮음 | `docker compose down` | 이 프로젝트의 컨테이너, 네트워크 | 이미지, 볼륨 |
| **⚠ 높음** | `docker compose down -v` | 위 + 이 프로젝트의 **이름 있는 볼륨**과 익명 볼륨 | 이미지 |
| 낮음 | `docker rm open-webui` | 멈춘 컨테이너 (실행 중이면 `-f` 필요) | 이미지, 볼륨 |
| 보통 | `docker rm -v open-webui` | 컨테이너 + 익명 볼륨 | 이름 있는 볼륨 |
| 낮음 | `docker image prune` | 태그 없는 이미지(dangling) | 태그 있는 이미지, 볼륨 |
| 보통 | `docker image prune -a` | 어떤 컨테이너도 쓰지 않는 이미지 전부 (다시 받아야 함) | 사용 중인 이미지, 볼륨 |
| 보통 | `docker system prune` | 멈춘 컨테이너, 안 쓰는 네트워크, dangling 이미지, 빌드 캐시 | 볼륨 |
| 보통 | `docker system prune --volumes` | 위 + 안 쓰는 **익명** 볼륨 | 이름 있는 볼륨 |
| **⚠ 높음** | `docker volume prune -a` | 안 쓰는 볼륨 전부, **이름 있는 볼륨 포함** | 사용 중인 볼륨 |

가장 자주 헷갈리는 것은 `down`과 `down -v`입니다. 글자 두 개 차이로 결과가 갈립니다.

<figure class="diagram">
{% include figures/docker-operations-troubleshooting/down-vs-down-v.svg %}
<figcaption>down은 볼륨을 남기고, down -v는 볼륨까지 지웁니다</figcaption>
</figure>

조합할 때 더 조심해야 합니다.

- `docker compose down`을 한 직후에는 볼륨을 쓰는 컨테이너가 없습니다. 이때 `docker volume prune -a`를 실행하면 Open WebUI의 볼륨도 "안 쓰는 볼륨"에 들어갑니다.
- `docker compose stop`으로 멈춘 뒤 `docker system prune`을 실행하면 멈춘 컨테이너가 지워집니다. 데이터는 볼륨에 남지만 `docker compose start`로는 돌아오지 못하고 `docker compose up -d`로 다시 만들어야 합니다.
- `prune`은 이 프로젝트만이 아니라 **Docker 전체**가 대상입니다. 다른 실습용 컨테이너나 이미지도 함께 지워질 수 있습니다.

### 임시 컨테이너로 확인한 결과

볼륨 안의 파일과 컨테이너 안 `/tmp`의 파일을 하나씩 만들고 명령을 차례로 실행했습니다.

| 동작 | 컨테이너 안 파일 | 볼륨 파일 |
|---|---|---|
| `stop` 후 `start` | 남음 | 남음 |
| `restart` | 남음 | 남음 |
| 이미지가 바뀐 뒤 `up -d` (컨테이너 교체) | **사라짐** | 남음 |
| `down` 후 `up -d` | 컨테이너째 삭제 | 남음 |
| `down -v` 후 `up -d` | 컨테이너째 삭제 | **사라짐** |

컨테이너 안에 직접 고친 내용은 업데이트 때 사라집니다. 남겨야 하는 것은 볼륨에 두거나 compose 파일에 적어야 합니다.

## 안전하게 업데이트하기

### main 태그의 뜻

예제의 이미지는 `ghcr.io/open-webui/open-webui:main`입니다. 태그는 버전 번호처럼 보여도 **움직일 수 있는 이름표**입니다. Open WebUI 문서에 따르면 `:main`은 항상 최신 빌드를 가리키고, 예고 없이 호환되지 않는 변경이 들어갈 수 있습니다. 혼자 시험 삼아 쓴다면 편하지만, 안정적으로 쓰려면 `:vX.Y.Z` 같은 릴리스 태그로 고정하는 것을 문서가 권합니다.

```yaml
    image: ghcr.io/open-webui/open-webui:vX.Y.Z  # 릴리스 페이지에서 실제 버전 확인
```

### 업데이트 순서

```powershell
cd D:\Dev\server

# 1. 지금 상태가 정상인지 확인
docker compose ps

# 2. 볼륨 백업 (다음 절)

# 3. 새 이미지 내려받기: 아직 컨테이너는 바뀌지 않음
docker compose pull

# 4. pull이 성공한 뒤 컨테이너 교체
docker compose up -d

# 5. 결과 확인
docker compose ps
docker compose logs --tail 50 open-webui
```

`pull`은 이미지를 받기만 하고 컨테이너를 시작하지 않습니다. 실제 교체는 `up -d`가 합니다. Compose는 이미지나 설정이 바뀐 서비스의 컨테이너를 멈추고 새로 만들며, 연결된 볼륨은 유지합니다. 임시 프로젝트에서 이미지를 바꾸고 `up -d`를 실행했을 때도 컨테이너는 새것으로 바뀌고 볼륨 파일은 그대로였습니다.

`docker compose restart`는 업데이트 명령이 아닙니다. 기존 컨테이너를 다시 켤 뿐이어서 새 이미지나 compose 파일 변경이 반영되지 않습니다.

두 가지를 더 기억해 둡니다.

- **되돌리기가 항상 쉽지는 않습니다.** Open WebUI 문서는 데이터베이스 마이그레이션이 한 방향이라고 설명합니다. 이미지만 이전 버전으로 돌리면 새 구조의 데이터와 맞지 않을 수 있으므로, 업데이트 전 백업을 함께 복원해야 합니다.
- **다시 로그인해야 할 수 있습니다.** `WEBUI_SECRET_KEY`를 고정하지 않으면 컨테이너를 새로 만들 때 새 키가 생겨 기존 세션이 끊긴다고 문서에 적혀 있습니다. 계정이 사라진 것은 아닙니다.

## 볼륨 백업과 복원

Open WebUI의 볼륨에는 `webui.db`, `webui.db-shm`, `webui.db-wal`, `cache/`, `uploads/`, `vector_db/`가 있고, 제 환경에서는 합계 1.1GB였습니다. `webui.db`는 SQLite 데이터베이스입니다. SQLite 문서는 쓰기 도중 파일을 복사하면 백업이 손상될 수 있고, `-wal` 파일은 데이터베이스와 함께 다뤄야 한다고 설명합니다. 그래서 **컨테이너를 멈춘 뒤** 볼륨 전체를 묶습니다.

### 백업

볼륨과 백업 폴더를 동시에 연결한 일회용 컨테이너가 `tar`로 압축합니다. `:ro`는 읽기 전용이라는 뜻입니다.

```powershell
cd D:\Dev\server
docker compose stop

New-Item -ItemType Directory -Force D:\docker-backup | Out-Null
cd D:\docker-backup

docker run --rm -v "server_webui-data:/data:ro" -v "${PWD}:/backup" ubuntu:22.04 tar czf /backup/webui-data-backup.tar.gz -C /data .

# 압축 파일 안의 목록 확인
docker run --rm -v "${PWD}:/backup:ro" ubuntu:22.04 tar tzf /backup/webui-data-backup.tar.gz

cd D:\Dev\server
docker compose start
```

정상이면 `D:\docker-backup`에 `webui-data-backup.tar.gz`가 생기고, 목록에 `./webui.db`와 `./uploads/`가 보입니다. 이 파일에는 계정과 대화 내용이 들어 있으니 공유 폴더에 그대로 두지 않습니다. 볼륨과 같은 디스크에만 두면 디스크 고장에는 대비되지 않으므로, 중요한 데이터라면 다른 저장 장치에도 복사합니다.

### 복원은 새 볼륨에서 먼저 시험

백업은 복원해 봐야 쓸 수 있는지 압니다. 기존 볼륨을 건드리지 않고 시험용 볼륨에 풉니다.

```powershell
cd D:\docker-backup
docker volume create webui-restore-test

docker run --rm -v "webui-restore-test:/data" -v "${PWD}:/backup:ro" ubuntu:22.04 tar xzf /backup/webui-data-backup.tar.gz -C /data

docker run --rm -v "webui-restore-test:/data:ro" ubuntu:22.04 ls -la /data

docker volume rm webui-restore-test
```

### 실제 복원

아래의 `down -v`는 **현재 볼륨을 삭제합니다.** 백업 파일을 시험한 뒤에만 실행합니다.

```powershell
cd D:\Dev\server
docker compose down -v
docker compose up --no-start

cd D:\docker-backup
docker run --rm -v "server_webui-data:/data" -v "${PWD}:/backup:ro" ubuntu:22.04 sh -c "find /data -mindepth 1 -delete && tar xzf /backup/webui-data-backup.tar.gz -C /data"

cd D:\Dev\server
docker compose start
docker compose ps
```

`up --no-start`는 컨테이너와 볼륨을 만들되 앱을 켜지 않습니다. 앱이 빈 데이터로 먼저 초기화되는 일을 막기 위해서입니다. 이 흐름은 같은 구조의 임시 프로젝트에서 실행해 파일이 그대로 돌아오는 것까지 확인했습니다. 다만 경로는 `D:`가 아니라 임시 폴더를 썼고, 실제 Open WebUI 볼륨에는 실행하지 않았습니다.

## restart 정책과 PC 재부팅

예제의 `restart: unless-stopped`는 "내가 직접 멈추지 않았다면 다시 띄운다"는 뜻입니다.

| 상황 | `unless-stopped`의 동작 |
|---|---|
| 프로세스가 오류로 종료 | 다시 시작 |
| `docker compose stop`으로 직접 멈춤 | 멈춘 채 유지 |
| 직접 멈춘 뒤 Docker 엔진이 재시작 | 계속 멈춘 채 유지 |
| 실행 중에 Docker 엔진이 재시작 | 엔진이 올라오면 다시 시작 |

임시 컨테이너를 1초 뒤 오류로 끝나게 만들었더니 몇 초 사이 재시작 횟수가 4번으로 늘었고, `docker stop` 뒤에는 더 늘지 않고 `exited`로 남았습니다.

Windows에서는 한 단계가 더 있습니다. 컨테이너를 되살리는 주체는 Docker 엔진이고, 엔진은 Docker Desktop이 켜져야 돕니다. Docker Desktop의 **Start Docker Desktop when you sign in to your computer** 설정은 문서 기준 기본값이 꺼짐입니다. 그래서 재부팅 뒤 자동으로 Open WebUI까지 뜨게 하려면 이 설정을 켜고, Windows에 로그인해야 합니다. 실제 재부팅 시험은 하지 않았으니, 설정을 바꾼 뒤 한 번 재부팅해서 `docker compose ps`로 확인하는 것을 권합니다.

## 문제 해결은 순서대로

증상을 보고 바로 재설치하면 원인을 알 기회도 함께 사라집니다. 컨테이너 자체에서 시작해 연결과 자원으로 넓혀 가며 하나씩 확인합니다.

<figure class="diagram">
{% include figures/docker-operations-troubleshooting/troubleshooting-flow.svg %}
<figcaption>앞 단계에서 이상이 보이면 거기서 원인을 좁힙니다</figcaption>
</figure>

### 1. 상태

```powershell
docker compose ps -a
```

`-a`를 붙이면 멈춘 컨테이너도 보입니다. `Up (healthy)`면 다음 단계로, `Exited`면 바로 로그로, `Restarting`이면 시작 직후 죽고 있으니 로그로 갑니다.

### 2. 로그

```powershell
docker compose logs --tail 100 open-webui
```

마지막 오류 한 줄보다 **처음 나온 오류**가 원인에 가까운 경우가 많습니다. 시간이 필요하면 `--timestamps`를 붙입니다.

### 3. 컨테이너 내부 접속

```powershell
docker exec open-webui curl -fsS http://localhost:8080/health
```

`{"status":true}`면 앱 자체는 응답합니다. 이 명령의 `localhost`는 Windows가 아니라 **컨테이너 자신**입니다.

### 4. 연결

```powershell
# Windows에서 컨테이너로
curl.exe -s -o NUL -w "%{http_code}" http://localhost:3000

# 컨테이너에서 Windows의 Ollama로
docker exec open-webui curl -s http://host.docker.internal:11434/api/version
```

정상이면 첫 명령은 `200`, 두 번째는 `{"version":"0.40.16"}`처럼 Ollama 버전을 돌려줍니다. 첫 명령만 실패하면 포트 쪽, 두 번째만 실패하면 Ollama 연결 쪽을 봅니다.

### 5. 자원

```powershell
docker stats --no-stream open-webui
docker system df
ollama ps
```

여기서 놓치기 쉬운 점이 있습니다. 이 구성에서 Ollama는 컨테이너가 아니라 **Windows 프로그램**입니다. 그래서 모델이 쓰는 CPU·GPU·메모리는 `docker stats`에 나오지 않습니다. 모델 쪽은 `ollama ps`의 `PROCESSOR` 열을 봅니다. `100% GPU`면 모델 전체가 GPU에 올라간 것이고, `48%/52% CPU/GPU`처럼 나뉘면 일부가 시스템 메모리에 있습니다.

## 자주 만나는 증상

### 포트 충돌

3000번을 이미 누가 쓰고 있으면 이런 오류가 납니다.

```text
Bind for 127.0.0.1:3000 failed: port is already allocated
```

{% raw %}
```powershell
# Docker 컨테이너가 쓰고 있는지 먼저 확인
docker ps --filter "publish=3000" --format "table {{.Names}}\t{{.Ports}}"

# Docker 밖의 프로그램인지 확인
Get-NetTCPConnection -LocalPort 3000 -State Listen
```
{% endraw %}

순서가 중요합니다. 제 PC에서는 `open-webui`가 3000번을 쓰는 중인데도 `netstat`과 `Get-NetTCPConnection`에 대기(LISTENING) 항목이 보이지 않았고, `docker ps --filter`에서만 바로 찾을 수 있었습니다.

상대를 끌 수 없다면 compose 파일에서 **왼쪽 숫자**만 바꿉니다. 왼쪽은 Windows 쪽 포트, 오른쪽은 컨테이너 안 앱의 포트입니다.

```yaml
    ports:
      - "127.0.0.1:3001:8080"
```

저장한 뒤 `docker compose up -d`를 실행하고 `http://localhost:3001`로 접속합니다. `restart`로는 포트 변경이 반영되지 않습니다.

### unhealthy

`unhealthy`는 프로세스가 죽었다는 뜻이 아니라 **상태 검사가 연속으로 실패했다**는 뜻입니다. 이 이미지는 컨테이너 안에서 `/health`를 호출해 검사합니다.

{% raw %}
```powershell
docker inspect --format "{{json .State.Health}}" open-webui
```
{% endraw %}

출력의 `Log`에 최근 검사의 종료 코드와 메시지가 있습니다. 처음 띄운 직후의 `health: starting`은 준비 중이라는 뜻입니다. 제 환경도 첫 시작에는 시간이 걸렸고 잠시 뒤 `healthy`가 됐습니다. 오래 기다려도 나아지지 않으면 로그와 3단계를 봅니다.

`restart: unless-stopped`가 있어도 `unhealthy`만으로 컨테이너가 재시작되지는 않습니다. 상태 검사가 계속 실패하는 임시 컨테이너를 만들었을 때 상태는 `Up (unhealthy)`, 재시작 횟수는 0이었습니다. restart 정책은 프로세스가 **종료될 때** 동작합니다.

### pull 시간 초과

회선이 불안정할 때 이미지 받기가 몇 번 시간 초과됐고, 다시 실행해서 받았습니다. Open WebUI 이미지는 제 환경에서 6.46GB로 큰 편입니다.

```powershell
docker compose pull
```

`pull`이 실패해도 실행 중인 컨테이너는 그대로입니다. **성공을 확인한 뒤에** `up -d`를 실행합니다. 계속 실패하면 다른 회선에서 시도해 Docker 문제인지 네트워크 문제인지 나눠 봅니다.

### 디스크 부족

```powershell
docker system df
```

제 환경의 값은 이미지 6.577GB, 컨테이너 55.6MB, 볼륨 1.119GB였습니다. `RECLAIMABLE` 열이 지울 수 있는 양의 추정치입니다. 안전한 순서는 다음과 같습니다.

1. `docker image prune`으로 태그 없는 이미지를 지웁니다. 업데이트 뒤 남은 옛 이미지가 주로 여기에 해당합니다.
2. 부족하면 다시 받아도 되는 이미지를 확인하고 `docker image prune -a`를 검토합니다.
3. 볼륨 정리는 마지막입니다. `docker volume ls`로 이름을 확인하고, 필요 없는 것을 이름으로 지정해 `docker volume rm`으로 지웁니다.

Windows에서 보이는 크기는 다른 값입니다. 제 환경의 Docker 데이터는 `D:\docker\DockerDesktopWSL\disk\docker_data.vhdx`라는 가상 디스크 파일 하나로 약 9.5GB였습니다. `docker system df`의 합계와 일치하지 않으며, Docker 안에서 지운 만큼 이 파일이 곧바로 줄어든다고 가정하면 안 됩니다. 탐색기에서 이 파일을 직접 지우면 이미지와 볼륨을 통째로 잃습니다.

## 실제 사례 1: 답변이 느린 원인은 Docker 밖에 있었다

Open WebUI의 답변이 유난히 늦게 나왔습니다. 컨테이너가 느린 것처럼 보였지만 원인은 다른 곳에 있었습니다.

먼저 모델 자체를 재 봤습니다. 약 34 tok/s, GPU 100%로 정상이었습니다. 생성 속도 문제가 아니라면 요청이 **시작되기 전에 기다리고** 있을 가능성이 있습니다.

로그에는 약 1분 20초짜리 요청 3개가 함께 끝난 기록이 있었습니다. Open WebUI는 본 답변 외에도 제목, 태그, 후속 질문을 만드는 요청을 보냅니다. 그런데 Ollama의 `OLLAMA_NUM_PARALLEL` 값이 1이어서, 모델 하나가 한 번에 요청 하나만 처리했고 나머지는 줄을 섰습니다.

| 항목 | 변경 전 | 변경 후 |
|---|---|---|
| `OLLAMA_NUM_PARALLEL` | 1 | 2 |
| 제목 생성 요청 | 본 답변과 함께 줄 서기 | 0.4초에 완료 |
| 본 답변 속도 | 약 34 tok/s | 유지 |

같은 때 `OLLAMA_CONTEXT_LENGTH`도 4K에서 16K로 올렸습니다. 이것은 긴 대화의 앞부분을 더 많이 유지하기 위한 변경이고, 줄 서기 해결과는 별개입니다.

값을 무작정 키우면 안 됩니다. Ollama 문서에 따르면 필요한 메모리는 `OLLAMA_NUM_PARALLEL × OLLAMA_CONTEXT_LENGTH`에 비례해 늘어납니다. 바꾼 뒤에는 `ollama ps`로 모델이 여전히 GPU에 올라가 있는지 확인합니다.

Windows에서는 Ollama를 트레이에서 종료하고, 사용자 환경 변수를 추가한 뒤, 시작 메뉴에서 다시 실행합니다. 로그는 `%LOCALAPPDATA%\Ollama\server.log`에 있습니다.

교훈은 "컨테이너 화면이 느리다고 원인이 컨테이너 안에 있는 것은 아니다"입니다. 앞의 5단계에서 연결과 자원을 나눠 본 이유가 여기에 있습니다.

## 실제 사례 2: compose 폴더를 옮겨도 데이터가 남은 이유

compose 파일을 `C:\Dev\server`에서 `D:\Dev\server`로 옮겨 다시 띄웠는데 계정과 데이터가 그대로였습니다. 데이터는 compose 폴더가 아니라 Docker의 볼륨에 있고, 볼륨 이름이 바뀌지 않았기 때문입니다.

Compose는 기본적으로 **compose 파일이 있는 폴더의 이름**을 프로젝트 이름으로 씁니다. 그래서 `server` 폴더의 `webui-data` 볼륨은 `server_webui-data`가 됩니다. 드라이브가 달라도 폴더 이름이 같으면 같은 볼륨을 찾습니다.

임시 프로젝트로 시험한 결과는 다음과 같습니다.

| 옮긴 방식 | 프로젝트 이름 | 볼륨 내용 |
|---|---|---|
| 다른 위치, **같은 폴더 이름** | 그대로 | 기존 데이터가 보임 |
| **다른 폴더 이름** | 바뀜 | 새 빈 볼륨이 생김 |

폴더 이름을 바꿨는데 계정이 사라진 것처럼 보이면, 데이터가 지워졌다고 판단하기 전에 `docker volume ls`로 옛 볼륨이 남아 있는지 확인합니다. 폴더 이름에 묶이기 싫다면 compose 파일 맨 위에 프로젝트 이름을 적어 둘 수 있습니다.

```yaml
name: server
```

옮기는 순서는 `docker compose down`(`-v` 없이) → 폴더 이동 → 새 위치에서 `docker compose up -d`입니다.

## 실제 사례 3: 빈 `C:\Dev`가 지워지지 않았다

폴더를 옮긴 뒤 빈 `C:\Dev`를 지우려 했더니 지워지지 않았습니다. 처음에는 그 폴더를 열어 둔 VS Code를 의심했지만, 프로세스를 확인해 보니 **Ollama 프로세스의 작업 폴더**가 그곳이었습니다. 프로그램을 시작한 위치가 작업 폴더로 남아 있으면, 파일이 하나도 없어도 폴더를 지울 수 없습니다.

정리 방법은 Ollama를 종료해 폴더를 놓게 한 뒤, 폴더를 지우고 Ollama를 다른 위치에서 다시 시작하는 것입니다. 지금은 `C:\Dev`가 남아 있지 않습니다. 어떤 프로세스가 파일이나 폴더를 잡고 있는지 찾을 때는 Microsoft의 [Process Explorer](https://learn.microsoft.com/en-us/sysinternals/downloads/process-explorer)도 쓸 수 있습니다.

## 시리즈 정리

| 편 | 기억할 한 가지 |
|---|---|
| 1. 이미지와 컨테이너 | 이미지는 실행 재료, 컨테이너는 거기서 만든 실행 단위 |
| 2. WSL2와 Docker Desktop | Windows의 Docker 명령은 WSL2 안의 Linux 엔진과 통신 |
| 3. 파일 위치 | 이미지와 볼륨은 낱개 파일이 아니라 vhdx 안에 있음 |
| 4. compose 파일 | 실행 설정을 파일 하나에 적어 다시 만들 수 있게 함 |
| 5. Ollama 연결 | 컨테이너의 `localhost`는 Windows가 아니라 컨테이너 자신 |
| 6. 운영과 문제 해결 | 컨테이너는 다시 만들 수 있고, 지켜야 할 것은 볼륨 |

## 운영 점검표

**평소**

- [ ] `docker compose ps`에서 `Up (healthy)`인가?
- [ ] `http://localhost:3000`이 열리는가?
- [ ] `docker system df`에서 디스크 사용량이 급하게 늘지 않았는가?

**업데이트 전**

- [ ] 컨테이너를 멈추고 볼륨을 백업했는가?
- [ ] 백업을 시험용 볼륨에 풀어 봤는가?
- [ ] 쓰려는 이미지 태그의 의미를 알고 있는가?

**업데이트 후**

- [ ] `docker compose pull`이 성공한 뒤 `up -d`를 실행했는가?
- [ ] 다시 `healthy`가 되었는가?
- [ ] 로그인과 기존 대화, Ollama 모델 목록을 확인했는가?

**명령 실행 전**

- [ ] `-v`, `--volumes`, `volume prune -a`가 들어 있지 않은가?
- [ ] 들어 있다면 지워질 볼륨 이름을 확인했고 백업이 있는가?

## 참고 문서

- Docker: [compose down](https://docs.docker.com/reference/cli/docker/compose/down/), [compose up](https://docs.docker.com/reference/cli/docker/compose/up/), [compose pull](https://docs.docker.com/reference/cli/docker/compose/pull/), [compose restart](https://docs.docker.com/reference/cli/docker/compose/restart/)
- Docker: [container rm](https://docs.docker.com/reference/cli/docker/container/rm/), [container stop](https://docs.docker.com/reference/cli/docker/container/stop/), [image prune](https://docs.docker.com/reference/cli/docker/image/prune/), [system prune](https://docs.docker.com/reference/cli/docker/system/prune/), [volume prune](https://docs.docker.com/reference/cli/docker/volume/prune/)
- Docker: [Volumes](https://docs.docker.com/engine/storage/volumes/), [restart 정책](https://docs.docker.com/engine/containers/start-containers-automatically/), [HEALTHCHECK](https://docs.docker.com/reference/dockerfile/#healthcheck), [Compose 프로젝트 이름](https://docs.docker.com/compose/how-tos/project-name/), [Docker Desktop 설정](https://docs.docker.com/desktop/settings-and-maintenance/settings/)
- Open WebUI: [Updating](https://docs.openwebui.com/getting-started/updating/)
- Ollama: [FAQ](https://docs.ollama.com/faq), [Troubleshooting](https://docs.ollama.com/troubleshooting)
- SQLite: [How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html)
