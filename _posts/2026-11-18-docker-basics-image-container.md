---
title: "Docker 처음 배우기: 이미지와 컨테이너, 가상환경·VM과 무엇이 다를까"
date: 2026-11-18 19:00:00 +0900
categories: [개발 도구, Docker]
tags: [docker, windows, container, wsl2, open-webui]
description: "Windows에서 Open WebUI를 띄워 놓고도 무엇이 어디서 도는지 모르겠다면 읽어 보세요. 이미지, 컨테이너, 레지스트리, 태그, 레이어를 작은 실습으로 확인하고 Python 가상환경, WSL2, VM과의 차이를 정리합니다."
---

> **시리즈: Windows에서 Docker 처음 배우기**
> 1. **Docker란 무엇인가: 이미지와 컨테이너** ← 지금 글
> 2. [Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop]({% post_url 2026-11-18-docker-windows-wsl2-structure %})
> 3. 무엇이 어느 폴더에 생기나: 이미지·컨테이너·볼륨의 실제 위치 (예정)
> 4. docker-compose.yml 한 줄씩 읽기: Open WebUI 띄우기 (예정)
> 5. 컨테이너에서 Windows의 Ollama 연결하기: localhost와 host.docker.internal (예정)
> 6. Docker 운영과 문제 해결: 로그, 업데이트, 데이터 지키기 (예정)

Windows PC에 WSL, Docker Desktop, Ollama, Open WebUI를 안내대로 설치했습니다. 브라우저에서 `http://localhost:3000`을 열면 채팅 화면이 뜨고 답도 돌아옵니다. 그런데 막상 "Open WebUI는 지금 어디서 돌고 있나요?"라는 질문을 받으면 답하기 어렵습니다. Windows 프로그램일까요, WSL 안일까요? 컨테이너를 지우면 대화 기록도 사라질까요? 설치 중에 본 "가상환경", "가상 머신", "컨테이너"는 같은 말일까요?

이 글은 그 질문의 출발점인 **이미지와 컨테이너**를 다룹니다. 개념을 먼저 짧게 설명하고, 작은 이미지로 직접 만들고 지워 본 뒤, 같은 눈으로 실제 Open WebUI를 읽습니다. 결론부터 적으면 이렇습니다.

- **이미지**는 프로그램과 실행에 필요한 파일을 묶은 읽기 전용 틀입니다.
- **컨테이너**는 그 틀로 만든 격리된 실행 단위입니다. 멈춘 뒤에도 지우기 전까지 남습니다.
- 이미지 하나로 컨테이너를 여러 개 만들 수 있고, 컨테이너를 지워도 이미지는 남습니다.
- Python 가상환경, WSL2, 가상 머신, 컨테이너는 모두 "나눈다"는 말을 쓰지만 나누는 범위가 다릅니다.

이 글은 Linux 컨테이너를 기준으로 하며, 명령은 Windows PowerShell과 Docker 29.9.3에서 실행한 결과입니다.

## Docker가 푸는 문제

프로그램은 코드만으로 돌지 않습니다. 특정 버전의 언어 런타임, 라이브러리, 설정 파일, 때로는 특정 Linux 배포판의 도구까지 필요합니다. 이것을 PC마다 손으로 맞추면 "내 PC에서는 되는데"가 시작됩니다.

Docker는 **프로그램과 실행 환경을 이미지로 묶어, 호환되는 Docker 실행 환경에서 같은 방식으로 실행**하게 합니다. Open WebUI를 예로 들면, Python이나 필요한 패키지를 Windows에 직접 설치하지 않았습니다. 이미 묶여 있는 것을 받아서 실행했을 뿐입니다.

이 흐름에 등장하는 이름은 셋입니다.

| 이름 | 쉬운 말 | Open WebUI에서는 |
|---|---|---|
| 레지스트리 | 이미지 저장소를 모아 제공하는 서비스 | `ghcr.io` |
| 이미지 | 읽기 전용 틀 | `ghcr.io/open-webui/open-webui:main` |
| 컨테이너 | 격리된 실행 단위 | `open-webui` |

<figure class="diagram">
{% include figures/docker-basics-image-container/image-to-containers.svg %}
<figcaption>같은 이미지로 만든 A와 B는 쓰기 레이어를 따로 씁니다. docker rm으로 지우면 그 쓰기 레이어도 사라지고 이미지는 남습니다.</figcaption>
</figure>

## 이미지: 실행에 필요한 것을 묶은 읽기 전용 틀

이미지에는 프로그램을 실행하는 데 필요한 파일, 실행 파일, 라이브러리, 설정이 들어 있습니다. 중요한 성질은 **한 번 만들어지면 바뀌지 않는다**는 점입니다. 내용을 바꾸고 싶으면 기존 이미지를 고치는 것이 아니라 새 이미지를 만듭니다.

### 레이어: 이미지는 변경 묶음을 쌓은 것

이미지는 통짜 파일 하나가 아니라 **레이어**를 쌓은 구조입니다. 레이어 하나는 "이 파일을 추가했다, 수정했다, 지웠다" 같은 파일 변경 묶음입니다. 이미지끼리 같은 레이어를 재사용할 수 있어서, 공통 부분을 매번 새로 저장하지 않아도 됩니다.

### 태그와 이미지 이름 읽기

태그로 이미지를 부를 때 이름은 정해진 형식을 따릅니다. 앞부분을 생략하면 기본값이 채워집니다.

```text
[레지스트리/][네임스페이스/]저장소[:태그]
```

| 내가 쓴 이름 | 레지스트리 | 네임스페이스 | 저장소 | 태그 |
|---|---|---|---|---|
| `alpine:3.20` | `docker.io` (기본값) | `library` (기본값) | `alpine` | `3.20` |
| `ghcr.io/open-webui/open-webui:main` | `ghcr.io` | `open-webui` | `open-webui` | `main` |

`docker.io`는 Docker Hub이고, `ghcr.io`는 GitHub의 컨테이너 레지스트리입니다. 저장소는 레지스트리 안에서 관련 이미지를 묶은 단위입니다. 태그를 아예 쓰지 않으면 `latest`로 처리되는데, `latest`도 자동으로 최신을 고르는 기능이 아니라 이름표 하나입니다.

**태그**는 이미지에 붙인 이름표입니다. 이미지 자체는 바뀌지 않지만, `main` 같은 태그가 가리키는 이미지는 시간이 지나면 달라질 수 있습니다. 그래서 같은 태그를 다시 `docker pull`하면 더 새로운 이미지를 받을 수 있습니다. 정확히 같은 이미지를 고정하고 싶을 때는 태그 대신 digest라는 고유 식별값으로 받습니다.

## 컨테이너: 이미지로 만든 격리된 실행 단위

컨테이너는 작은 컴퓨터라기보다 **격리된 실행 단위**에 가깝습니다. 실행 중에는 그 안에서 프로세스가 돌고, 멈춘 뒤에도 지우기 전까지 남습니다. 기본 설정에서는 컨테이너 안의 프로세스가 다른 컨테이너의 프로세스를 보거나 건드릴 수 없고, 컨테이너마다 자기 네트워크 스택을 가집니다. 실행 옵션으로 이 범위를 바꿀 수도 있습니다.

이미지는 읽기 전용인데 컨테이너 안에서는 파일을 만들 수 있습니다. 컨테이너를 만들 때 이미지 위에 **쓰기 레이어**가 한 장 얹히기 때문입니다. 볼륨 같은 별도 저장 공간에 연결하지 않은 경로의 변경은 여기에 쌓이고, 이미지는 그대로입니다. 그래서 컨테이너 여러 개가 같은 이미지를 함께 쓰면서도 각자 다른 상태를 가질 수 있습니다.

컨테이너를 지우면 쓰기 레이어도 함께 지워집니다. 지워지면 안 되는 데이터를 **볼륨**에 두는 이유가 이것입니다. 볼륨의 내용은 컨테이너 수명과 따로 유지되고, 같은 볼륨을 연결한 컨테이너끼리는 그 안의 파일을 함께 볼 수 있습니다.

## 직접 해 보기: 이미지 하나로 컨테이너 두 개 만들기

아주 작은 Linux 이미지인 `alpine:3.20`으로 실습합니다. 컨테이너 이름은 `docker-demo-a`, `docker-demo-b`로 정해서 다른 컨테이너와 섞이지 않게 합니다.

> 이 실습은 `open-webui` 컨테이너를 건드리지 않습니다. 삭제 연습을 실제 서비스 컨테이너에 하지 마세요.
{: .prompt-warning }

### 1. 시작 전 확인

Docker Desktop이 시작을 마친 뒤 PowerShell에서 실행합니다.

{% raw %}
```powershell
docker context ls
docker version --format "client {{.Client.Version}} / server {{.Server.Version}} ({{.Server.Os}})"
docker ps -a --filter "name=docker-demo" --format "table {{.Names}}\t{{.Status}}"
docker images --filter "reference=alpine:3.20" --filter "reference=ubuntu:22.04" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
```
{% endraw %}

**확인할 것:** 명령이 어느 Docker 엔진으로 가는지, 실습 이름이 비어 있는지, 실습 이미지가 이미 있는지 봅니다.

```text
NAME              DESCRIPTION                               DOCKER ENDPOINT                             ERROR
default           Current DOCKER_HOST based configuration   npipe:////./pipe/docker_engine
desktop-linux *   Docker Desktop                            npipe:////./pipe/dockerDesktopLinuxEngine

client 29.9.3 / server 29.9.3 (linux)

NAMES     STATUS

REPOSITORY   TAG       SIZE
ubuntu       22.04     120MB
```

**정상 결과:**

- `*`가 `desktop-linux`에 붙어 있으면 로컬 Docker Desktop의 Linux 엔진입니다. 다른 곳에 붙어 있으면 어떤 엔진인지 확인하기 전에는 진행하지 않습니다.
- 둘째 결과 끝에 `linux`가 보입니다. `windows`이면 Docker Desktop이 Linux 컨테이너 모드인지 확인하고, 서버 오류가 나면 Docker Desktop이 켜져 있는지 봅니다.
- 이름 목록은 비어 있어야 합니다. `name=` 필터는 이름의 일부만 같아도 잡습니다. 무엇이든 나오면 그 컨테이너는 건드리지 말고 겹치지 않는 새 공통 접두어를 정합니다. 예를 들어 `dockerlab7-a`, `dockerlab7-b`로 정했다면 이후 `docker run`, `docker diff`, `docker rm`의 이름과 `name=` 필터 값을 모두 바꾸고, 바꾼 필터(`name=dockerlab7`)로 이름이 비어 있는지 다시 확인합니다.
- 마지막 표에 **없는** 이미지를 기억해 둡니다. 위 예시에서는 `alpine:3.20`이 없고 `ubuntu:22.04`는 원래 있습니다. 정리할 때 이 기록을 씁니다.

### 2. 이미지 받기

1번 표에 `alpine:3.20`이 없을 때만 받습니다. 이미 있으면 다시 받지 말고 그대로 씁니다. 다시 받으면 같은 태그가 다른 이미지를 가리키게 될 수 있습니다.

```powershell
docker pull alpine:3.20
```

이미지가 있는지는 어느 경우든 확인합니다.

{% raw %}
```powershell
docker images alpine:3.20 --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
```
{% endraw %}

**확인할 것:** `alpine:3.20`이 내 Docker에 있는지 봅니다.

```text
REPOSITORY   TAG       SIZE
alpine       3.20      12.2MB
```

**정상 결과:** `alpine`, `3.20` 줄이 하나 보입니다. 새로 받았다면 `docker pull`의 마지막 줄에 `docker.io/library/alpine:3.20`이 찍힙니다. 앞에서 본 생략된 기본값이 실제로 채워진 것입니다. 크기는 환경에 따라 다를 수 있습니다. `docker pull`이 실패했다면 다음 단계로 가지 말고 네트워크를 확인한 뒤 다시 받습니다.

### 3. 같은 이미지로 컨테이너 두 개 실행

A에서는 파일을 만들고, B에서는 그 파일을 읽어 봅니다.

```powershell
docker run --name docker-demo-a alpine:3.20 sh -c "echo hello > /tmp/note.txt; cat /tmp/note.txt"
docker run --name docker-demo-b alpine:3.20 cat /tmp/note.txt
```

**확인할 것:** 같은 이미지에서 나왔어도 파일이 공유되지 않는지 봅니다.

```text
hello
cat: can't open '/tmp/note.txt': No such file or directory
```

**정상 결과:** 첫 줄은 A의 출력이고, 둘째 줄은 B의 오류입니다. 이 파일 없음 오류가 이번 실습에서 보려던 결과입니다. `/tmp`는 볼륨에 연결하지 않았으므로 A가 만든 파일은 A의 쓰기 레이어에만 있습니다. 이름 충돌이나 다운로드 오류가 나왔다면 1번과 2번으로 돌아갑니다.

`docker run`은 새 컨테이너를 만들고 시작하며, 이미지가 없으면 먼저 받습니다. 그래서 2번을 건너뛰어도 동작합니다. `--name`은 컨테이너에 이름을 붙이는 옵션입니다.

### 4. 컨테이너 상태와 쓰기 레이어 보기

{% raw %}
```powershell
docker ps --filter "name=docker-demo" --format "table {{.Names}}\t{{.Status}}"
docker ps -a --filter "name=docker-demo" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
docker diff docker-demo-a
docker diff docker-demo-b
```
{% endraw %}

**확인할 것:** 실행 중인 컨테이너와 멈춘 컨테이너를 구분하고, 각 컨테이너가 이미지에서 무엇을 바꿨는지 봅니다.

```text
NAMES     STATUS

NAMES           IMAGE         STATUS
docker-demo-b   alpine:3.20   Exited (1) Less than a second ago
docker-demo-a   alpine:3.20   Exited (0) Less than a second ago

C /tmp
A /tmp/note.txt
```

**정상 결과:**

- `docker ps`는 실행 중인 컨테이너만 보여 주므로 비어 있습니다. 시킨 명령이 끝나면서 컨테이너도 멈췄기 때문입니다.
- `docker ps -a`에는 멈춘 컨테이너까지 나옵니다. 두 컨테이너 모두 `alpine:3.20`에서 나왔습니다. 괄호 안 숫자는 종료 코드로, B는 파일을 못 찾아서 1입니다.
- `docker diff docker-demo-a`의 `A`는 추가, `C`는 변경입니다. B는 바꾼 것이 없어서 아무것도 나오지 않습니다.

멈췄다고 사라진 것은 아닙니다. 지우기 전까지 컨테이너와 쓰기 레이어는 남아 있습니다.

### 5. 컨테이너를 지워도 이미지는 남는지 확인

컨테이너가 남아 있으면 이미지를 지울 수 없는 경우가 있습니다. 아래는 이 PC에서 두 컨테이너가 남은 상태로 `docker rmi alpine:3.20`을 실행했을 때 본 예시이며, 따라 실행할 필요는 없습니다.

```text
Error response from daemon: conflict: unable to delete alpine:3.20 (must be forced) - container <컨테이너 ID> is using its referenced image <이미지 ID>
```

멈춘 컨테이너도 이미지를 참조하고 있어서 거절됐습니다. 강제로 지우는 대신, 이번 실습에서 만든 컨테이너부터 지웁니다. 3번에서 A의 `hello`와 B의 파일 없음 오류를 보고 두 컨테이너를 이번에 만들었다고 확인한 경우에만 아래 명령을 실행합니다.

{% raw %}
```powershell
docker rm docker-demo-a docker-demo-b
docker ps -a --filter "name=docker-demo" --format "table {{.Names}}\t{{.Status}}"
docker images alpine:3.20 --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
```
{% endraw %}

```text
docker-demo-a
docker-demo-b
NAMES     STATUS
REPOSITORY   TAG       SIZE
alpine       3.20      12.2MB
```

**정상 결과:** 컨테이너 목록은 비었고 이미지는 그대로입니다. 같은 이미지로 새 컨테이너를 만들어도 `/tmp/note.txt`는 없습니다. 그 파일은 이미지가 아니라 지워진 쓰기 레이어에 있었으니까요.

### 6. 이미지 정리 (선택)

1번에서 `alpine:3.20`이 없었고 이번에 처음 받은 경우에만 지웁니다. 원래 있던 이미지라면 이 단계를 건너뜁니다.

{% raw %}
```powershell
docker rmi alpine:3.20
docker images --filter "reference=alpine:3.20" --format "table {{.Repository}}\t{{.Tag}}"
```
{% endraw %}

**정상 결과:** 표에 `alpine` 줄이 없으면 정리된 것입니다. 같은 이미지에 다른 태그가 있으면 `docker rmi`는 지정한 태그만 해제하므로, 출력 문구보다 대상 태그가 목록에서 사라졌는지로 판단합니다.

## 실제 Open WebUI를 같은 눈으로 읽기

이제 같은 명령으로 실제 환경을 봅니다. 아래 명령은 상태를 읽기만 합니다.

{% raw %}
```powershell
docker images ghcr.io/open-webui/open-webui:main --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
docker ps --filter "name=^open-webui$" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
docker container inspect open-webui --format "{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}"
```
{% endraw %}

```text
REPOSITORY                      TAG       SIZE
ghcr.io/open-webui/open-webui   main      6.46GB

NAMES        IMAGE                                STATUS                 PORTS
open-webui   ghcr.io/open-webui/open-webui:main   Up 7 hours (healthy)   127.0.0.1:3000->8080/tcp

volume /app/backend/data
```

이제 이 결과를 읽을 수 있습니다. `docker ps` 결과가 비어 있거나 `inspect`가 실패하면 `docker ps -a`로 컨테이너 이름과 정지 상태를 먼저 확인합니다.

- 첫 표는 `ghcr.io`의 `open-webui` 저장소에서 받은 `main` 태그가 지금 로컬에서 가리키는 이미지입니다.
- `docker ps`의 IMAGE 칸은 컨테이너를 만들 때 쓴 이미지 참조입니다. `main`을 나중에 다시 받으면 같은 이름의 로컬 이미지와 실행 중인 컨테이너의 이미지가 다를 수 있습니다.
- 앞의 alpine과 달리 서버 프로그램이 계속 돌기 때문에 상태가 `Up`입니다.
- `127.0.0.1:3000->8080/tcp`는 이 PC 안에서 3000번 포트로 들어온 연결을 컨테이너의 8080번으로 넘긴다는 뜻입니다. 브라우저에서 3000번을 여는 이유입니다.
- `volume /app/backend/data`는 컨테이너 안의 이 경로에 볼륨이 연결되어 있다는 뜻입니다.

이미지를 만든 기록은 `docker history`로 볼 수 있습니다. 이 PC에서 `docker history ghcr.io/open-webui/open-webui:main`은 52줄이었고 그중 33줄의 크기가 `0B`로 표시됐습니다. 실습한 alpine은 2줄이었습니다.

아래는 당시 `docker system df`로 본 **이 Docker 엔진 전체**의 합계입니다. Open WebUI만의 값이 아니고, 이미지에는 `ubuntu:22.04` 120MB도 포함되어 있습니다.

| 종류 | 크기 | 읽는 법 |
|---|---:|---|
| 이미지 | 6.577GB | 엔진에 있는 이미지 합계 |
| 컨테이너 | 55.6MB | 엔진에 있는 컨테이너 합계. 이미지를 통째로 복사한 크기는 아닙니다 |
| 볼륨 | 1.119GB | 엔진에 있는 로컬 볼륨 합계 |

처음 질문 하나에 답할 수 있습니다. 이 설치에서는 `/app/backend/data`에 볼륨을 연결해 계정과 대화 데이터를 보관합니다. 볼륨이 어디에 있고 어떻게 지켜야 하는지는 3편과 6편에서 자세히 다룹니다.

> 그렇다고 `open-webui` 컨테이너를 시험 삼아 지우지는 마세요. 삭제 연습은 위의 실습 컨테이너로만 합니다.
{: .prompt-warning }

## 가상환경, WSL2, 가상 머신, 컨테이너는 무엇이 다를까

설치 과정에서는 비슷한 말이 섞여 나옵니다. 구분 기준은 **무엇까지 따로 갖는가**입니다.

| 이름 | 따로 갖는 것 | 함께 쓰는 것 | 커널 |
|---|---|---|---|
| Python 가상환경 | Python 패키지 | OS, 파일 시스템, 기반 Python | 실행 중인 OS의 커널 그대로 |
| 컨테이너 | 기본 설정에서 파일 시스템, 프로세스 범위, 네트워크 스택 | 커널 | 실행 환경의 Linux 커널 공유 |
| WSL2 | Linux 환경과 Linux 커널 | PC 하드웨어 | 관리형 가상 머신의 Linux 커널 |
| 가상 머신(VM) | 운영체제 전체 | PC 하드웨어 | VM마다 자기 커널 |

**커널**은 프로세스, 메모리, 파일, 네트워크를 실제로 관리하는 운영체제의 핵심입니다. 이 표에서 가장 중요한 칸입니다.

- **Python 가상환경**은 Python 패키지 묶음을 프로젝트별로 나눕니다. 기반 Python 위에 만들어지며, OS를 새로 띄우지 않습니다.
- **가상 머신**은 자기 커널을 가진 운영체제 전체를 실행합니다.
- **WSL2**도 가상 머신을 쓰지만, Windows가 뒤에서 관리하는 가벼운 형태이고 그 안에서 실제 Linux 커널이 동작합니다.
- **컨테이너**는 자기 커널이 없습니다. 기본 설정에서 파일과 프로세스는 나뉘어 있어도 커널은 함께 씁니다.

<figure class="diagram">
{% include figures/docker-basics-image-container/isolation-layers.svg %}
<figcaption>이 글의 Docker Desktop WSL2 환경에서는 컨테이너마다 배포판이 달라도 같은 Linux 커널을 함께 씁니다.</figcaption>
</figure>

같은 Docker Desktop WSL2 엔진에서 서로 다른 Linux 이미지를 실행해 배포판 이름과 커널 버전을 출력해 봅니다. 없는 이미지는 새로 받습니다. 끝난 뒤에는 1번에서 없던 태그만 `docker rmi alpine:3.20`, `docker rmi ubuntu:22.04`처럼 하나씩 지웁니다.

```powershell
docker run --rm alpine:3.20 sh -c "grep PRETTY /etc/os-release; uname -r"
docker run --rm ubuntu:22.04 sh -c "grep PRETTY /etc/os-release; uname -r"
```

```text
PRETTY_NAME="Alpine Linux v3.20"
6.18.58.1-microsoft-standard-WSL2
PRETTY_NAME="Ubuntu 22.04.5 LTS"
6.18.58.1-microsoft-standard-WSL2
```

`--rm`은 실행이 끝나면 그때 만든 컨테이너를 자동으로 지우는 옵션입니다. 같은 엔진에서 실행했더니 배포판은 달라도 커널 문자열은 같았습니다. 실행 중인 Open WebUI 안에서 읽어도 OS는 `Debian GNU/Linux 13 (trixie)`, 커널은 같은 값이었습니다. 이름에 `WSL2`가 들어 있다는 점도 눈여겨볼 만합니다.

여기서 처음 질문에 답이 나옵니다. **Open WebUI는 Windows 프로그램이 아니라 Linux 컨테이너**로 돌고, 이 환경에서 그 Linux 커널은 WSL2 쪽에서 옵니다. 반면 **Ollama는 Windows 프로그램**이라 컨테이너 안에 없습니다. 둘이 어떻게 연결되는지는 5편에서 봅니다.

## 자주 헷갈리는 점

| 헷갈리는 말 | 실제 |
|---|---|
| 컨테이너를 멈추면 지워진다 | 멈춤과 삭제는 다릅니다. `docker ps -a`에 남아 있으면 쓰기 레이어도 남아 있습니다 |
| 컨테이너를 지우면 이미지도 지워진다 | 이미지는 남습니다. 이미지나 그 태그는 `docker rmi`로 따로 지웁니다 |
| 컨테이너 안에서 바꾼 내용이 이미지에 저장된다 | 볼륨이나 호스트 폴더 등 별도 저장 공간을 연결하지 않은 경로의 변경은 각 컨테이너의 쓰기 레이어에 저장됩니다 |
| 태그가 같으면 항상 같은 이미지다 | `main`, `latest` 같은 태그는 다른 이미지를 가리키게 될 수 있습니다 |
| 컨테이너는 작은 VM이다 | VM은 자기 커널을 가지지만, 컨테이너는 커널을 함께 씁니다 |

## 정리

| 질문 | 답 |
|---|---|
| 이미지는 무엇인가 | 실행에 필요한 파일을 레이어로 쌓은 읽기 전용 틀 |
| 컨테이너는 무엇인가 | 이미지로 만든 격리된 실행 단위. 멈춘 뒤에도 삭제 전까지 남음 |
| 레지스트리는 무엇인가 | 이미지 저장소를 모아 제공하는 서비스 |
| 상태를 어떻게 보나 | `docker images`, `docker ps`, `docker ps -a` |
| 지우면 무엇이 사라지나 | `docker rm`은 컨테이너와 쓰기 레이어, `docker rmi`는 이미지 또는 그 태그 |
| VM과의 핵심 차이는 | 컨테이너는 자기 커널 없이 커널을 함께 씀 |

다음 편에서는 Windows에서 어떻게 Linux 컨테이너가 돌아가는지, WSL2와 Docker Desktop의 구조를 살펴봅니다. [2편 읽기]({% post_url 2026-11-18-docker-windows-wsl2-structure %})

## 참고 문서

- [What is an image?](https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-an-image/), [What is a container?](https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-a-container/), [What is a registry?](https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-a-registry/) (Docker Docs)
- [Storage drivers](https://docs.docker.com/engine/storage/drivers/), [Volumes](https://docs.docker.com/engine/storage/volumes/), [Docker Engine security](https://docs.docker.com/engine/security/) (Docker Docs)
- [docker image tag](https://docs.docker.com/reference/cli/docker/image/tag/), [docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/), [docker image rm](https://docs.docker.com/reference/cli/docker/image/rm/), [docker container run](https://docs.docker.com/reference/cli/docker/container/run/), [docker system df](https://docs.docker.com/reference/cli/docker/system/df/), [Docker contexts](https://docs.docker.com/engine/manage-resources/contexts/) (Docker Docs)
- [Working with the Container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) (GitHub Docs)
- [venv](https://docs.python.org/3/library/venv.html) (Python Docs), [Comparing WSL Versions](https://learn.microsoft.com/en-us/windows/wsl/compare-versions) (Microsoft Learn)
