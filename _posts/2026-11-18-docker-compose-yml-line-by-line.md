---
title: "docker-compose.yml 한 줄씩 읽기: Open WebUI를 띄우며 배우는 설정"
date: 2026-11-18 19:15:00 +0900
categories: [개발 도구, Docker]
tags: [docker, windows, docker-compose, open-webui, ollama]
description: "Open WebUI의 docker-compose.yml을 위에서 아래로 읽으며 ports, environment, volumes, restart의 뜻과 프로젝트 이름 규칙, up -d 때 일어나는 일, healthy 확인법, 다른 PC에 열 때의 주의점을 실습으로 정리합니다."
---

> **시리즈: Windows에서 Docker 처음 배우기**
> 1. [Docker란 무엇인가: 이미지와 컨테이너]({% post_url 2026-11-18-docker-basics-image-container %})
> 2. [Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop]({% post_url 2026-11-18-docker-windows-wsl2-structure %})
> 3. [무엇이 어느 폴더에 생기나: 이미지·컨테이너·볼륨의 실제 위치]({% post_url 2026-11-18-docker-where-files-live %})
> 4. **docker-compose.yml 한 줄씩 읽기: Open WebUI 띄우기** ← 지금 글
> 5. [컨테이너에서 Windows의 Ollama 연결하기: localhost와 host.docker.internal]({% post_url 2026-11-18-docker-container-to-host-ollama %})
> 6. [Docker 운영과 문제 해결: 로그, 업데이트, 데이터 지키기]({% post_url 2026-11-18-docker-operations-troubleshooting %})

안내서대로 `docker-compose.yml`을 만들고 `docker compose up -d`를 실행하면 Open WebUI가 뜹니다. 브라우저에서 `http://localhost:3000`을 열면 화면도 나옵니다. 그런데 파일을 고쳐야 할 때가 오면 막힙니다. 포트의 숫자 중 어느 쪽을 바꿔야 하는지, 폴더를 옮겨도 데이터가 남는지, `unhealthy`가 떴을 때 고장인지 알 수 없기 때문입니다.

이 글은 Windows의 Ollama와 Docker 컨테이너로 띄운 Open WebUI 구성을 예제로, compose 파일을 위에서 아래로 읽습니다. 앞 편을 읽지 않았어도 괜찮습니다. 끝까지 읽으면 다음을 설명할 수 있습니다.

- 파일의 각 줄이 무엇을 정하는가
- 볼륨과 네트워크의 이름이 어디서 오는가
- `docker compose up -d`가 어떤 순서로 무엇을 만드는가
- 잘 떴는지 무엇으로 확인하는가
- 다른 PC에 열면 무엇이 달라지는가

명령과 출력은 Docker 29.9.3, Compose 5.7.0에서 확인했습니다.

## 오늘 읽을 파일

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

형식은 YAML입니다. 들여쓰기로 소속을 나타내고, 들여쓰기에는 공백만 씁니다. `image:` 앞을 탭으로 바꿔 검사해 보면 `found character that cannot start any token` 오류가 나며 실행되지 않습니다.

## Compose는 긴 `docker run`을 파일로 옮긴 것

같은 구성을 명령 하나로 쓰면 이렇게 됩니다. **Compose와 비교하려는 예시이니 실행하지 마세요.** 실제 실습은 아래 '따라 하기' 절부터입니다. 이름 `open-webui`와 3000 포트가 Compose 구성과 겹칩니다. PowerShell 기준이고, 줄 끝의 백틱은 줄 잇기이며 그 뒤에 공백이 있으면 안 됩니다.

```powershell
docker run -d `
  --name open-webui `
  -p 127.0.0.1:3000:8080 `
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 `
  -e DEFAULT_MODELS=gemma4:12b-it-qat `
  --add-host host.docker.internal:host-gateway `
  -v webui-data:/app/backend/data `
  --restart unless-stopped `
  ghcr.io/open-webui/open-webui:main
```

옵션과 compose 항목은 거의 일대일로 대응합니다.

| `docker run` | compose 항목 | 정하는 것 |
|---|---|---|
| 마지막 인자 | `image` | 어떤 이미지로 만들지 |
| `--name` | `container_name` | 컨테이너 이름 |
| `-p` | `ports` | 밖에서 들어올 길 |
| `-e` | `environment` | 프로그램에 넘길 설정값 |
| `--add-host` | `extra_hosts` | 컨테이너 안에 추가할 호스트 이름 |
| `-v` | `volumes` | 지워지면 안 되는 데이터의 자리 |
| `--restart` | `restart` | 꺼졌을 때 다시 켤지 |

파일로 옮기면 긴 명령을 기억하지 않아도 되고, 설정을 고친 뒤 같은 명령 `docker compose up -d`로 반영할 수 있습니다.

다만 완전히 같지는 않습니다. `docker run`은 볼륨을 `webui-data` 이름 그대로 쓰고 기본 bridge 네트워크에 붙지만, Compose는 볼륨 이름 앞에 프로젝트 이름을 붙이고 프로젝트용 네트워크를 만듭니다. 그래서 `docker run`으로 쓰던 컨테이너를 그대로 옮기면 새 빈 볼륨이 연결되어 데이터가 사라진 것처럼 보일 수 있습니다. 옮길 때는 기존 볼륨을 먼저 백업하고 `docker compose config`로 연결될 볼륨 이름을 확인합니다.

## 위에서 아래로 읽기

### `services`와 `open-webui`

```yaml
services:
  open-webui:
```

`services`는 띄울 프로그램의 목록입니다. 그 아래 `open-webui`는 이 파일 안에서 쓰는 **서비스 이름**이고, 그 아래로 들여쓴 줄이 모두 이 서비스의 설정입니다. 이 예제는 서비스가 하나지만, 데이터베이스가 필요하면 같은 높이에 하나 더 적습니다. 나중에 볼 `docker compose logs open-webui`의 `open-webui`가 이 이름입니다.

### `image`

```yaml
    image: ghcr.io/open-webui/open-webui:main
```

`ghcr.io`는 이미지를 내려받을 저장소, `open-webui/open-webui`는 이미지 이름, `main`은 **태그**입니다. 태그는 버전 표식이지만 고정된 값이라는 보장은 없습니다. Open WebUI 문서에 따르면 `main`은 개발이 진행되면 다시 빌드되는 이동식 태그이고, 운영 환경에는 `:v1.2.3` 형태의 버전 태그로 고정하기를 권합니다.

알아 둘 점이 하나 있습니다. Compose의 기본 정책은 **이미지가 로컬에 없을 때만** 내려받는 것입니다. 그래서 이 예제의 `:main`은 로컬에 이미지가 있으면 재사용하고, `docker compose up -d`만으로 새 버전이 받아지지 않습니다. 다만 `:latest` 태그는 예외로, 기본 정책에서도 항상 받습니다. 업데이트 절차는 6편에서 다룹니다.

### `container_name`

```yaml
    container_name: open-webui
```

컨테이너 이름을 직접 정합니다. `docker logs open-webui`처럼 짧게 부를 수 있어 편합니다. 적지 않으면 `<프로젝트>-<서비스>-1` 형태가 됩니다. 실제로 `compose-order` 폴더의 `app` 서비스는 `compose-order-app-1`이 됐습니다.

대가도 있습니다. 이름을 고정하면 이 서비스를 여러 개로 늘릴 수 없고, 같은 이름의 컨테이너가 이미 있으면 새로 만들지 못합니다.

### `ports`

```yaml
    ports:
      - "127.0.0.1:3000:8080"
```

이 파일에서 가장 중요한 줄입니다. 콜론으로 나뉜 세 부분은 **받을 주소, 이 PC의 포트, 컨테이너 포트**입니다.

<figure class="diagram">
{% include figures/docker-compose-yml-line-by-line/port-mapping.svg %}
<figcaption>Docker 28 이상에서 127.0.0.1은 이 PC 전용이고, 주소를 빼면 기본 설정에서 모든 주소에 공개됩니다. 포트가 겹치면 가운데 3000을 바꿉니다</figcaption>
</figure>

- `8080`은 컨테이너 안에서 Open WebUI가 듣는 포트입니다. 이미지가 정한 값이므로 보통 그대로 둡니다.
- `3000`은 Windows 쪽에서 쓸 포트입니다. 다른 프로그램이 3000을 쓰고 있으면 **이 숫자만** 바꿉니다. `"127.0.0.1:3100:8080"`이면 주소가 `http://localhost:3100`이 됩니다.
- `127.0.0.1`은 이 PC 자신을 뜻합니다. Docker 문서에 따르면 이렇게 게시한 포트는 Docker 호스트에서만 접근할 수 있고, 이 글의 29.9.3도 이 범위입니다. 28.0.0 미만에서는 같은 L2 네트워크의 다른 장비가 닿을 수 있다는 경고가 있습니다.

값을 큰따옴표로 감싸는 것도 이유가 있습니다. Compose 문서는 YAML이 콜론 붙은 숫자를 60진수로 해석하는 문제를 피하도록 `HOST:CONTAINER` 값을 항상 문자열로 쓰라고 안내합니다.

### `environment`

```yaml
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
      - DEFAULT_MODELS=gemma4:12b-it-qat
```

컨테이너 안 프로그램에 넘기는 환경 변수입니다. `OLLAMA_BASE_URL`은 Open WebUI가 찾아갈 Ollama 주소이고, `DEFAULT_MODELS`는 새 채팅에서 미리 선택할 모델입니다. 환경 변수를 적는다고 모델이 설치되지는 않으므로, Windows에서 `ollama list`로 그 이름이 있는지 확인합니다.

여기서 자주 헷갈리는 점이 있습니다. Open WebUI 문서는 `DEFAULT_MODELS`를 `ConfigVar`로 표시합니다. 이런 값은 내부에 저장되고, 이미 저장된 값이 있으면 기본 설정에서는 환경 변수보다 그 값이 우선합니다. 그래서 파일의 값만 바꿔서는 화면이 그대로일 수 있고, 관리자 화면에서 바꿔야 합니다.

### `extra_hosts`

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

컨테이너 안에 `host.docker.internal`이라는 이름을 등록합니다. `host-gateway`는 Docker가 호스트의 내부 IP로 바꿔 주는 특별한 값입니다. 컨테이너 안에서 `localhost`는 컨테이너 자신이므로, Windows에서 도는 Ollama에 닿으려면 이런 이름이 필요합니다. Docker Desktop은 이 이름을 자동으로 처리하지만, 파일에 적어 두면 의도가 드러납니다. 왜 이렇게 연결되는지는 5편에서 자세히 봅니다.

### 서비스 안의 `volumes`

```yaml
    volumes:
      - webui-data:/app/backend/data
```

왼쪽은 볼륨 이름, 오른쪽은 컨테이너 안의 경로입니다. Open WebUI는 계정, 대화, 설정을 `/app/backend/data`에 저장합니다. 컨테이너는 지우고 다시 만들 수 있는 것이므로, 남겨야 할 데이터는 이렇게 볼륨에 둡니다.

왼쪽에 이름 대신 `./data`처럼 경로를 쓰면 볼륨이 아니라 폴더 연결(바인드 마운트)이 됩니다. 이 파일은 이름을 썼으므로 compose 파일이 있는 폴더에는 데이터가 생기지 않습니다.

### `restart`

```yaml
    restart: unless-stopped
```

컨테이너가 멈췄을 때의 정책입니다.

| 값 | 동작 |
|---|---|
| `no` | 다시 켜지 않습니다 (기본값) |
| `on-failure` | 종료 코드가 0이 아닐 때만 다시 켭니다 |
| `always` | 멈추면 다시 켭니다. 직접 멈춘 경우에도 Docker가 재시작되면 다시 켜집니다 |
| `unless-stopped` | `always`와 비슷하지만, 직접 멈춘 컨테이너는 Docker가 재시작돼도 꺼진 채로 둡니다 |

`unless-stopped`는 "평소에는 살아 있게 하되, 내가 끈 것은 존중한다"는 뜻입니다.

### 최상위 `volumes`

```yaml
volumes:
  webui-data:
```

맨 왼쪽에 있는 이 블록은 서비스의 설정이 아니라 **이 프로젝트가 쓸 볼륨의 선언**입니다. 값이 비어 있으면 Docker 기본 설정으로 만든다는 뜻입니다. 빈 것처럼 보여도 지우면 안 됩니다. 이 블록을 빼고 검사하면 다음 오류가 납니다.

```text
service "open-webui" refers to undefined volume webui-data: invalid compose project
```

## 프로젝트 이름이 자원 이름을 정합니다

파일 어디에도 `server`라는 단어가 없는데, 이 구성을 `server` 폴더에서 띄우면 볼륨은 `server_webui-data`, 네트워크는 `server_default`가 됩니다. 프로젝트 이름을 따로 지정하지 않으면 Compose가 **compose 파일이 있는 폴더 이름을** 프로젝트 이름으로 쓰기 때문입니다.

<figure class="diagram">
{% include figures/docker-compose-yml-line-by-line/compose-resources.svg %}
<figcaption>프로젝트 이름을 따로 지정하지 않은 예입니다. 볼륨과 네트워크 이름에는 폴더에서 온 이름이 붙고, container_name은 적은 그대로 쓰입니다</figcaption>
</figure>

이 예제처럼 네트워크를 따로 적지 않으면 Compose가 기본 네트워크를 하나 만들어 서비스를 연결합니다.

폴더 이름은 그대로 쓰이지 않을 수도 있습니다. 프로젝트 이름에는 영어 소문자, 숫자, `-`, `_`만 쓸 수 있고 첫 글자는 소문자나 숫자여야 합니다. `My Server.v2` 폴더에서 확인해 보니 프로젝트 이름이 `myserverv2`로 바뀌었습니다.

### 폴더 이름을 바꾸면 생기는 일

이 규칙은 데이터와 바로 연결됩니다. 임시 프로젝트의 볼륨에 표시 파일을 하나 만들고, 같은 compose 파일을 다른 이름의 폴더로 복사해 실험했습니다.

| 상황 | 결과 |
|---|---|
| 원래 컨테이너가 도는 중에 새 폴더에서 `up -d` | `container_name`이 겹쳐 `Conflict. The container name ... is already in use` 오류 |
| 원래 프로젝트를 `down`한 뒤 새 폴더에서 `up -d` | 새 빈 볼륨이 연결되어 표시 파일이 **보이지 않음** |
| 원래 폴더로 돌아와 `up -d` | 원래 볼륨이 다시 연결되어 표시 파일이 **그대로 있음** |

즉 폴더 이름을 바꿔도 예전 볼륨이 지워지지는 않습니다. 다른 볼륨을 보고 있을 뿐입니다. Open WebUI에서 이런 일이 생기면 계정과 대화가 사라진 듯 보이고, 처음 설치한 화면이 다시 나옵니다. 반대로 **같은 Docker 엔진에서 프로젝트 이름과 볼륨 설정이 그대로라면** 폴더를 다른 드라이브로 옮겨도 같은 볼륨이 연결되어 계정과 데이터가 남습니다.

폴더 이름에 묶이고 싶지 않다면 파일 맨 위에 이름을 적을 수 있습니다. 기존 데이터를 이어 쓰려면 먼저 `docker compose ls -a`와 `docker volume ls`로 기존 프로젝트 이름을 확인해 똑같이 적습니다.

```yaml
name: server

services:
  # 이하 동일
```

다른 폴더에서 같은 `name:`을 적어 실행해 보니 표시 파일이 있는 기존 볼륨이 연결됐습니다. 이름은 `-p` 옵션, `COMPOSE_PROJECT_NAME` 환경 변수, 파일의 `name:`, 프로젝트 폴더 이름(여러 파일을 지정하면 첫 번째 Compose 파일의 폴더), Compose 파일을 지정하지 않았을 때의 현재 폴더 이름 순서로 적용됩니다.

## 따라 하기: 운영 중인 구성을 건드리지 않는 실습

이미 Open WebUI를 쓰고 있다면 그 폴더에서 실험하지 마세요. 폴더, 컨테이너 이름, 포트가 다른 실습 프로젝트를 따로 만들면 기존 컨테이너와 볼륨에 영향을 주지 않습니다.

Docker Desktop을 켠 PowerShell에서 Compose가 동작하는지 보고, 새 폴더를 만듭니다.

```powershell
docker compose version
New-Item -ItemType Directory "$HOME\compose-practice"
cd "$HOME\compose-practice"
Get-ChildItem -Force
```

버전이 나와야 하고, 마지막 명령에는 아무것도 나오지 않아야 합니다. 폴더가 이미 있다는 오류가 나거나 파일이 보이면 그 폴더를 쓰지 말고 다른 이름으로 만듭니다. 이때 아래의 `compose-practice`는 새 폴더 이름으로 읽습니다.

```powershell
notepad docker-compose.yml
```

앞의 파일을 붙여 넣고 **두 줄만** 바꿔 저장합니다.

```yaml
    container_name: open-webui-practice
    ports:
      - "127.0.0.1:3100:8080"
```

저장한 뒤 `Get-ChildItem -Name`에 `docker-compose.yml`이 보여야 합니다. `docker-compose.yml.txt`라면 이름을 고칩니다. 3100은 예시입니다. 3100도 쓰이고 있으면 가운데 숫자를 다른 포트로 바꾸고, 아래 출력과 주소의 3100은 고른 포트로 읽습니다.

### 1. 실행 전에 `docker compose config`

```powershell
docker compose config
```

파일을 해석한 **최종 결과**를 보여 줍니다. 문법 오류가 있으면 여기서 드러나고, 실제 자원 이름도 실행 전에 알 수 있습니다. 정상이면 아래 값이 보입니다.

```yaml
name: compose-practice
services:
  open-webui:
    container_name: open-webui-practice
    # 중간 생략
    ports:
      - mode: ingress
        host_ip: 127.0.0.1
        target: 8080
        published: "3100"
        protocol: tcp
networks:
  default:
    name: compose-practice_default
volumes:
  webui-data:
    name: compose-practice_webui-data
```

`name`이 `compose-practice`, `published`가 앞에서 고른 호스트 포트, 볼륨 이름이 `compose-practice_webui-data`인지 대조합니다. 하나라도 다르거나 기존 프로젝트와 겹치면 다음 단계로 가지 않습니다.

### 2. `docker compose up -d`

```powershell
docker compose up -d
```

`-d`는 백그라운드 실행입니다. 빼면 로그가 터미널을 차지합니다. 이미지가 이미 있는 PC에서 나온 진행 내용은 다음과 같습니다(`--progress plain`으로 받아 같은 줄은 뺐습니다).

```text
Network compose-practice_default Creating
Volume compose-practice_webui-data Creating
Volume compose-practice_webui-data Created
Network compose-practice_default Created
Container open-webui-practice Creating
Container open-webui-practice Created
Container open-webui-practice Starting
Container open-webui-practice Started
```

일어나는 일을 순서대로 적으면 이렇습니다.

1. **이미지 확인**: 로컬에 없으면 내려받습니다. 이 PC에서 표시된 이미지 크기는 6.46GB였습니다. 다른 작은 이미지를 받다가 네트워크 오류가 난 한 번의 실습에서는 네트워크와 볼륨을 만들기 전에 멈췄습니다. 회선이 불안정해 받기에 실패하면 같은 명령을 다시 실행합니다.
2. **네트워크와 볼륨 준비**: 없으면 만듭니다. 위 출력처럼 둘은 함께 진행되므로 어느 쪽이 먼저라고 볼 필요는 없습니다.
3. **컨테이너 생성**: 설정대로 컨테이너를 만들고 네트워크와 볼륨을 연결합니다.
4. **컨테이너 시작**: `Started`는 프로세스를 시작했다는 뜻입니다. **앱이 접속을 받을 준비가 끝났다는 뜻은 아닙니다.**

### 3. `docker compose ps`

```powershell
docker compose ps
```

이 프로젝트의 컨테이너 상태와 포트를 봅니다. 시작 직후에는 이렇게 나옵니다.

```text
NAME                  IMAGE                                COMMAND           SERVICE      CREATED        STATUS                                     PORTS
open-webui-practice   ghcr.io/open-webui/open-webui:main   "bash start.sh"   open-webui   1 second ago   Up Less than a second (health: starting)   127.0.0.1:3100->8080/tcp
```

확인할 것은 두 가지입니다. `STATUS`가 최종적으로 `Up ... (healthy)`가 되는지, `PORTS`가 앞에서 고른 호스트 포트로 `127.0.0.1:<포트>->8080/tcp`인지입니다. 목록이 비어 있으면 `docker compose ps -a`로 멈춘 컨테이너까지 봅니다.

### 4. `docker compose logs`

```powershell
docker compose logs --tail 20 open-webui
docker compose logs -f open-webui
```

`--tail 20`은 마지막 20줄, `-f`는 계속 따라 보기입니다. `-f`는 `Ctrl+C`로 빠져나와도 컨테이너는 계속 돕니다. 상태가 이상할 때 가장 먼저 볼 곳입니다.

### 5. `docker compose ls`

```powershell
docker compose ls
```

이 PC에서 실행 중인 Compose 프로젝트와 파일 위치를 보여 줍니다. compose 파일이 어디 있는지 잊었을 때 특히 유용합니다. 경로는 줄여 적었습니다.

```text
NAME                STATUS              CONFIG FILES
compose-practice    running(1)          C:\Users\<사용자>\compose-practice\docker-compose.yml
server              running(1)          <폴더>\server\docker-compose.yml
```

컨테이너가 모두 멈춘 프로젝트는 여기서 빠지고, `docker compose ls -a`에는 `exited(1)`로 나옵니다.

### 6. 브라우저와 health 확인

```powershell
curl.exe http://localhost:3100/health
```

정상이면 `{"status":true}`가 나옵니다. PowerShell 5.1에서는 `curl`이 다른 명령의 별칭이라 `curl.exe`로 씁니다. 그다음 브라우저에서 `http://localhost:3100`을 엽니다. 처음 만드는 계정이 관리자가 되므로, 실습용 계정이어도 그 점은 기억해 둡니다.

## `healthy`는 무엇을 뜻하나

`healthy`는 Docker가 컨테이너 안에서 **정해진 검사 명령을 돌려 통과했다**는 뜻입니다. 이 이미지의 검사는 안에서 `http://localhost:8080/health`를 호출해 `status`가 `true`인지 봅니다. 앱이 실제로 응답하는지를 보므로 `Up`보다 강한 신호입니다. 다만 그 응답 경로만 보는 것이어서, Ollama 연결이나 모델까지 정상이라는 증명은 아닙니다.

| 표시 | 뜻 |
|---|---|
| `health: starting` | 아직 판정 전입니다 |
| `healthy` | 검사를 통과한 상태입니다. 연속 실패가 기준에 이르기 전까지 유지되고, 통과하면 실패 횟수가 초기화됩니다 |
| `unhealthy` | 검사가 연속으로 기준 횟수만큼 실패했습니다 |

새 볼륨으로 처음 띄운 실습에서는 흥미로운 일이 있었습니다.

| 시작 후 | 상태 |
|---|---|
| 0초 | `health: starting` |
| 약 90초 | `unhealthy` |
| 4분 | `healthy` |

고장이 아니었습니다. 로그에는 그동안 Hugging Face에서 파일을 내려받는 기록이 이어졌고, 재시작 횟수도 0이었습니다. 이 이미지의 검사에는 간격과 재시도 값이 따로 없어서 Docker 기본값이 적용됩니다. 첫 검사는 시작 30초 뒤, 다음 검사는 직전 검사가 끝나고 30초 뒤에 돌고, 3회 연속 실패하면 `unhealthy`입니다. 이 실습에서는 그렇게 실패가 쌓여 약 90초에 `unhealthy`가 됐고, 준비를 마친 뒤 검사가 통과하자 `healthy`로 돌아왔습니다. 걸리는 시간은 회선과 환경에 따라 다릅니다. `unhealthy`만으로 컨테이너가 재시작되지는 않습니다.

그래서 첫 시작에 `unhealthy`가 보이면 바로 지우지 말고 로그부터 봅니다. 내려받기나 초기화가 진행 중이면 기다리고, 같은 오류가 반복되면 그 오류를 살핍니다.

## 파일을 고친 뒤와 실습 정리

파일을 고치면 다시 `docker compose up -d`를 실행합니다. 서비스 설정이나 이미지가 달라지면 컨테이너를 다시 만들 수 있습니다. 포트를 바꿔 실행했을 때는 `Recreate`가 나왔고, 같은 볼륨을 쓰므로 볼륨의 파일은 그대로였습니다. 아무것도 바꾸지 않았을 때는 `Running`만 나왔습니다.

실습이 끝나면 데이터를 남길지 버릴지 먼저 정하고, 아래 둘 중 **하나만** 실행합니다. `down`으로 컨테이너를 먼저 지우면 거기 연결됐던 익명 볼륨은 나중에 `down -v`를 해도 지워지지 않으므로, 버릴 생각이면 처음부터 삭제 쪽을 고릅니다. 이 예제의 볼륨은 이름 있는 볼륨입니다.

| 명령 | 지우는 것 | 남는 것 |
|---|---|---|
| `docker compose down` | 컨테이너, 기본 네트워크 | 이름 있는 볼륨, 익명 볼륨, 이미지 |
| `docker compose down -v` | 위 항목 + 파일에 선언한 볼륨 + 연결된 익명 볼륨 | `external` 볼륨, 이미지 |

> `-v`는 볼륨의 데이터를 지웁니다. 실제로 쓰는 Open WebUI 폴더에서 실행하면 계정과 대화가 함께 사라집니다.
{: .prompt-danger }

**데이터를 남길 때**는 실습 폴더에서 이것만 실행합니다.

```powershell
docker compose -f .\docker-compose.yml -p compose-practice down
```

**실습 데이터까지 버릴 때**는 위 명령 대신 아래를 진행합니다. 확인과 삭제에 같은 `-f`, `-p` 값을 씁니다.

```powershell
Get-Location
Resolve-Path .\docker-compose.yml
docker compose -f .\docker-compose.yml -p compose-practice config --volumes
docker volume ls --filter "label=com.docker.compose.project=compose-practice"
```

현재 폴더와 파일 경로가 실습 폴더이고, 삭제 대상 볼륨이 `webui-data` 하나, 볼륨 목록에 `compose-practice_webui-data`만 보일 때만 다음 명령을 따로 실행합니다.

```powershell
docker compose -f .\docker-compose.yml -p compose-practice down -v
```

## 다른 PC에 열 때 달라지는 것

지금 구성은 `127.0.0.1`에만 묶여 있어서 이 PC에서만 접속됩니다. 다른 PC에서 쓰려고 주소를 빼서 `"3000:8080"`으로 바꾸면 기본 설정의 Docker는 이 포트를 모든 네트워크 주소에 공개합니다. 실제 접속 여부는 네트워크 경로와 방화벽에 달렸지만, 줄 하나로 위험 범위가 크게 달라집니다. 이 부분은 공식 문서를 기준으로 정리했고, 직접 포트를 열어 시험하지는 않았습니다.

먼저 다음을 확인합니다.

- **관리자 계정을 먼저 만듭니다.** Open WebUI는 처음 만든 계정이 관리자가 됩니다. 계정 없이 포트부터 열면 다른 사람이 먼저 관리자가 될 수 있습니다.
- **가입 설정을 확인합니다.** 관리자 생성 뒤 가입은 꺼지지만, 설정에서 다시 켤 수 있습니다. 필요한 사람에게만 계정을 줍니다.
- **방화벽 범위를 좁힙니다.** Docker Desktop에서는 호스트 포트를 백엔드 프로세스가 받으므로, Windows 방화벽에서는 `com.docker.backend.exe`를 기준으로 들어오는 연결을 제어합니다. 허용 규칙에는 TCP 3000, 필요한 원격 주소, 네트워크 프로필만 넣습니다.
- **필요한 주소에만 묶습니다.** 모든 주소 대신 `"<이 PC의 IP>:3000:8080"`처럼 특정 주소를 쓸 수 있습니다.
- **HTTP라는 점을 기억합니다.** 이 구성은 암호화되지 않은 HTTP입니다. 믿을 수 없는 네트워크에서는 비밀번호와 대화가 그대로 지나갑니다. VPN이나 HTTPS 프록시를 앞에 둡니다. HTTPS가 무엇을 지켜 주는지는 [TLS 정리: 핸드셰이크, 인증서, 그리고 IoT 장치가 쓰는 mTLS]({% post_url 2026-11-12-tls-basics %})에서 볼 수 있습니다.

다른 PC에서 쓸 일이 없다면 `127.0.0.1`을 그대로 두는 것이 가장 간단하고 안전합니다.

## 정리

| 줄 | 기억할 것 |
|---|---|
| `image` | `main`은 움직이는 태그이고, 이미지가 있으면 기본 정책의 `up`이 새로 받지 않습니다 (`latest`는 예외) |
| `container_name` | 편하지만 같은 이름과 충돌합니다 |
| `ports` | `받을 주소:PC 포트:컨테이너 포트`. 포트를 바꿀 때는 가운데 숫자를 바꿉니다 |
| `environment` | 일부 Open WebUI 값은 저장값이 있으면 그 값이 우선합니다 |
| `extra_hosts` | 컨테이너 안에서 호스트를 부를 이름을 만듭니다 |
| `volumes` | 서비스 안에서 연결하고, 최상위에서 선언합니다 |
| `restart` | `unless-stopped`는 직접 끈 컨테이너를 존중합니다 |
| 프로젝트 이름 | 따로 지정하지 않으면 폴더 이름에서 오고, 볼륨과 네트워크 이름 앞에 붙습니다 |

확인 순서는 `config`로 해석 결과를 보고, `up -d`로 띄운 뒤, `ps`에서 `healthy`와 포트를 보고, 문제가 있으면 `logs`를 읽는 것입니다.

다음 편에서는 이 파일의 `host.docker.internal`을 파고듭니다. 컨테이너 안의 `localhost`로는 닿지 않는 Windows의 Ollama에 어떻게 연결되는지 확인합니다. [5편 읽기]({% post_url 2026-11-18-docker-container-to-host-ollama %})
