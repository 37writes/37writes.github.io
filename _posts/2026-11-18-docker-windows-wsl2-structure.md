---
title: "Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop의 관계"
date: 2026-11-18 19:05:00 +0900
categories: [개발 도구, Docker]
tags: [docker, windows, wsl2, docker-desktop, hypervisor]
description: "Windows에서 Linux 컨테이너가 도는 구조를 WSL2, docker-desktop 배포판, Docker Engine 순서로 풀어 봅니다. Ubuntu가 꺼져 있어도 컨테이너가 도는 이유, 확인 명령의 정상 결과, 설치 중 겪은 가상화·재시작 문제까지 정리합니다."
---

> **시리즈: Windows에서 Docker 처음 배우기**
> 1. Docker란 무엇인가: 이미지와 컨테이너
> 2. **Windows에서 Docker가 돌아가는 구조: WSL2와 Docker Desktop** ← 지금 글
> 3. 무엇이 어느 폴더에 생기나: 이미지·컨테이너·볼륨의 실제 위치
> 4. docker-compose.yml 한 줄씩 읽기: Open WebUI 띄우기
> 5. 컨테이너에서 Windows의 Ollama 연결하기: localhost와 host.docker.internal
> 6. Docker 운영과 문제 해결: 로그, 업데이트, 데이터 지키기

Windows PC에 WSL과 Docker Desktop을 설치하고 Open WebUI 컨테이너를 띄웠습니다. 브라우저에서 `http://localhost:3000`이 열리니 잘 돌아가는 것은 분명한데, 상태를 확인하다 이상한 장면을 만났습니다.

```powershell
wsl -l -v
```

```text
  NAME              STATE           VERSION
* Ubuntu-22.04      Stopped         2
  docker-desktop    Running         2
```

설치한 Ubuntu는 `Stopped`인데 컨테이너는 멀쩡히 돌고 있습니다. 그렇다면 컨테이너는 어디서 돌고 있고, `docker-desktop`은 무엇일까요? 이 글은 그 답을 Windows부터 컨테이너까지 층별로 따라갑니다. 앞 편을 읽지 않았어도 괜찮습니다. 컨테이너를 "프로그램과 그 실행 환경을 묶어 격리해 실행한 것" 정도로 알고 있으면 충분합니다.

결론은 그림 한 장으로 먼저 보여 드립니다.

<figure class="diagram">
{% include figures/docker-windows-wsl2-structure/layers-and-request-path.svg %}
<figcaption>docker 명령은 Windows에서 출발해 WSL2 안의 docker-desktop 배포판에 있는 엔진까지 갑니다. Ubuntu는 이 경로에 없습니다.</figcaption>
</figure>

## 왜 Windows에 Linux 커널이 필요한가

커널은 운영체제의 핵심으로, 프로그램의 요청을 받아 CPU·메모리·파일·네트워크를 실제로 다루는 부분입니다. 가상 머신(VM)은 자기 커널을 포함한 운영체제 전체를 실행하지만, 컨테이너는 자기 커널이 없고 **호스트(컨테이너를 실행하는 쪽) 운영체제의 커널 위에서** 돕니다.

Open WebUI 이미지 안의 프로그램은 Linux용이고, Docker도 컨테이너를 격리할 때 namespace 같은 Linux 커널 기능을 씁니다. 그래서 Linux 컨테이너를 돌리려면 어딘가에 Linux 커널이 있어야 합니다. Windows 커널은 Linux 커널이 아니므로, Windows PC에는 Linux 커널을 실행할 자리가 따로 필요합니다.

그 자리를 만들어 주는 것이 **WSL2**(Windows Subsystem for Linux 2)입니다. WSL2는 Microsoft가 빌드한 실제 Linux 커널을 가볍게 관리되는 VM 안에서 실행합니다. 일반 VM처럼 직접 만들고 설정할 필요 없이 뒤에서 관리됩니다.

> Docker Desktop의 Linux 컨테이너 실행 방식(백엔드)에는 WSL2 말고 Hyper-V, Docker VMM도 있습니다. 이 글은 기본값인 WSL2 기준입니다.

## 층별로 보기

그림의 아래쪽부터 올라가며 각 층이 하는 일을 정리하면 다음과 같습니다.

| 층 | 무엇인가 | 이 PC에서 확인한 값 |
|---|---|---|
| 하이퍼바이저 | VM을 실행하는 바탕이 되는 가상화 계층 | 켜져 있어야 WSL2가 동작 |
| WSL2 VM | Linux 커널을 실행하는 관리형 VM | 커널 `6.18.58.1-microsoft-standard-WSL2` |
| 배포판 | 커널 위의 Linux 환경(파일과 프로그램 묶음) | `docker-desktop`, `Ubuntu-22.04` |
| Docker Engine | 이미지를 받고 컨테이너를 만들어 실행하는 서버 프로그램 | 29.9.3, `linux/amd64` |
| 컨테이너 | 엔진이 실행한 격리된 프로그램 | `open-webui` |

**배포판(distribution)** 은 Ubuntu, Debian처럼 Linux 커널 위에 올라가는 파일과 프로그램의 묶음입니다. WSL2에서는 여러 배포판이 **커널 하나를 함께 쓰면서** 나란히 돕니다.

### Ubuntu-22.04와 docker-desktop은 별개입니다

`docker-desktop`은 Docker Desktop이 자기 엔진을 돌리려고 쓰는 전용 배포판이고, 다른 배포판과 분리되어 있습니다. 이 배포판의 프로세스를 읽어 보면 엔진인 `dockerd`와 `containerd`가 보입니다. Docker Desktop이 관리하는 영역이니 직접 들어가 고칠 일은 없습니다.

`Ubuntu-22.04`는 제가 Linux 작업용으로 따로 설치한 배포판입니다. Docker 공식 문서도 Docker Desktop에는 특정 배포판 설치가 필요 없고, Windows에서 `docker` 명령을 그대로 쓸 수 있다고 설명합니다. 그래서 도입부의 장면이 가능합니다. 컨테이너를 돌리는 쪽은 `docker-desktop`이고, Ubuntu는 꺼져 있어도 상관이 없습니다.

Ubuntu 터미널 안에서도 `docker`를 쓰고 싶다면 Docker Desktop의 WSL integration을 켜면 됩니다. 이것은 **그 배포판에서 같은 엔진을 부를 수 있게 하는 기능**이지, 엔진을 Ubuntu로 옮기는 기능이 아닙니다.

### 컨테이너 안의 Ubuntu도 또 다른 것입니다

이름이 비슷해 헷갈리는 것이 하나 더 있습니다. `ubuntu:22.04` **이미지**로 임시 컨테이너를 실행해 보겠습니다. `--rm`을 붙였으니 끝나면 컨테이너는 지워집니다.

```powershell
docker run --rm ubuntu:22.04 sh -c 'uname -r; grep PRETTY_NAME /etc/os-release'
```

```text
6.18.58.1-microsoft-standard-WSL2
PRETTY_NAME="Ubuntu 22.04.5 LTS"
```

두 줄이 많은 것을 말해 줍니다.

- 파일은 Ubuntu 22.04의 것입니다. 이미지가 가져온 사용자 영역입니다.
- 커널은 WSL2의 것입니다. 컨테이너에 자기 커널이 없다는 증거입니다.

이 명령을 실행한 뒤에도 `wsl -l -v`의 `Ubuntu-22.04`는 그대로 `Stopped`였습니다. `ubuntu:22.04` 이미지와 `Ubuntu-22.04` 배포판은 이름만 닮았을 뿐 서로 다른 것입니다.

## docker 명령은 어떤 길로 가는가

`docker`라는 명령은 엔진 자체가 아니라 **클라이언트**입니다. Docker는 클라이언트-서버 구조이고, 클라이언트가 API로 요청을 보내면 서버인 엔진(daemon)이 실제 일을 합니다. 여기서는 클라이언트가 Windows에, 엔진이 Linux 쪽에 있습니다.

둘 사이의 출발점은 `docker context ls`에서 볼 수 있습니다. **context**는 "이 CLI가 어느 엔진에 어떻게 접속할지"를 담은 설정 묶음입니다.

```powershell
docker context ls
```

```text
NAME              DESCRIPTION                               DOCKER ENDPOINT                             ERROR
default           Current DOCKER_HOST based configuration   npipe:////./pipe/docker_engine
desktop-linux *   Docker Desktop                            npipe:////./pipe/dockerDesktopLinuxEngine
```

`*`가 지금 쓰는 context입니다. 주소의 `npipe`는 **named pipe**, 즉 이름을 붙인 통로로 프로세스끼리 통신하는 Windows 기능입니다. 웹 주소처럼 네트워크로 나가는 것이 아니라 PC 안의 다른 프로그램에 말을 거는 창구라고 보면 됩니다.

이 파이프의 서버 쪽 프로세스를 조회해 보니 Docker Desktop의 `com.docker.backend`였습니다. 정리하면 요청은 이렇게 흐릅니다.

1. PowerShell에서 `docker ps`를 실행합니다.
2. Windows용 `docker.exe`가 `dockerDesktopLinuxEngine` 파이프로 요청을 보냅니다.
3. 파이프를 받은 Docker Desktop 백엔드를 거쳐 요청이 WSL2 안의 Docker Engine에 닿습니다.
4. 엔진이 결과를 돌려주거나 컨테이너를 실행합니다.

백엔드에서 엔진까지의 내부 전달 방식은 공개 문서에서 확인하지 못해서 그림에서도 화살표 하나로 두었습니다. 사용하는 입장에서는 "Windows의 CLI가 파이프로 말을 걸면 Docker Desktop이 Linux 쪽 엔진까지 이어 준다"까지만 알아도 충분합니다.

## 내 PC에서 확인하는 명령 다섯 개

PowerShell에서 아래를 차례로 실행하면 층별 상태를 확인할 수 있습니다. 버전 숫자는 PC와 시점에 따라 다릅니다.

### 1. `wsl -l -v`: 어떤 배포판이 어떤 상태인가

```text
  NAME              STATE           VERSION
* Ubuntu-22.04      Stopped         2
  docker-desktop    Running         2
```

**정상 기준:** Docker Desktop이 실행 중이면 `docker-desktop`이 `Running`이고 `VERSION`이 `2`입니다. Ubuntu 같은 다른 배포판은 없거나 `Stopped`여도 괜찮습니다. `*`는 `wsl`만 입력했을 때 들어가는 기본 배포판 표시입니다.

### 2. `wsl --version`: WSL과 커널 버전

```text
WSL 버전: 3.0.5.0
커널 버전: 6.18.58.1-1
```

앞의 두 줄만 옮겼습니다. **정상 기준:** 버전 정보가 출력됩니다. Docker Desktop은 WSL 2.1.5 이상을 요구합니다(작성 시점 문서 기준).

### 3. `docker version`: 클라이언트와 서버가 모두 응답하는가

```text
Client:
 Version:           29.9.3
 OS/Arch:           windows/amd64
 Context:           desktop-linux

Server: Docker Desktop 4.99.0 (245822)
 Engine:
  Version:          29.9.3
  OS/Arch:          linux/amd64
```

주요 줄만 옮겼습니다. 이 출력에 구조가 그대로 보입니다. **클라이언트는 `windows/amd64`, 엔진은 `linux/amd64`** 입니다. **정상 기준:** `Client`와 `Server`가 둘 다 나옵니다. `Client`만 나오고 엔진 연결 오류가 나면 Docker Desktop이 켜져 있는지부터 봅니다.

### 4. `docker context ls`: 어느 엔진을 보고 있는가

앞에서 본 명령입니다. **정상 기준:** `desktop-linux`에 `*`가 있고 `ERROR` 칸이 비어 있습니다.

### 5. `docker info`: 엔진이 어떤 환경에서 도는가

전체 출력이 길어서 필요한 줄만 골랐습니다.

```powershell
docker info | Select-String -Pattern '^ (Server Version|Storage Driver|Kernel Version|Operating System|OSType|Docker Root Dir):'
```

```text
 Server Version: 29.9.3
 Storage Driver: overlayfs
 Kernel Version: 6.18.58.1-microsoft-standard-WSL2
 Operating System: Docker Desktop
 OSType: linux
 Docker Root Dir: /var/lib/docker
```

**정상 기준:** `OSType`이 `linux`이고 커널 이름에 `WSL2`가 보입니다. `Docker Root Dir`이 `C:\...`가 아니라 `/var/lib/docker`인 점도 눈여겨볼 만합니다. 엔진이 Linux 쪽에서 돌고 있다는 뜻이고, 이 경로가 Windows의 어디에 대응되는지가 다음 편의 주제입니다.

## 설치 순서

처음 설치한다면 순서는 단순합니다.

1. BIOS/UEFI에서 하드웨어 가상화가 켜져 있는지 확인합니다. Docker Desktop의 요구 사항이기도 합니다.
2. **관리자** PowerShell에서 WSL을 설치하고 PC를 다시 시작합니다.

   ```powershell
   wsl --install
   ```

   이 명령은 WSL에 필요한 기능을 켜고 기본 배포판으로 Ubuntu를 설치합니다. WSL이 전혀 없는 PC에서만 이렇게 동작하고, 이미 있으면 `wsl --list --online`으로 목록을 본 뒤 `wsl --install -d <배포판 이름>`을 씁니다.
3. Docker Desktop을 설치하고 실행합니다.

   ```powershell
   winget install -e --id Docker.DockerDesktop
   ```

4. 앞의 다섯 명령으로 확인합니다.

Windows 버전과 메모리 같은 세부 요구 사항은 바뀔 수 있으니 [Docker Desktop 설치 문서](https://docs.docker.com/desktop/setup/install/windows-install/)를 함께 확인하세요.

## 설치하면서 실제로 막힌 곳

제 PC에서는 이 순서대로 한 번에 끝나지 않았습니다. 아래는 이 환경에서 겪은 일입니다. 같은 증상이어도 원인은 다를 수 있으니 확인 방법 위주로 봐 주세요.

### WSL 설치가 손상됐다는 오류

`wsl --install -d Ubuntu`가 이런 오류로 멈췄습니다.

```text
wsl: WSL 설치가 손상된 것 같습니다(오류 코드: Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG).
```

WSL 패키지를 다시 설치하는 쪽으로 넘어갔습니다.

```powershell
winget install -e --id Microsoft.WSL
```

### 설치 중 시간 초과

위 명령은 네트워크가 불안정할 때 `0x80072ee2`(시간 초과)로 실패했고, 회선이 정상인 환경에서 다시 실행하니 설치됐습니다. 이 코드가 보이면 WSL 자체를 의심하기 전에 네트워크부터 확인할 만합니다.

### 가상화가 꺼져 있다는 오류

WSL은 설치됐는데 WSL2가 "가상화가 꺼져 있다"며 실행되지 않았습니다. 관리자 PowerShell에서 Windows 기능부터 확인했습니다.

```powershell
Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform | Format-Table FeatureName, State
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux | Format-Table FeatureName, State
```

둘 다 `Enabled`였습니다. 다음으로 부팅 때 하이퍼바이저를 시작하는 설정을 봤습니다.

```powershell
bcdedit /enum "{current}" | findstr /i hypervisorlaunchtype
```

아무 줄도 나오지 않았습니다. Microsoft의 WSL 문제 해결 문서도 `hypervisorlaunchtype`이 `Off`이면 하이퍼바이저가 꺼진 것이라며 `Auto`로 설정하는 방법을 안내합니다. 제 경우는 `Off`가 아니라 줄이 없는 상태였고, 같은 값을 넣은 뒤 재시작하니 WSL2가 동작했습니다.

```powershell
bcdedit /set hypervisorlaunchtype auto
```

`bcdedit`은 관리자 권한이 필요하고, 부팅 설정을 잘못 바꾸면 PC가 정상적으로 켜지지 않을 수 있습니다. BitLocker나 Secure Boot를 쓰는 PC는 먼저 Microsoft 문서의 주의 사항을 확인하세요. 또 이것이 유일한 원인은 아닙니다. BIOS/UEFI의 가상화 설정이나 가상 머신 플랫폼 기능이 꺼져 있어도 비슷한 오류가 날 수 있습니다.

### "시스템 종료"는 재시작이 아니었습니다

가장 헷갈린 부분입니다. 위 설정을 넣고 **시스템 종료 후 전원을 다시 켰는데** 오류가 그대로였습니다. 마지막 부팅 시각을 확인해 보니 바뀌지 않았습니다.

```powershell
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
```

Windows의 **빠른 시작**이 켜져 있으면 시스템 종료는 완전한 종료가 아니라 최대 절전에 가까운 상태가 됩니다. 부팅 설정 변경은 재시작해야 적용되므로, 이 경우에는 시작 메뉴의 **다시 시작**이나 아래 명령을 써야 합니다.

```powershell
shutdown /r /t 0
```

| 동작 | 이 환경에서 일어난 일 |
|---|---|
| 시스템 종료 후 전원 켜기 | 마지막 부팅 시각 그대로, 오류도 그대로 |
| 다시 시작 | 설정이 적용되어 WSL2 동작 |

WSL이나 부팅 설정을 바꾼 뒤 "재부팅했는데 그대로"라면, 어떤 버튼을 눌렀는지와 마지막 부팅 시각부터 확인해 보세요.

## 디스크 위치는 다음 편에서

Docker Desktop은 WSL2 엔진의 데이터를 기본적으로 `%LOCALAPPDATA%\Docker\wsl` 아래에 두고, `Settings → Resources → Advanced`의 **Disk image location**에서 위치를 바꿀 수 있습니다. C: 드라이브 공간이 부족하다면 눈여겨볼 설정입니다. 다만 이 폴더를 탐색기로 열어도 이미지나 볼륨이 낱개 파일로 보이지는 않습니다. 이유는 다음 편에서 자세히 다룹니다.

## 정리

- Linux 컨테이너에는 Linux 커널이 필요하고, Windows에서는 WSL2의 VM이 그 커널을 실행합니다.
- Docker Engine은 `docker-desktop` 배포판에서 돌고, 직접 설치한 `Ubuntu-22.04`는 별개입니다. 그래서 Ubuntu가 `Stopped`여도 컨테이너는 돕니다.
- PowerShell의 `docker`는 클라이언트이고, named pipe를 통해 Docker Desktop을 거쳐 엔진에 요청합니다.
- `docker version`에서 클라이언트 `windows/amd64`, 서버 `linux/amd64`가 함께 보이면 이 구조가 정상 동작하는 것입니다.
- 부팅 설정을 바꿨다면 시스템 종료가 아니라 **다시 시작**을 합니다.

다음 편에서는 이 구조에서 이미지·컨테이너·볼륨이 실제로 어느 폴더에 생기는지 따라가 봅니다.

## 참고 문서

- [Docker Desktop WSL 2 backend](https://docs.docker.com/desktop/features/wsl/)
- [Install Docker Desktop on Windows](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Docker overview](https://docs.docker.com/get-started/docker-overview/)
- [Docker contexts](https://docs.docker.com/engine/manage-resources/contexts/)
- [Comparing WSL versions](https://learn.microsoft.com/en-us/windows/wsl/compare-versions)
- [Install WSL](https://learn.microsoft.com/en-us/windows/wsl/install)
- [Troubleshooting WSL](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting)
- [Containers vs. virtual machines](https://learn.microsoft.com/en-us/virtualization/windowscontainers/about/containers-vs-vm)
- [Named pipes](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipes)
- [BCDEdit /set](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set)
- [Updates may not install with Fast Startup](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/updates-not-install-with-fast-startup)
