---
title: "Docker 파일은 어디에 생길까: 이미지·컨테이너·볼륨의 실제 위치"
date: 2026-11-18 19:10:00 +0900
categories: [개발 도구, Docker]
tags: [docker, windows, wsl2, docker-desktop, docker-volume, vhdx]
description: "Windows의 Docker Desktop에서 compose 파일, 설정, 로그, vhdx, 이미지, 볼륨, 컨테이너 데이터가 실제로 어디에 생기는지 Open WebUI 예제로 확인합니다. 지워도 남는 것과 저장 위치를 바꿀 때의 주의점도 정리합니다."
---

> **시리즈: Windows에서 Docker 처음 배우기**
> 1. Docker란 무엇인가: 이미지와 컨테이너 (예정)
> 2. Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop (예정)
> 3. **무엇이 어느 폴더에 생기나: 이미지·컨테이너·볼륨의 실제 위치** ← 지금 글
> 4. docker-compose.yml 한 줄씩 읽기: Open WebUI 띄우기 (예정)
> 5. 컨테이너에서 Windows의 Ollama 연결하기: localhost와 host.docker.internal (예정)
> 6. Docker 운영과 문제 해결: 로그, 업데이트, 데이터 지키기 (예정)

Open WebUI를 Docker로 띄우고 나면 이상한 점이 하나 생깁니다. 내려받은 이미지는 6GB가 넘고 채팅 기록도 쌓이는데, compose 파일이 있는 폴더를 열어 보면 파일이 `docker-compose.yml` 하나뿐입니다. `docker volume inspect`가 알려 주는 `/var/lib/docker/volumes/...` 경로는 탐색기에 붙여 넣어도 열리지 않습니다.

데이터는 어디에 있고, 무엇을 지우면 사라질까요? 이 글은 Windows Docker Desktop의 WSL 2 백엔드에서 로컬 Linux 엔진을 쓴 예입니다. Windows에서 도는 Ollama와 Docker 컨테이너로 띄운 Open WebUI를 예제로, 실제 PC에서 위치를 하나씩 확인합니다. 먼저 쓰이는 말 세 가지만 짚고 가겠습니다.

- **이미지**: 프로그램과 실행에 필요한 파일을 묶은 읽기 전용 틀입니다.
- **컨테이너**: 이미지로 실행한 격리된 프로그램입니다.
- **볼륨**: 컨테이너와 따로 Docker가 관리하는 데이터 저장 공간입니다.

## 결론부터: 경로는 세 세계로 나뉜다

이 WSL 2 예에서는 파일 경로가 세 종류로 나뉩니다.

1. **Windows 경로**: `D:\...`나 `C:\Users\...`처럼 탐색기에서 바로 보입니다.
2. **Docker용 Linux 경로**: `/var/lib/docker/...`처럼 Docker 엔진이 보는 경로입니다. 실제 내용은 Windows의 가상 디스크 파일(`.vhdx`) 안에 있습니다.
3. **컨테이너 안 경로**: `/app/backend/data`처럼 그 컨테이너 안에서 보이는 경로입니다.

<figure class="diagram">
{% include figures/docker-where-files-live/where-map.svg %}
<figcaption>이 WSL 2 예에서 Docker 데이터는 탐색기에 vhdx 파일로 보이고, 컨테이너는 그 안의 볼륨을 연결해 씁니다</figcaption>
</figure>

## 무엇이 어디에 있나

제 PC는 Docker Desktop의 디스크 위치를 `D:\docker`로 바꿔 두었습니다. 아래 표는 이 PC의 관측 예이고, 버전과 설정에 따라 경로가 다를 수 있습니다.

| 무엇 | 위치 (이 PC의 관측 예) | 어디서 보이나 | 들어 있는 것 |
|---|---|---|---|
| compose 파일 | `D:\Dev\server\docker-compose.yml` | Windows | 컨테이너 실행 설정. 이 폴더에 데이터는 없습니다 |
| Docker CLI 설정 | `C:\Users\<사용자>\.docker` | Windows | `config.json`, `contexts`, `cli-plugins` 등 |
| Docker Desktop 설정 | `%APPDATA%\Docker\settings-store.json` | Windows | Docker Desktop 앱의 설정 |
| Docker Desktop 로그·상태 | `%LOCALAPPDATA%\Docker` | Windows | `log`, `wsl`, `install-log.txt` 등 |
| Docker 데이터 디스크 | `D:\docker\DockerDesktopWSL\disk\docker_data.vhdx` | Windows에서는 파일 하나 | 이미지, 컨테이너, 볼륨이 담긴 가상 디스크 |
| Docker Desktop 시스템 디스크 | `D:\docker\DockerDesktopWSL\main\ext4.vhdx` | Windows에서는 파일 하나 | 같은 폴더 아래에 있는 또 하나의 가상 디스크 |
| Docker 엔진 데이터 | `/var/lib/docker` | Docker의 Linux 안 | 볼륨, 컨테이너 관련 데이터 |
| 볼륨의 실제 위치 | `/var/lib/docker/volumes/server_webui-data/_data` | Docker의 Linux 안 | `webui.db`, `uploads/`, `vector_db/` 등 |
| 컨테이너가 보는 위치 | `/app/backend/data` | 컨테이너 안 | 위 볼륨과 같은 내용 |
| Ollama 모델 | `D:\ollama\models` | Windows | 모델 파일. 컨테이너와 vhdx 밖에 있습니다 |

`docker_data.vhdx`의 기본 위치는 `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`입니다. Docker 공식 백업 문서도 Docker Desktop이 시작되지 않을 때 보존할 파일로 이 경로를 듭니다.

Ollama는 이 예제에서 컨테이너가 아니라 Windows 프로그램입니다. 모델의 기본 위치는 `C:\Users\<사용자>\.ollama\models`이고, `OLLAMA_MODELS` 환경 변수로 바꿀 수 있습니다. 그래서 Open WebUI 컨테이너를 지워도 모델은 그대로 있고, `docker system df`의 용량에도 잡히지 않습니다.

## 왜 탐색기에서 이미지 파일이 안 보일까

Docker Desktop의 WSL 2 방식에서 Docker 엔진은 Windows와 분리된 `docker-desktop` Linux 환경에서 돕니다. WSL 2의 Linux 파일은 ext4 파일 시스템을 담은 가상 디스크, 즉 `.vhdx` 파일 안에 저장됩니다. Windows 입장에서는 커다란 파일 하나이고, 그 안의 폴더 구조는 Linux가 디스크를 연결했을 때 보입니다.

그래서 `D:\docker`를 아무리 뒤져도 `webui.db`나 이미지 층이 낱개 파일로 나오지 않습니다. 볼륨 정보를 먼저 보겠습니다.

```powershell
docker volume inspect server_webui-data
```

**확인할 것**: `Mountpoint`와 Compose 라벨입니다.

**정상 결과** (일부):

```json
{
    "Driver": "local",
    "Labels": {
        "com.docker.compose.project": "server",
        "com.docker.compose.volume": "webui-data"
    },
    "Mountpoint": "/var/lib/docker/volumes/server_webui-data/_data",
    "Name": "server_webui-data"
}
```

여기서 `Mountpoint`는 Windows 경로가 아니라 **Docker 엔진이 보는 Linux 경로**입니다. PowerShell에서 확인하면 없다고 나옵니다.

```powershell
Test-Path /var/lib/docker/volumes/server_webui-data/_data
```

```text
False
```

`False`는 볼륨이 없다는 뜻이 아니라, 그 경로가 Windows 쪽에 없다는 뜻입니다. Docker 문서도 볼륨 데이터는 Docker가 관리하며 직접 건드리는 동작은 보장되지 않는다고 설명합니다. 내용을 보고 싶으면 뒤에 나오는 임시 컨테이너를 씁니다.

볼륨 이름의 `server_`는 compose 파일이 있는 폴더 이름에서 왔습니다. 프로젝트 이름을 따로 지정하지 않았을 때의 기본값입니다. compose 파일에는 `webui-data`라고만 적었고, Compose가 프로젝트 이름 `server`를 앞에 붙였습니다.

```yaml
services:
  open-webui:
    volumes:
      - webui-data:/app/backend/data

volumes:
  webui-data:
```

이 때문에 compose 폴더를 옮길 때는 폴더 이름에 주의해야 합니다. 저는 폴더를 `C:\Dev\server`에서 `D:\Dev\server`로 옮겼는데, 이름이 같아서 프로젝트 이름과 볼륨이 유지됐고 계정과 데이터도 그대로였습니다. 옮긴 뒤 앱이 초기 화면으로 돌아오면 새 계정을 만들기 전에 `docker volume ls`로 기존 볼륨부터 확인합니다.

### 이미지는 `/var/lib/docker`에 다 있을까

오래된 글에는 이미지가 `/var/lib/docker/overlay2`에 있다고 나오는 경우가 많습니다. 제 환경은 조금 달랐습니다. Docker Desktop은 기본으로 containerd image store를 쓰고, 이 PC의 저장 드라이버도 `overlayfs`였습니다.

{% raw %}
```powershell
docker info --format "{{.DockerRootDir}} {{.Driver}}"
```
{% endraw %}

```text
/var/lib/docker overlayfs
```

Docker 엔진의 `/var/lib`를 읽기 전용으로 잠깐 연결해 보면 `docker`와 나란히 `desktop-containerd`가 있습니다.

```powershell
docker run --rm -v /var/lib:/hostvar:ro ubuntu:22.04 ls /hostvar
```

```text
cni
containerd
desktop-containerd
docker
...
```

제 PC에서 이미지 층은 `/var/lib/desktop-containerd` 아래에 있었고, 볼륨은 `/var/lib/docker/volumes` 아래에 있었습니다. 이 구조는 Docker 내부 구현이라 버전과 설정에 따라 달라질 수 있습니다. 외울 것은 정확한 내부 폴더가 아니라 **이미지와 볼륨이 모두 vhdx 안의 Linux 디스크에 있다**는 점입니다.

## 쓰기 계층과 볼륨은 다르다

컨테이너 안에서 파일을 쓸 때 어디에 저장되는지는 경로에 따라 달라집니다.

- **볼륨이 연결된 경로**에 쓰면 볼륨에 저장됩니다. 이 예제의 `/app/backend/data`가 그렇습니다.
- **다른 마운트가 없는 경로**에 쓰면 컨테이너마다 하나씩 있는 **쓰기 계층**에 저장됩니다. 쓰기 계층의 데이터는 컨테이너가 삭제되면 함께 사라집니다.

<figure class="diagram">
{% include figures/docker-where-files-live/after-rm.svg %}
<figcaption>컨테이너를 지우면 쓰기 계층만 사라지고, 이미지와 이름 있는 볼륨은 남습니다</figcaption>
</figure>

운영 중인 데이터로 시험하면 위험하니 임시 볼륨과 임시 컨테이너로 확인해 보겠습니다. 아래 명령은 한 PowerShell 창에서 이어서 실행하고, 처음 실행하면 `ubuntu:22.04` 이미지를 내려받습니다. 이름에는 실행마다 다른 접미사를 붙이고, 생성이 실패하면 다음 단계로 넘어가지 않습니다.

```powershell
$id = Get-Random -Maximum 100000000
$vol = "blogdemo-files-vol-$id"
$ctr = "blogdemo-files-c-$id"
docker volume create $vol
$ok = $LASTEXITCODE -eq 0
if ($ok) { docker run -d --name $ctr -v "${vol}:/data" ubuntu:22.04 sleep 600; $ok = $LASTEXITCODE -eq 0 }
if ($ok) { docker exec $ctr sh -c "echo volume > /data/keep.txt; echo layer > /root/gone.txt"; docker diff $ctr } else { "생성 실패: 여기서 멈춥니다" }
```

**확인할 것**: `docker diff`는 컨테이너의 쓰기 계층에서 바뀐 항목을 보여 줍니다.

**정상 결과**:

```text
C /root
A /root/gone.txt
A /data
```

`/root/gone.txt`는 쓰기 계층에 추가됐습니다. `/data/keep.txt`는 목록에 없습니다. 볼륨에 저장됐기 때문입니다. `/data`는 볼륨을 연결할 자리로 생긴 폴더입니다.

이제 컨테이너를 지우고, 같은 볼륨을 **읽기 전용**(`:ro`)으로 연결한 새 임시 컨테이너에서 확인합니다.

```powershell
if ($ok) { docker rm -f $ctr; docker run --rm -v "${vol}:/data:ro" ubuntu:22.04 sh -c "ls /data; cat /data/keep.txt; ls /root/gone.txt; echo x > /data/new.txt" }
```

**정상 결과**:

```text
keep.txt
volume
ls: cannot access '/root/gone.txt': No such file or directory
sh: 1: cannot create /data/new.txt: Read-only file system
```

볼륨의 `keep.txt`는 남았고, 쓰기 계층의 `gone.txt`는 사라졌습니다. 읽기 전용으로 연결했기 때문에 새 파일도 만들 수 없습니다. 끝나면 이번에 만든 자원만 이름으로 지정해 지웁니다. 중간에 실패했을 때도 같은 명령을 씁니다.

```powershell
docker rm -f $ctr 2>$null
docker volume rm $vol
```

참고로 `docker stop` 뒤 `docker start`로 같은 컨테이너를 다시 켜면 `gone.txt`도 남아 있습니다. 쓰기 계층은 컨테이너를 멈출 때가 아니라 **삭제할 때** 사라집니다.

## 무엇을 하면 무엇이 사라지나

| 명령 | 컨테이너와 쓰기 계층 | 이미지 | 이 예제의 Compose 관리 볼륨 |
|---|---|---|---|
| `docker stop` | 남음 | 남음 | 남음 |
| `docker compose stop` | 남음 | 남음 | 남음 |
| `docker rm` | **삭제** | 남음 | 남음 |
| `docker rm -v` | **삭제** | 남음 | 남음 (익명 볼륨만 삭제) |
| `docker compose down` | **삭제** | 남음 | 남음 |
| `docker compose down -v` | **삭제** | 남음 | **삭제** |
| `docker volume rm <이름>` | 해당 없음 | 남음 | **삭제** |

표에서 가장 조심할 것은 `docker compose down -v`입니다. compose 파일의 `volumes`에 적은 이름 있는 볼륨까지 지웁니다. 이 예제에서는 `server_webui-data`, 즉 Open WebUI의 계정과 채팅 데이터가 사라집니다. `external`로 선언한 볼륨과 바인드 마운트의 호스트 파일은 `-v`로도 지워지지 않습니다. `-v` 없는 `down`도 컨테이너와 쓰기 계층은 지우니, 앱만 멈출 때는 `docker compose stop`을 씁니다. `-v`는 데이터를 버려도 될 때만 붙입니다.

## 위치와 용량을 확인하는 명령

아래는 모두 읽기만 하는 명령입니다.

### 전체 용량: `docker system df`

```powershell
docker system df
```

**확인할 것**: 이미지, 컨테이너, 볼륨이 각각 얼마나 쓰는지입니다.

제 PC에서 `ubuntu:22.04`까지 받아 둔 상태의 값은 다음과 같았습니다.

| 종류 | 크기 | 설명 |
|---|---|---|
| Images | 6.577GB | Open WebUI 이미지 6.46GB와 `ubuntu:22.04` 120MB |
| Containers | 55.6MB | 컨테이너의 쓰기 계층 |
| Local Volumes | 1.119GB | Open WebUI 데이터 볼륨 |

이때 `docker_data.vhdx`는 약 9.5GB였습니다. 위 세 값의 합과 vhdx 파일 크기는 같은 숫자가 아니니, 용량을 볼 때는 둘을 따로 확인합니다.

### 볼륨 목록과 위치

```powershell
docker volume ls
docker volume inspect server_webui-data
```

**정상 결과**: 목록에 `server_webui-data`가 있고, `Mountpoint`가 `/var/lib/docker/volumes/server_webui-data/_data`입니다.

### 컨테이너에 무엇이 연결됐는지

{% raw %}
```powershell
docker inspect open-webui --format "{{json .Mounts}}"
```
{% endraw %}

**정상 결과** (일부, 보기 좋게 줄바꿈):

```json
[{
  "Type": "volume",
  "Name": "server_webui-data",
  "Source": "/var/lib/docker/volumes/server_webui-data/_data",
  "Destination": "/app/backend/data",
  "RW": true
}]
```

`Source`는 Docker 쪽 위치, `Destination`은 컨테이너 안 위치입니다. 이 줄이 두 경로가 같은 데이터라는 증거입니다.

### 볼륨 내용을 읽기 전용으로 보기

`-v`에 없는 볼륨 이름을 주면 Docker가 빈 볼륨을 새로 만듭니다. 그래서 `docker volume inspect`로 이름이 맞는 것을 확인한 경우에만 임시 컨테이너를 띄웁니다.

```powershell
docker volume inspect server_webui-data > $null
if ($LASTEXITCODE -eq 0) { docker run --rm --network none -v server_webui-data:/data:ro ubuntu:22.04 sh -c "ls -1 /data; du -sh /data" }
```

**확인할 것**: 실행 중인 컨테이너를 건드리지 않고 볼륨에 무엇이 있는지 봅니다. `:ro`라서 이 임시 컨테이너는 볼륨을 바꿀 수 없고, `--rm`이라 끝나면 임시 컨테이너도 지워집니다. 목록과 용량은 그 순간의 관측일 뿐이고, 앱이 쓰는 중인 DB를 이렇게 본다고 백업이 되지는 않습니다.

**정상 결과**:

```text
cache
uploads
vector_db
webui.db
webui.db-shm
webui.db-wal
1.1G	/data
```

## 저장 위치를 바꾸고 싶을 때

C 드라이브가 부족하면 Docker Desktop 설정에서 디스크 이미지 위치를 바꿉니다. 제 PC에서는 **Settings → Resources → Advanced → Disk image location**에서 `D:\docker`를 지정했고, 그 결과 vhdx가 `D:\docker\DockerDesktopWSL` 아래에 생겼습니다. 메뉴 이름과 확인 창은 버전마다 다를 수 있으니 지금 쓰는 버전의 설정 화면을 확인합니다.

바꾸기 전후에 다음을 확인합니다.

1. Docker Desktop을 완전히 끄고 지켜야 할 데이터를 먼저 백업합니다.
2. 옮길 드라이브에 vhdx를 담을 여유 공간이 있는지 봅니다.
3. 대상 폴더는 기존 디스크 이미지가 없는 빈 폴더로 고릅니다. 이미 이미지가 있으면 기존 것을 쓸지 교체할지 묻는 창이 뜰 수 있습니다.
4. 끝나면 `docker images`, `docker volume ls`로 이미지와 볼륨이 그대로인지 봅니다.
5. 앱을 열어 데이터까지 보이는지 확인합니다.

이때 **vhdx 파일을 탐색기에서 직접 옮기거나 지우지 마세요.** `docker_data.vhdx`에는 이미지뿐 아니라 볼륨도 들어 있습니다. 이 파일을 지우는 것은 Open WebUI 데이터까지 지우는 일이 될 수 있습니다. Microsoft도 WSL 관련 파일을 Windows 도구로 수정하거나 옮기면 배포판이 손상될 수 있다고 안내합니다. Docker 문서에서 vhdx 파일을 백업할 때도 Docker Desktop을 완전히 끈 뒤에 하라고 합니다.

Docker Desktop을 제거하는 것도 조심해야 합니다. 공식 문서는 제거할 때 그 PC의 컨테이너, 이미지, 볼륨 같은 Docker 데이터가 삭제된다고 경고합니다. 지켜야 할 볼륨이 있으면 먼저 백업합니다. 백업과 복구 절차는 6편에서 다룹니다.

## 정리

- `docker-compose.yml`, `.docker` 설정, Docker Desktop 로그, Ollama 모델은 **Windows 파일**입니다.
- 이 WSL 2 예에서 이미지와 볼륨은 **vhdx 안의 Linux 디스크**에 있어서 탐색기에서 낱개 파일로 보이지 않습니다.
- `Mountpoint`는 Windows 경로가 아니라 **Docker 쪽 Linux 경로**입니다.
- 컨테이너의 `/app/backend/data`는 볼륨을 **컨테이너 안에서 본 경로**입니다.
- 컨테이너를 지우면 쓰기 계층은 사라지지만 이름 있는 볼륨은 남습니다. `docker compose down -v`는 볼륨까지 지웁니다.
- 저장 위치는 Docker Desktop 설정에서 바꾸고, vhdx 파일을 직접 옮기거나 지우지 않습니다.

다음 편에서는 이 구성을 만든 `docker-compose.yml`을 한 줄씩 읽어 봅니다.

## 참고 자료

- [Docker: Storage](https://docs.docker.com/engine/storage/)
- [Docker: Volumes](https://docs.docker.com/engine/storage/volumes/)
- [Docker Desktop: containerd image store](https://docs.docker.com/desktop/features/containerd/)
- [Docker Desktop: WSL 2 backend](https://docs.docker.com/desktop/features/wsl/)
- [Docker Desktop: Back up and restore data](https://docs.docker.com/desktop/settings-and-maintenance/backup-and-restore/)
- [Docker Desktop: Uninstall](https://docs.docker.com/desktop/uninstall/)
- [Docker CLI: docker compose down](https://docs.docker.com/reference/cli/docker/compose/down/)
- [Docker CLI: docker container rm](https://docs.docker.com/reference/cli/docker/container/rm/)
- [Microsoft: How to manage WSL disk space](https://learn.microsoft.com/en-us/windows/wsl/disk-space)
- [Ollama FAQ](https://docs.ollama.com/faq)
