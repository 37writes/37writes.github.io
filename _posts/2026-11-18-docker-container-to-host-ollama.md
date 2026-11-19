---
title: "컨테이너의 localhost는 왜 Windows가 아닐까: Open WebUI와 Ollama 연결 원리"
date: 2026-11-18 19:20:00 +0900
categories: [개발 도구, Docker]
tags: [docker, windows, docker-desktop, networking, ollama, open-webui]
description: "Windows에서는 되는 localhost:11434가 Docker 컨테이너 안에서는 왜 실패할까요? 컨테이너의 네트워크, host.docker.internal, OLLAMA_BASE_URL, OLLAMA_HOST를 Open WebUI와 Ollama 예제로 풀고 단계별 진단법까지 정리합니다."
---

> **시리즈: Windows에서 Docker 처음 배우기**
> 1. [Docker란 무엇인가: 이미지와 컨테이너]({% post_url 2026-11-18-docker-basics-image-container %})
> 2. [Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop]({% post_url 2026-11-18-docker-windows-wsl2-structure %})
> 3. [무엇이 어느 폴더에 생기나: 이미지·컨테이너·볼륨의 실제 위치]({% post_url 2026-11-18-docker-where-files-live %})
> 4. [docker-compose.yml 한 줄씩 읽기: Open WebUI 띄우기]({% post_url 2026-11-18-docker-compose-yml-line-by-line %})
> 5. **컨테이너에서 Windows의 Ollama 연결하기: localhost와 host.docker.internal** ← 지금 글
> 6. [Docker 운영과 문제 해결: 로그, 업데이트, 데이터 지키기]({% post_url 2026-11-18-docker-operations-troubleshooting %})

이 글은 Windows에서 Ollama와 Docker Desktop이 실행 중이고 Open WebUI 컨테이너가 떠 있다고 전제합니다. PowerShell에서 Ollama 주소를 부르면 바로 응답이 옵니다.

```powershell
curl.exe http://localhost:11434/api/version
```

```text
{"version":"0.40.16"}
```

그런데 같은 주소를 Open WebUI 컨테이너 안에서 부르면 실패합니다.

```powershell
docker exec open-webui curl -sS -m 5 http://localhost:11434/api/version
$LASTEXITCODE
```

```text
curl: (7) Failed to connect to localhost port 11434 after 0 ms: Could not connect to server
7
```

`7`은 curl의 종료 코드로, 그 주소와 포트에 연결하지 못했다는 뜻입니다. 주소를 한 글자도 바꾸지 않았는데 결과가 다른 이유는 **`localhost`가 "지금 이 명령을 실행하는 쪽 자신"을 가리키기 때문**입니다. 이 글은 그 차이에서 시작해 Open WebUI가 Windows의 Ollama에 닿는 경로를 따라가고, 연결이 안 될 때 어디부터 확인할지를 정리합니다.

이 글의 예제는 시리즈 내내 쓰는 구성입니다. Ollama는 Windows 프로그램으로 돌고, Open WebUI만 Docker 컨테이너로 돕니다. 확인한 환경은 Docker Desktop(Docker 29.9.3, Compose 5.7.0), WSL 3.0.5, Ollama 0.40.16입니다.

## 요청은 두 방향으로 오갑니다

헷갈리는 이유는 이 구성에 요청이 두 개 있고, 방향이 서로 반대이기 때문입니다.

<figure class="diagram">
{% include figures/docker-container-to-host-ollama/two-request-paths.svg %}
<figcaption>이 구성에서 브라우저는 Windows에서 컨테이너로, Open WebUI 서버는 컨테이너에서 Windows로 요청합니다. 그래서 두 요청에 쓰는 주소가 다릅니다</figcaption>
</figure>

1. **브라우저 → Open WebUI**: Windows의 브라우저가 `http://localhost:3000`을 엽니다. Docker가 이 요청을 컨테이너의 8080 포트로 넘깁니다.
2. **Open WebUI → Ollama**: 컨테이너 안의 Open WebUI 서버가 `http://host.docker.internal:11434`로 요청합니다. 이 요청은 Windows의 Ollama에 도착합니다.

Ollama를 부르는 쪽은 브라우저가 아니라 **Open WebUI의 백엔드**입니다. Open WebUI 문서도 Ollama 연결을 서버 쪽 요청으로 분류하고, 이때의 `localhost`는 Open WebUI가 돌고 있는 기계나 컨테이너라고 설명합니다. 브라우저가 Windows에 있다고 해서 Ollama 주소에 `localhost`를 쓸 수 없는 이유입니다.

두 요청과 관련된 설정은 compose 파일에서 볼 수 있습니다.

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

`ports`는 1번 요청의 입구를, `OLLAMA_BASE_URL`은 2번 요청의 목적지를 정합니다. 이 예제는 같은 이름을 `extra_hosts`로 `/etc/hosts`에도 적어 두었지만, Docker Desktop은 이 매핑 없이도 이름을 해석합니다. `DEFAULT_MODELS`는 새 채팅에서 미리 고를 모델을 정할 뿐, 모델을 설치하지는 않습니다.

## 컨테이너에는 자기만의 네트워크가 있습니다

컨테이너는 Linux의 **네임스페이스**라는 격리 기능 위에서 돕니다. 네임스페이스는 프로세스에게 "자기 몫의 시스템 자원"만 보이게 하는 장치입니다. 이 글의 Compose 구성에서 컨테이너는 프로젝트용 bridge 네트워크에 붙고, 자기 네트워크 스택을 갖습니다. Docker 문서의 표현으로는 컨테이너가 보는 것은 IP 주소가 붙은 네트워크 인터페이스, 게이트웨이, 라우팅 표, DNS 같은 것들입니다.

그래서 이 구성에서 컨테이너 안의 `localhost`(`127.0.0.1`)는 Windows가 아니라 **컨테이너 자신**입니다. 직접 비교하면 분명합니다.

| 어디서 실행 | 주소 | 결과 | 의미 |
|---|---|---|---|
| Windows | `localhost:11434/api/version` | `{"version":"0.40.16"}` | Windows에서 Ollama가 듣고 있음 |
| 컨테이너 | `localhost:8080/health` | HTTP 200 | 컨테이너 자신의 Open WebUI가 응답 |
| 컨테이너 | `localhost:11434/api/version` | curl 종료 코드 7 | 컨테이너 자신의 11434에 연결할 수 없었음 |
| 컨테이너 | `host.docker.internal:11434/api/version` | `{"version":"0.40.16"}` | 컨테이너 밖 Windows의 Ollama에 도달 |

이 구성에서 Ollama는 Windows 프로그램이고 컨테이너에는 들어 있지 않습니다. 다만 종료 코드 7이 직접 말해 주는 것은 그 주소와 포트에 연결하지 못했다는 사실까지입니다.

### bridge 네트워크와 컨테이너 IP

컨테이너의 네트워크가 어디에 붙어 있는지도 확인해 봅니다. PowerShell이 `$k`, `$v`를 자기 변수로 풀지 않도록 앞에 백틱을 붙였습니다.

{% raw %}
```powershell
docker inspect open-webui --format "{{range `$k, `$v := .NetworkSettings.Networks}}{{`$k}} {{`$v.IPAddress}} {{`$v.Gateway}}{{end}}"
```
{% endraw %}

네트워크 이름, 컨테이너 IP, 게이트웨이 순서로 나옵니다.

```text
server_default 172.18.0.2 172.18.0.1
```

- `server_default`: Compose가 만든 네트워크입니다. Compose는 `<프로젝트 이름>_default` 네트워크를 만들어 서비스를 붙이고, 프로젝트 이름은 기본적으로 compose 파일이 있는 폴더 이름에서 옵니다.
- `172.18.0.2`: 이 네트워크 안에서 컨테이너가 받은 IP입니다.
- `172.18.0.1`: 컨테이너가 밖으로 나갈 때 거치는 게이트웨이입니다.

이 Compose 기본 네트워크의 종류가 **bridge**입니다. 소프트웨어로 만든 스위치에 컨테이너를 꽂는다고 생각하면 됩니다. 같은 Compose 네트워크의 서비스끼리는 서비스 이름으로 서로를 찾을 수 있습니다. 다만 Ollama는 이 네트워크에 없는 Windows 프로그램이므로, 서비스 이름으로는 찾을 수 없습니다. 컨테이너 IP는 다시 만들면 바뀔 수 있어서 설정에 적어 둘 값도 아닙니다.

## 1번 요청: localhost:3000이 컨테이너 8080에 닿기까지

`"127.0.0.1:3000:8080"`은 왼쪽부터 **Windows에서 받을 주소, Windows 포트, 컨테이너 포트**입니다.

Docker Desktop 문서에 따르면 포트를 공개하면 Docker Desktop의 백엔드가 그 연결을 받아 Linux VM으로 전달하고, VM 안에서 컨테이너의 IP와 포트로 보냅니다. 앱 입장에서는 Windows의 일반 로컬 서비스처럼 접속할 수 있습니다.

앞의 `127.0.0.1`은 보안상 의미가 있습니다. 이 주소를 적으면 Docker가 돌아가는 PC에서만 접속할 수 있습니다. 주소를 생략해 `"3000:8080"`으로 쓰면 모든 주소에 공개되고, Docker 문서도 이 기본 동작이 외부에 포트를 열 수 있다고 경고합니다. 다른 PC에 공개할 생각이 없다면 앞에 `127.0.0.1`을 붙여 두는 편이 안전합니다.

## 2번 요청: host.docker.internal이 Windows에 닿기까지

### OLLAMA_BASE_URL: 어디로 보낼지

```yaml
environment:
  - OLLAMA_BASE_URL=http://host.docker.internal:11434
```

`OLLAMA_BASE_URL`은 Open WebUI가 사용할 Ollama 주소입니다. Open WebUI 문서에 따르면 Docker 이미지의 기본값도 이 주소입니다. 그래도 compose 파일에 적어 두면 파일만 읽어도 어디로 연결하는지 알 수 있습니다. 컨테이너에 전달된 값은 이렇게 확인합니다.

```powershell
docker exec open-webui printenv OLLAMA_BASE_URL
```

```text
http://host.docker.internal:11434
```

### extra_hosts와 host-gateway: 같은 이름을 hosts에도 적기

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

`extra_hosts`는 컨테이너의 `/etc/hosts`에 이름과 IP를 추가합니다. `/etc/hosts`는 이름과 IP의 짝을 적어 두는 파일입니다. `host-gateway`는 Docker가 호스트의 내부 IP로 바꿔 넣는 특별한 값입니다.

```powershell
docker exec open-webui cat /etc/hosts
```

```text
127.0.0.1       localhost
192.168.65.254  host.docker.internal
```

실제 출력에는 IPv6와 컨테이너 자신의 줄도 있지만 여기서는 뺐습니다. `192.168.65.254`는 공유기가 Windows에 준 주소가 아니라 Docker Desktop이 알려 주는 호스트의 내부 IP입니다. Docker 문서는 호스트의 IP가 바뀔 수 있다는 점을 들어 이 이름을 쓰라고 안내하므로, 설정에도 IP 대신 이름을 적습니다.

사실 Docker Desktop에서는 이 줄이 없어도 이름이 풀립니다. `extra_hosts` 없이 띄운 임시 컨테이너에서도 `host.docker.internal`은 같은 `192.168.65.254`로 풀렸고 Ollama 응답도 받았습니다. 문서에도 Docker Desktop이 이 이름을 자동으로 처리한다고 나옵니다. 그럼에도 compose에 남겨 두면 이 컨테이너가 호스트에 접속한다는 의도가 드러나고, Open WebUI의 공식 실행 예제와도 같은 형태가 됩니다.

## Ollama는 127.0.0.1에서만 듣는데 왜 연결될까

여기서 이상한 점이 하나 있습니다. Windows에서 Ollama의 LISTEN 상태를 보면 `127.0.0.1`에만 묶여 있습니다.

```powershell
netstat -ano | findstr :11434 | findstr LISTENING
```

```text
TCP    127.0.0.1:11434        0.0.0.0:0              LISTENING       <PID>
```

Ollama의 기본값이 `127.0.0.1:11434`이므로 정상입니다. 이 주소는 같은 PC 안에서 오는 연결만 받습니다. 그런데 컨테이너는 별도 네트워크에 있는데도 연결에 성공했습니다.

Docker Desktop 문서는 컨테이너의 바깥 방향 트래픽을 이렇게 설명합니다. 트래픽은 VM에서 호스트로 전달되고, **호스트의 Docker Desktop 백엔드 프로세스가 받아 일반 앱과 같은 방식으로 TCP/IP 연결을 새로 만듭니다.** 그래서 컨테이너의 외부 연결은 Windows에서 `com.docker.backend`가 만든 연결로 보입니다.

이 PC에서도 같은 모습이 관측됐습니다. 임시 컨테이너에서 `host.docker.internal:11434` 연결을 잠시 열어 둔 채 Windows의 연결 목록을 보니, 새로 생긴 연결은 이것이었습니다.

| 연결을 만든 프로세스 | 출발 주소 | 도착 주소 |
|---|---|---|
| `com.docker.backend` | `127.0.0.1:<임시 포트>` | `127.0.0.1:11434` |

이 관측에서 Ollama는 **Windows 루프백으로 접속을 받았습니다.** `127.0.0.1`에서만 듣는 Ollama에 연결된 모습과 들어맞습니다.

다만 범위는 여기까지입니다. 문서에서 "호스트의 `127.0.0.1` 서비스에 항상 이렇게 연결된다"는 보장은 찾지 못했고, Docker Desktop이 내부에서 목적지를 어떻게 바꾸는지도 이 글에서는 단정하지 않습니다. 이 PC는 WSL의 `networkingMode=mirrored` 설정을 쓰고 있으며, [WSL의 기본값인 NAT 모드](https://learn.microsoft.com/en-us/windows/wsl/networking)에서 같은 결과가 나오는지는 확인하지 못했습니다. 그러니 이 내용은 원리로 외우기보다, 아래 진단 순서로 자기 PC에서 직접 확인하는 것이 좋습니다.

## OLLAMA_HOST=0.0.0.0은 언제 필요할까

Ollama 연결 문제를 찾아보면 `OLLAMA_HOST=0.0.0.0`을 설정하라는 답을 자주 만납니다. Open WebUI의 문제 해결 문서에도 나오는 방법입니다. `0.0.0.0`은 특정 주소 하나가 아니라 모든 IPv4 인터페이스를 뜻하는 IPv4 와일드카드입니다.

이 글의 구성에서는 필요하지 않았습니다. `OLLAMA_HOST` 환경 변수가 없고 Ollama가 `127.0.0.1`에서만 듣는 상태로 위 연결이 모두 성공했기 때문입니다. 연결이 안 된다고 먼저 이 값부터 바꾸지 말고, 다음 절의 진단으로 원인을 좁혀 보세요.

`0.0.0.0`이 위험할 수 있는 이유는 Ollama의 API 성격 때문입니다. Ollama 문서는 `localhost:11434`의 로컬 API에 인증이 필요 없다고 설명합니다. 이 API를 외부 인터페이스에 열면, 방화벽이 막지 않는 한 같은 네트워크의 다른 PC도 모델 목록을 보거나 모델 실행을 요청할 수 있는 상태가 됩니다. 설정값만 보고 공개 범위를 판단하지 말고, 앞의 `netstat` 명령으로 실제 수신 주소를 확인하세요. 다른 PC에 공개할 때는 방화벽에서 IPv4와 IPv6의 접근 범위를 함께 확인해 제한하고, 인증을 맡을 앞단도 검토해야 합니다.

## 연결이 안 될 때: 안쪽부터 네 단계

Ollama에서 시작해 Open WebUI 화면 쪽으로 나아갑니다. 앞 단계가 실패하면 그 단계부터 고칩니다. 모두 읽기 전용 명령이라 실행 중인 컨테이너와 데이터를 바꾸지 않습니다.

### 1단계: Ollama가 듣고 있는가

```powershell
netstat -ano | findstr :11434 | findstr LISTENING
```

정상이면 `127.0.0.1:11434`와 `LISTENING`이 보입니다. 아무것도 안 나오면 Ollama가 실행 중이 아니거나 다른 포트를 쓰는 것입니다.

### 2단계: Windows에서 API가 응답하는가

```powershell
curl.exe -sS http://localhost:11434/api/version
```

정상이면 `{"version":"..."}`이 나옵니다. Windows PowerShell 5.1의 `curl`은 다른 명령의 별칭이므로 `curl.exe`로 씁니다.

### 3단계: 컨테이너에서 Windows까지 닿는가

```powershell
docker ps --filter name=open-webui
docker exec open-webui curl -sS -m 5 http://host.docker.internal:11434/api/version
$LASTEXITCODE
```

`docker ps`에는 상태 `healthy`와 포트 `127.0.0.1:3000->8080/tcp`가 보여야 합니다. 목록이 비면 `docker ps -a --filter name=open-webui`로 멈춘 컨테이너인지 봅니다. 연결의 성공 기준은 **버전 JSON과 종료 코드 `0`**입니다.

`docker exec open-webui cat /etc/hosts`는 `extra_hosts`를 쓴 구성에서 매핑을 확인하는 용도입니다. 이 줄이 없어도 Docker Desktop에서는 이름이 풀릴 수 있으므로, 이름 해석만 따로 보려면 `docker exec open-webui getent hosts host.docker.internal`을 씁니다.

### 1·2단계는 되는데 3단계만 실패할 때

종료 코드부터 나눕니다. 6은 이름을 찾지 못한 것, 7은 연결하지 못한 것, 28은 `-m`으로 준 시간 안에 끝나지 않은 것입니다. 그다음 이 순서로 봅니다.

1. **호스트명과 포트**: curl에 적은 `host.docker.internal`의 철자와 포트를 보고, 그 포트가 1단계 `netstat`에 나온 Ollama 포트와 같은지 확인합니다. 이 curl은 주소를 직접 적었으므로 `OLLAMA_BASE_URL`을 읽지 않습니다. 환경 변수는 직접 호출이 성공한 뒤 4단계에서 봅니다.
2. **Docker Desktop 네트워크**: 설정의 Network에서 Docker subnet이 지금 쓰는 네트워크 대역과 겹치지 않는지 봅니다.
3. **Windows 방화벽과 보안 프로그램**: 컨테이너의 바깥 연결은 `com.docker.backend`에서 나가는 것으로 보이므로, 이 프로세스가 막혔는지 확인합니다. 방화벽을 통째로 끄지는 않습니다.
4. **그래도 실패하면**: 앞의 `OLLAMA_HOST` 절에서 위험을 읽고, 필요한 범위로만 바인딩 변경을 검토합니다.

### 4단계: Open WebUI가 모델을 보는가

```powershell
docker exec open-webui curl -sS -m 5 http://host.docker.internal:11434/api/tags
```

정상이면 응답의 `models`에 설치한 모델이 들어 있습니다. 비어 있으면 Windows에서 `ollama list`로 설치 여부를 봅니다. 그다음 `http://localhost:3000`을 열어 모델 선택 목록에 같은 이름이 보이는지 확인합니다.

직접 호출은 성공하는데 Open WebUI 화면에 문제가 있으면, 그때 컨테이너에 전달된 주소 설정을 봅니다.

```powershell
docker exec open-webui printenv OLLAMA_BASE_URL
docker exec open-webui printenv OLLAMA_BASE_URLS
```

이 글의 구성에서는 첫 줄에 `http://host.docker.internal:11434`가 나오고, 설정하지 않은 `OLLAMA_BASE_URLS`는 아무것도 출력하지 않습니다.

### 증상별 원인표

| 증상 | 가능성이 큰 원인 | 할 일 |
|---|---|---|
| 1단계에 아무것도 없음 | Ollama가 꺼져 있거나 포트가 다름 | Ollama 실행, 포트 확인 |
| 컨테이너에서 `localhost:11434`가 종료 코드 7 | 이 구성에서 예상되는 결과. 컨테이너 자신의 포트를 부른 것 | `host.docker.internal` 사용 |
| `OLLAMA_BASE_URL`이 `localhost`로 되어 있음 | 주소 설정 오류 | 기존 compose 폴더에서 수정 후 `docker compose up -d` |
| 종료 코드 6 | 이름을 찾지 못함. 주소 오타 가능성 | 주소 철자 확인, 위 3단계 실패 순서 |
| `host.docker.internal:11434`가 종료 코드 7 | 그 주소·포트에 연결하지 못함 | 1·2단계 실패면 그쪽부터, 통과면 위 3단계 실패 순서 |
| 종료 코드 28 | 제한 시간 안에 끝나지 않음 | 위 3단계 실패 순서 |
| 3·4단계는 정상인데 화면에 모델이 없음 | 저장된 연결 주소, `OLLAMA_BASE_URLS`, 꺼진 연결, 모델 필터 | 관리자 Settings > Connections의 Ollama 연결과 Manage의 Model IDs (Filter) 확인, `docker exec open-webui printenv OLLAMA_BASE_URLS` |
| `localhost:3000`이 안 열림 | 컨테이너가 꺼졌거나 아직 시작 중, 포트 공개 오류 | `docker ps`의 상태와 포트 확인 |
| 다른 PC에서 3000이 안 열림 | `127.0.0.1`로 공개했으므로 의도된 동작 | 공개가 정말 필요한지부터 검토 |

몇 가지만 덧붙입니다.

- 임시 컨테이너에서 없는 이름 `ollama`는 약 4초 뒤 6, 아무것도 듣지 않는 `host.docker.internal:11435`는 7, 접속만 받고 응답하지 않는 서버는 28이 나왔습니다. 없는 이름도 `-m 3`처럼 제한을 짧게 주면 이름 해석 중에 28로 끝났습니다.
- compose의 환경 변수를 고쳤다면 **기존 compose 폴더에서 같은 프로젝트 이름으로** `docker compose up -d`를 실행합니다. 설정이 바뀐 컨테이너는 다시 만들어지므로 잠깐 접속이 끊길 수 있고, 볼륨은 유지됩니다. 프로젝트 이름이 달라지면 기존 프로젝트의 볼륨이 연결되지 않을 수 있고, 기존 컨테이너와 이름이 충돌할 수 있습니다.
- 문제 해결에 `docker compose down -v`는 쓰지 않습니다. `-v`는 볼륨까지 지워 계정과 대화 데이터가 사라질 수 있습니다.
- Open WebUI는 화면에서 저장한 연결 설정을 데이터베이스에 보관하고, 이 값이 환경 변수보다 우선할 수 있습니다. `OLLAMA_BASE_URLS`도 `OLLAMA_BASE_URL`보다 우선합니다. `printenv` 값이 맞는데 동작이 다르면 이 둘을 확인합니다.
- 이 PC에서는 `localhost:3000`이 정상으로 열리는데도 Windows의 `netstat`에 3000 포트 LISTEN이 보이지 않았습니다. 임시 컨테이너로 다른 포트를 공개해도 같았습니다. 그러니 3000번은 `netstat`만으로 판단하지 말고 `docker ps`와 실제 접속 결과로 확인하세요.

## 정리

- `localhost`는 그 명령을 실행한 쪽 자신입니다. Windows에서는 Windows, 컨테이너에서는 컨테이너입니다.
- 브라우저 → `localhost:3000` → 컨테이너 8080과, Open WebUI → `host.docker.internal:11434` → Windows Ollama는 방향이 다른 별개의 요청입니다.
- `OLLAMA_BASE_URL`은 목적지를, `ports`는 반대 방향 입구를 정합니다. `extra_hosts`는 같은 이름을 `/etc/hosts`에도 적지만, Docker Desktop은 이 매핑 없이도 이름을 해석합니다.
- 이 구성에서는 Ollama가 `127.0.0.1`에서만 들어도 연결됐고, Windows에서는 `com.docker.backend`가 만든 로컬 연결로 보였습니다. `OLLAMA_HOST=0.0.0.0`은 필요하지 않았습니다.
- 문제가 생기면 Ollama LISTEN → Windows API → 컨테이너 안 curl → Open WebUI 모델 목록 순으로 확인합니다.

다음 편에서는 로그 확인, 이미지 업데이트, 데이터를 지키는 방법까지 Docker 운영과 문제 해결을 다룹니다. [6편 읽기]({% post_url 2026-11-18-docker-operations-troubleshooting %})

## 참고 문서

- [Docker Desktop networking: How it works](https://docs.docker.com/desktop/features/networking/)
- [Docker Desktop networking how-tos](https://docs.docker.com/desktop/features/networking/networking-how-tos/)
- [docker container run: --add-host와 host-gateway](https://docs.docker.com/reference/cli/docker/container/run/)
- [Compose file reference: extra_hosts](https://docs.docker.com/reference/compose-file/services/)
- [Networking in Compose](https://docs.docker.com/compose/how-tos/networking/)
- [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)
- [docker compose up](https://docs.docker.com/reference/cli/docker/compose/up/), [docker compose down](https://docs.docker.com/reference/cli/docker/compose/down/)
- [Docker Desktop settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)
- [Ollama FAQ](https://docs.ollama.com/faq), [Ollama API authentication](https://docs.ollama.com/api/authentication)
- [Open WebUI environment variables](https://docs.openwebui.com/reference/env-configuration/), [Open WebUI connection errors](https://docs.openwebui.com/troubleshooting/connection-error/), [Open WebUI Ollama connection](https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-ollama/)
