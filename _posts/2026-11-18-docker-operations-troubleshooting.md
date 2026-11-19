---
title: "Docker 운영 입문: 로그 확인, 안전한 업데이트, 데이터 지키기, 느릴 때 찾는 법"
date: 2026-11-18 19:25:00 +0900
categories: [개발 도구, Docker]
tags: [docker, windows, docker-compose, troubleshooting, backup, open-webui, ollama]
description: "Windows의 Docker Desktop에서 Open WebUI를 운영할 때 필요한 상태·로그 명령, 삭제 명령의 범위, 검증하는 백업과 기존 볼륨을 지우지 않는 복원, 포트 충돌과 응답 지연을 찾는 순서를 정리합니다."
---

> **시리즈: Windows에서 Docker 처음 배우기**
> 1. Docker란 무엇인가: 이미지와 컨테이너 (예정)
> 2. Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop (예정)
> 3. 무엇이 어느 폴더에 생기나: 이미지·컨테이너·볼륨의 실제 위치 (예정)
> 4. docker-compose.yml 한 줄씩 읽기: Open WebUI 띄우기 (예정)
> 5. 컨테이너에서 Windows의 Ollama 연결하기: localhost와 host.docker.internal (예정)
> 6. **Docker 운영과 문제 해결: 로그, 업데이트, 데이터 지키기** ← 지금 글

컨테이너를 한 번 띄우는 것과 계속 쓰는 것은 다른 일입니다. 화면이 안 열리면 어디부터 볼지, 정리 명령이 대화 기록까지 지우지는 않는지, 업데이트가 잘못되면 어떻게 돌아올지, 답변이 왜 늦는지를 알아야 합니다.

이 글은 Windows의 Ollama와 Docker 컨테이너로 띄운 Open WebUI를 예제로 이 질문에 답합니다. 백업·복원·전환·되돌리기 명령은 같은 Open WebUI 이미지로 만든 **임시 프로젝트**에서 실행해 확인했습니다(Docker 29.9.3, Compose 5.7.0). PC 전체가 대상인 `prune`과 실제 재부팅은 실행하지 않았고 공식 문서 기준으로 적었습니다.

## 예제 환경

Docker Desktop을 켠 뒤 PowerShell에서 compose 파일이 있는 폴더로 이동합니다.

```powershell
cd D:\Dev\server
```

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

계정·대화·업로드 파일은 컨테이너 안 `/app/backend/data`에 연결된 **볼륨**에 있습니다. 컨테이너는 이미지로 다시 만들 수 있지만 볼륨은 그렇지 않으므로, 운영에서 지켜야 할 것은 대부분 볼륨입니다.

## 매일 쓰는 명령 7개

| 명령 | 무엇을 하는가 | 정상이면 |
|---|---|---|
| `docker compose ps -a` | 상태와 포트 확인 | `Up ... (healthy)` |
| `docker compose logs -f --tail 100 open-webui` | 최근 로그를 보고 이어서 따라감 | 새 오류가 계속 나오지 않음 |
| `docker exec open-webui curl -fsS http://localhost:8080/health` | 컨테이너 안에서 명령 실행 | `{"status":true}` |
| `docker stats --no-stream open-webui` | CPU·메모리를 한 번 출력 | `MEM USAGE`가 `LIMIT`에 붙어 있지 않음 |
| `docker compose restart open-webui` | 같은 컨테이너를 다시 시작 | 잠시 뒤 다시 `healthy` |
| `docker compose stop open-webui` | 지우지 않고 멈춤 | `ps -a`에 `Exited` |
| `docker compose start open-webui` | 멈춘 컨테이너를 다시 시작 | 다시 `Up` |

```text
NAME         SERVICE      STATUS                 PORTS
open-webui   open-webui   Up 7 hours (healthy)   127.0.0.1:3000->8080/tcp
```

`Up`은 프로세스가 살아 있다는 뜻, `(healthy)`는 이미지에 정의된 상태 검사를 통과했다는 뜻입니다. 포트 열은 이 PC의 3000번이 컨테이너의 8080번으로 이어진다는 뜻입니다.

`logs`, `restart`처럼 서비스를 받는 Compose 명령에는 **서비스 이름**을, `docker exec`, `docker stats`에는 **컨테이너 이름**을 씁니다. 이 예제는 둘 다 `open-webui`입니다. `stop`은 이 Linux 컨테이너에 별도 설정이 없으면 SIGTERM을 보내고 기본 10초 뒤 SIGKILL로 끝냅니다.

## 무엇이 무엇을 지우는가

**`docker compose down -v`는 이 예제의 계정과 대화가 든 볼륨을 지웁니다.** 아래 표의 위험도는 중요한 데이터가 이름 있는 볼륨에 있는 이 예제 기준입니다. 컨테이너 안에만 둔 파일은 "낮음" 명령으로도 사라집니다. 좁은 화면에서는 표를 가로로 밀어 보세요.

| 위험 | 명령 | 지우는 것 | 남는 것 |
|---|---|---|---|
| 낮음 | `docker compose stop` | 없음 | 전부 |
| 낮음 | `docker compose down` | 프로젝트의 컨테이너, 네트워크 | 이미지, 볼륨, external 자원 |
| **⚠ 높음** | `docker compose down -v` | 위 + Compose가 관리하는 이름 있는 볼륨, 익명 볼륨 | 이미지, external 자원 |
| 낮음 | `docker rm open-webui` | 멈춘 컨테이너 | 이미지, 볼륨 |
| **⚠ 높음** | `docker rm -v open-webui` | 컨테이너 + 연결된 익명 볼륨 | 이름 있는 볼륨 |
| 낮음 | `docker image prune` | dangling 이미지(태그가 없고 컨테이너가 참조하지 않음) | 나머지 이미지 |
| 보통 | `docker image prune -a` | 컨테이너가 참조하지 않는 이미지 전부. 로컬에서 빌드한 이미지 포함 | 참조 중인 이미지 |
| 보통 | `docker system prune` | **다른 프로젝트까지** 모든 멈춘 컨테이너, 안 쓰는 네트워크, dangling 이미지, 안 쓰는 빌드 캐시 | 볼륨 |
| **⚠ 높음** | `docker system prune --volumes` | 위 + 참조 없는 익명 볼륨 | 이름 있는 볼륨 |
| **⚠ 높음** | `docker volume prune -a` | 참조 없는 볼륨 전부, 이름 있는 볼륨 포함 | 참조 중인 볼륨 |

여기서 "참조"에는 **멈춘 컨테이너도 포함**됩니다. 익명 볼륨은 `down` 뒤 새 컨테이너에 자동으로 다시 연결되지 않습니다. `system prune -a`는 dangling 대신 참조 없는 이미지 전체를 지웁니다.

<figure class="diagram">
{% include figures/docker-operations-troubleshooting/down-vs-down-v.svg %}
<figcaption>이 예제의 Compose 관리 볼륨 기준: down은 같은 볼륨을 다시 연결하고, down -v는 기존 데이터를 지웁니다</figcaption>
</figure>

조합할 때 특히 조심합니다. `down` 직후 다른 컨테이너가 참조하지 않으면 Open WebUI 볼륨도 `docker volume prune -a`의 대상입니다. `stop` 뒤 `system prune`을 실행하면 멈춘 컨테이너가 지워져 `start`로는 돌아오지 못하고 `up -d`로 다시 만들어야 합니다.

## 안전하게 업데이트하기

`:main`은 최신 빌드를 가리키도록 계속 바뀌는 **움직이는 태그**이고, 사전 공개용 `:dev`와는 별개입니다. Open WebUI 문서는 `:main`에 예고 없는 호환성 변경이 들어갈 수 있다고 설명하고, 재현성이 필요하면 `:vX.Y.Z` 고정 태그를 권합니다.

1. 아래 절차로 백업합니다. 실패하면 업데이트하지 않습니다.
2. 고정 태그를 쓴다면 릴리스 노트를 읽고 compose의 `image:` 버전을 바꿉니다. 이 단계를 빼면 `pull`해도 버전이 오르지 않습니다.
3. `docker compose pull`을 실행합니다. 이미지만 받으며 실행 중인 컨테이너는 바뀌지 않습니다.
4. 성공을 확인한 뒤 `docker compose up -d`로 컨테이너를 교체합니다. 연결된 볼륨은 유지됩니다.
5. `docker compose ps`와 `docker compose logs --tail 50 open-webui`로 확인합니다.

`docker compose restart`는 기존 컨테이너를 다시 켤 뿐이라 새 이미지나 compose 변경을 반영하지 않습니다. 데이터베이스 구조가 바뀌는 릴리스는 이미지만 되돌려도 구조가 돌아오지 않으므로, 업데이트 전 백업을 복원해야 합니다. `WEBUI_SECRET_KEY`를 고정하지 않았다면 컨테이너를 새로 만들 때 세션이 끊겨 다시 로그인해야 할 수 있습니다.

## 검증하는 백업

`webui.db`는 SQLite 파일이고, 쓰는 도중 복사하면 백업이 손상될 수 있습니다. 그래서 앱을 멈추고 묶습니다. 같은 볼륨을 쓰는 다른 프로그램이 있다면 그것도 멈춥니다.

볼륨 이름은 복사하지 말고 **실행 중인 컨테이너에서 읽습니다.** `docker run -v`에 없는 이름을 주면 오류 없이 빈 볼륨이 만들어져, 빈 백업을 정상으로 착각할 수 있습니다. 여기서 `-v`는 볼륨을 연결하는 옵션으로, `down -v`의 삭제와는 다릅니다. 아래 블록은 통째로 붙여 넣습니다. 날짜가 든 새 파일을 임시 이름으로 만들고, 각 단계를 확인한 뒤에만 최종 이름으로 옮기며, 성공하든 실패하든 앱을 다시 시작합니다.

{% raw %}
```powershell
function Test-Step($step) { if ($LASTEXITCODE -ne 0) { throw "$step 실패" } }
$stopped = $false; $tmp = $null
try {
  cd D:\Dev\server
  $dir = 'D:\docker-backup'
  $vol = docker inspect open-webui --format '{{range .Mounts}}{{if eq .Destination `/app/backend/data`}}{{.Name}}{{end}}{{end}}'
  Test-Step '컨테이너 확인'
  if (-not $vol) { throw '데이터 볼륨을 찾지 못했습니다' }
  $image = docker inspect open-webui --format '{{.Image}}'
  $digest = docker image inspect $image --format '{{index .RepoDigests 0}}'
  Test-Step '이미지 확인'

  $backup = "webui-data-$(Get-Date -Format 'yyyyMMdd-HHmmss').tar.gz"
  $tmp = "$dir\$backup.tmp"
  New-Item -ItemType Directory -Force $dir -ErrorAction Stop | Out-Null
  docker compose stop open-webui; Test-Step '앱 정지'
  $stopped = $true

  docker run --rm -v "${vol}:/data:ro" -v "${dir}:/backup" $image tar czf "/backup/$backup.tmp" -C /data .
  Test-Step '압축'
  if (-not (Test-Path $tmp)) { throw '임시 파일이 없습니다' }
  $list = docker run --rm -v "${dir}:/backup:ro" $image tar tzf "/backup/$backup.tmp"
  Test-Step '목록 확인'
  if ($list -notcontains './webui.db') { throw 'webui.db가 없습니다' }

  $digest | Set-Content "$dir\$backup.image.txt" -ErrorAction Stop
  Move-Item $tmp "$dir\$backup" -ErrorAction Stop
  "백업 완료: $dir\$backup ($vol)"
} finally {
  if ($tmp) { Remove-Item $tmp -ErrorAction SilentlyContinue }
  if ($stopped) {
    docker compose start open-webui
    if ($LASTEXITCODE -ne 0) { Write-Warning '앱 시작 실패: 상태와 로그를 확인하세요' }
  }
}
```
{% endraw %}

오류가 나면 "백업 완료"가 출력되지 않습니다. 이때는 업데이트로 넘어가지 말고 `docker compose ps`로 앱이 돌아왔는지 본 뒤 원인을 고칩니다. `.image.txt`에는 백업 당시 이미지가 기록됩니다. **앱 버전이 데이터와 맞아야 하므로** 복원할 때 이 이미지를 씁니다. 백업 파일에는 계정과 대화가 들어 있으니 공유 폴더에 두지 말고, 중요하면 다른 저장 장치에도 복사합니다.

## 기존 볼륨을 지우지 않는 복원

복원은 현재 볼륨을 덮어쓰지 않습니다. **새 볼륨에 풀어 시험하고, 통과한 뒤 compose가 그 볼륨을 보게 바꿉니다.** 먼저 위 백업 블록을 한 번 더 실행해 현재 상태도 백업합니다. 그다음 같은 PowerShell 창에서 복원할 파일 이름을 넣어 실행합니다.

{% raw %}
```powershell
try {
  cd D:\Dev\server
  $dir = 'D:\docker-backup'
  $restore = 'webui-data-20261118-210000.tar.gz'   # 복원할 백업
  $image = (Get-Content "$dir\$restore.image.txt" -ErrorAction Stop).Trim()
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $newVol = "webui-restore-$stamp"
  $test = "webui-restore-test-$stamp"

  docker volume create $newVol | Out-Null; Test-Step '볼륨 생성'
  docker run --rm -v "${newVol}:/data" -v "${dir}:/backup:ro" $image tar xzf "/backup/$restore" -C /data
  Test-Step '압축 풀기'
  $check = docker run --rm -v "${newVol}:/data:ro" $image sh -c "cp /data/webui.db* /tmp/ && python -c 'import sys,sqlite3; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' /tmp/webui.db 'PRAGMA integrity_check'"
  Test-Step '무결성 검사'
  if ($check -ne 'ok') { throw "DB 검사 결과: $check" }

  docker run -d --name $test -p 127.0.0.1:3901:8080 -v "${newVol}:/app/backend/data" $image | Out-Null
  Test-Step '시험 앱 시작'
  "시험 주소: http://localhost:3901 (볼륨 $newVol)"
} catch { Write-Warning "복원 시험 중단: $_" }
```
{% endraw %}

운영 앱은 3000번에서 그대로 돕니다. `docker ps --filter "name=$test"`에서 시험 앱이 `healthy`가 되면 `http://localhost:3901`에서 **로그인하고 기존 대화와 업로드 파일을 확인**합니다. 끝나면 시험 컨테이너를 지웁니다. 실패했거나 연습이었다면 이번에 만든 볼륨만 지웁니다.

```powershell
docker rm -f $test
docker volume rm $newVol   # 전환하지 않을 때만
```

확인이 끝났다면 compose 파일은 그대로 두고, 자동으로 합쳐지는 override 파일로 볼륨과 이미지를 바꿉니다.

```powershell
try {
  cd D:\Dev\server
  if (Test-Path docker-compose.override.yml) { throw '기존 override 파일을 먼저 확인하세요' }
  @"
services:
  open-webui:
    image: $image
volumes:
  webui-data:
    external: true
    name: $newVol
"@ | Set-Content -Encoding ascii docker-compose.override.yml
  docker compose config --quiet; Test-Step '설정 확인'
  docker compose up -d open-webui; Test-Step '전환'
} catch { Write-Warning "전환 중단: $_" }
```

전환할 때 원래 볼륨이 compose 설정과 맞지 않는다는 경고가 나올 수 있는데, 그 볼륨을 지우지 않고 둔다는 뜻입니다. `http://localhost:3000`에서 다시 로그인과 데이터를 확인합니다. 문제가 있으면 override만 지워 원래 볼륨으로 돌아갑니다. 원래 볼륨은 삭제되지 않았습니다.

```powershell
Remove-Item docker-compose.override.yml
docker compose up -d open-webui
```

복원 상태를 유지하는 동안 override를 지우지 않습니다. 이후 업데이트할 때는 override의 `image` 줄을 빼야 compose 파일의 이미지가 적용됩니다.

## restart 정책과 PC 재부팅

`restart: unless-stopped`는 정상적으로 시작된 컨테이너의 프로세스가 끝나면 다시 띄웁니다. 직접 `stop`한 컨테이너는 Docker 엔진이 재시작해도 멈춘 채로 둡니다. 공식 문서 기준으로 정책은 컨테이너가 최소 10초 실행돼 시작에 성공한 뒤 적용됩니다.

컨테이너를 되살리는 주체는 엔진이고, Windows에서 엔진은 Docker Desktop이 실행되어야 동작합니다. **Start Docker Desktop when you sign in to your computer**는 기본값이 꺼짐입니다. 재부팅 뒤 자동으로 뜨게 하려면 이 설정을 켜고 Windows에 로그인한 다음 `docker compose ps`로 확인합니다.

## 문제 해결은 순서대로

바로 재설치하면 원인을 알 기회도 사라집니다. 컨테이너 자체에서 시작해 연결과 자원으로 넓혀 갑니다.

<figure class="diagram">
{% include figures/docker-operations-troubleshooting/troubleshooting-flow.svg %}
<figcaption>이상이 보이는 단계에서 원인을 좁힙니다. 3단계는 컨테이너가 실행 중일 때만 합니다</figcaption>
</figure>

**1. 상태.** `docker compose ps -a`를 봅니다. 목록이 비면 폴더와 `docker context show`를 확인합니다. `Exited`나 `Restarting`이면 2단계에서 멈추고 원인을 찾습니다.

**2. 로그.** `docker compose logs --tail 100 open-webui`에서 마지막 줄만 보지 말고 **처음 나온 오류**를 찾습니다.

**3. 내부 접속.** 실행 중이면 `docker exec open-webui curl -fsS http://localhost:8080/health`를 실행합니다. `{"status":true}`면 앱은 응답합니다. 여기서 `localhost`는 Windows가 아니라 컨테이너 자신입니다.

**4. 연결.** 3단계가 성공했을 때 출발지별로 나눠 봅니다.

```powershell
# Windows → WebUI
curl.exe -sS -o NUL -w "%{http_code}`n" http://localhost:3000

# 컨테이너 → Ollama
docker exec open-webui curl -fsS http://host.docker.internal:11434/api/version
$LASTEXITCODE
```

| 결과 | 뜻과 다음 확인 |
|---|---|
| 첫 명령 `200` | Windows에서 WebUI까지 정상 |
| 첫 명령 `000`과 연결 오류 | HTTP 응답 없음. 포트 매핑과 접속 주소 확인 |
| 첫 명령 `4xx`·`5xx` | 앱까지 도착함. WebUI 로그 확인 |
| 둘째 명령 버전 JSON과 `0` | 컨테이너에서 Ollama까지 정상 |
| 둘째 명령 오류 메시지와 0이 아닌 값 | Ollama 실행 여부와 연결 설정 확인 |

**5. 자원.** Docker 쪽과 Ollama 쪽을 나눕니다. Ollama는 컨테이너가 아니라 Windows 프로그램이어서 `docker stats`에 나오지 않습니다.

```powershell
docker stats --no-stream open-webui   # 컨테이너 CPU·메모리
docker system df                      # 이미지·컨테이너·볼륨 디스크
ollama ps                             # 모델 배치
```

`ollama ps`의 `PROCESSOR`는 모델이 어디에 **올라갔는지**를 보여 줍니다. `100% GPU`는 전부 GPU 메모리에, `48%/52% CPU/GPU`는 나뉘어 올라갔다는 뜻이며 사용률이 아닙니다. 사용률과 GPU 메모리는 Windows 작업 관리자의 **성능 → GPU**에서 봅니다.

## 자주 만나는 증상

**포트 충돌.** `Bind for 127.0.0.1:3000 failed: port is already allocated`가 나오면 누가 쓰는지 찾습니다.

{% raw %}
```powershell
docker ps --filter "publish=3000" --format "table {{.Names}}\t{{.Ports}}"
Get-NetTCPConnection -LocalPort 3000 -State Listen
```
{% endraw %}

첫 명령에 이름이 나오면 그 컨테이너입니다. 둘째 명령은 Docker 밖 프로그램을 찾으며, `OwningProcess` 값을 `Get-Process -Id`에 넣으면 이름이 나옵니다. 제 PC에서는 `open-webui`가 쓰는 3000번이 둘째 명령에 보이지 않아 Docker부터 확인합니다. 바꿀 때는 `"127.0.0.1:3001:8080"`처럼 **왼쪽 숫자**만 고치고 `up -d`를 실행한 뒤 새 주소로 접속합니다.

**unhealthy.** 프로세스가 죽은 것이 아니라 상태 검사가 연속으로 실패했다는 뜻입니다. 첫 시작의 `health: starting`은 준비 중입니다. `unless-stopped`가 있어도 `unhealthy`만으로는 재시작되지 않으며, 임시 컨테이너에서도 재시작 횟수는 0이었습니다.

{% raw %}
```powershell
docker inspect --format "{{json .State.Health}}" open-webui
```
{% endraw %}

**pull 시간 초과.** 불안정한 회선에서 몇 번 실패했고 다시 실행해 받았습니다. 실패해도 실행 중인 컨테이너는 그대로이니 성공한 뒤에만 `up -d`를 실행합니다.

**디스크 부족.** `docker system df`의 `RECLAIMABLE`을 보고 `docker image prune`부터 실행합니다. 볼륨은 마지막에, 이름을 확인해 `docker volume rm`으로 하나씩 지웁니다. 제 환경의 Docker 데이터는 `D:\docker\DockerDesktopWSL\disk\docker_data.vhdx`에 있습니다. Docker 안에서 지운 만큼 이 파일이 곧바로 줄어든다고 가정하지 말고, 탐색기에서 직접 지우지도 않습니다.

## 실제 사례: 응답 지연과 폴더 두 건

**답변이 늦었던 경우.** 이 설정에서 관측한 생성 속도는 약 34 tok/s, `ollama ps`의 모델 배치는 GPU 100%였습니다. 로그에는 약 1분 20초짜리 요청 3개가 함께 끝난 기록이 있었습니다. Open WebUI는 본 답변 외에 제목·태그·후속 질문 요청도 보내는데 `OLLAMA_NUM_PARALLEL`이 1이었기 때문에, 요청이 줄을 선다고 의심했습니다.

값을 2로, `OLLAMA_CONTEXT_LENGTH`를 4K에서 16K로 **같은 때** 바꾼 뒤 제목 요청은 0.4초에 끝났고 본 답변 속도는 유지됐습니다. 두 설정을 함께 바꿔서 각각의 효과는 분리하지 못했습니다. 분리하려면 같은 입력으로 하나씩 바꿔 재야 합니다. 필요한 메모리는 두 값의 곱에 비례해 늘어나므로 바꾼 뒤 `ollama ps`를 다시 봅니다.

**폴더를 옮겨도 데이터가 남은 경우.** compose 파일을 `C:\Dev\server`에서 `D:\Dev\server`로 옮겨도 계정이 그대로였습니다. 같은 엔진에서 기본 프로젝트 이름이 폴더 이름 `server`로 유지되어 같은 볼륨 `server_webui-data`를 찾았기 때문입니다. 임시 프로젝트에서도 폴더 이름을 바꾸면 새 빈 볼륨이 생겼습니다. 옮기기 전에 `docker compose ls`와 `docker volume ls`로 이름을 확인합니다. 최상위 `name:`으로 고정할 수 있지만 `-p`와 `COMPOSE_PROJECT_NAME`이 더 우선합니다.

**빈 `C:\Dev`가 지워지지 않은 경우.** 처음엔 VS Code를 의심했지만 Ollama 프로세스의 작업 폴더가 그곳이었습니다. 파일이 없어도 프로세스가 작업 폴더로 쓰면 지울 수 없으므로, Ollama를 끄고 폴더를 지운 뒤 다른 위치에서 다시 시작하면 됩니다.

## 시리즈 정리와 점검표

| 편 | 기억할 한 가지 |
|---|---|
| 1. 이미지와 컨테이너 | 이미지는 실행 재료, 컨테이너는 거기서 만든 실행 단위 |
| 2. WSL2와 Docker Desktop | 이 글의 Docker Desktop WSL 2 환경에서 명령은 WSL2 안의 Linux 엔진으로 전달됨 |
| 3. 파일 위치 | 이 환경의 이미지와 볼륨은 낱개 파일이 아니라 vhdx 안에 있음 |
| 4. compose 파일 | 실행 설정을 파일에 적어 다시 만들 수 있게 함 |
| 5. Ollama 연결 | 컨테이너의 `localhost`는 컨테이너 자신 |
| 6. 운영과 문제 해결 | 컨테이너는 다시 만들 수 있고, 지켜야 할 것은 볼륨 |

**삭제·업데이트 전**

- [ ] `docker context show`와 `docker compose ls`로 지금 보는 엔진과 프로젝트가 맞는가?
- [ ] 지워질 컨테이너·이미지·볼륨과 그 안의 데이터를 이름으로 확인했는가?
- [ ] 백업이 "백업 완료"로 끝났고, 새 볼륨에 풀어 로그인과 데이터를 확인했는가?

**업데이트 후**

- [ ] `pull` 성공 뒤 `up -d`를 실행했고 다시 `healthy`인가?
- [ ] 로그인, 기존 대화, Ollama 모델 목록이 보이는가?

## 참고 문서

- Docker: [compose down](https://docs.docker.com/reference/cli/docker/compose/down/), [compose up](https://docs.docker.com/reference/cli/docker/compose/up/), [container stop](https://docs.docker.com/reference/cli/docker/container/stop/), [image prune](https://docs.docker.com/reference/cli/docker/image/prune/), [system prune](https://docs.docker.com/reference/cli/docker/system/prune/), [volume prune](https://docs.docker.com/reference/cli/docker/volume/prune/)
- Docker: [Volumes](https://docs.docker.com/engine/storage/volumes/), [restart 정책](https://docs.docker.com/engine/containers/start-containers-automatically/), [Compose 프로젝트 이름](https://docs.docker.com/compose/how-tos/project-name/), [Docker Desktop 설정](https://docs.docker.com/desktop/settings-and-maintenance/settings/)
- Open WebUI: [Updating](https://docs.openwebui.com/getting-started/updating/), [Quick Start](https://docs.openwebui.com/getting-started/quick-start/)
- Ollama: [FAQ](https://docs.ollama.com/faq) · SQLite: [How To Corrupt](https://www.sqlite.org/howtocorrupt.html), [integrity_check](https://www.sqlite.org/pragma.html#pragma_integrity_check) · Microsoft: [Task Manager의 GPU](https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/)
