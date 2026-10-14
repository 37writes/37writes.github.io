---
title: "CodeCommit git push 403 해결: Git Credential Manager가 만료된 서명을 저장하는 문제"
date: 2026-10-14 15:20:00 +0900
categories: [AWS, Git]
tags: [git, codecommit, credential-helper, gcm, windows, powershell]
description: "Windows에서 CodeCommit에 첫 push는 성공하는데 다음 push부터 403이 나는 원인을 Git 소스 코드로 확인하고, credential.helper 빈 값 초기화로 해결하는 방법을 정리합니다. PowerShell 5.1의 빈 문자열 인자 문제와 403 진단 순서도 다룹니다."
---

## 어떤 문제였나

Windows에서 로컬 폴더를 AWS CodeCommit 저장소에 올리는 중이었습니다. 이상한 일이 연달아 일어났습니다.

1. `git push`를 하면 "Enter your credentials" 로그인 창이 뜬다. **취소하면** push가 성공한다.
2. 그런데 **두 번째 push부터는** 창도 뜨지 않고 바로 `403`이 난다.

결론부터 말하면, **Git Credential Manager(GCM)가 15분짜리 일회용 서명을 저장해 두었다가 다시 내밀어서** 생긴 문제였습니다. 원인을 이해하려면 Git이 CodeCommit에 로그인하는 방식을 먼저 알아야 합니다.

## 배경: Git과 CodeCommit

### Git은 도구, CodeCommit은 서비스

| 구분 | 정체 | 하는 일 |
|---|---|---|
| **Git** | 버전 관리 **도구(프로그램)** | 커밋, 브랜치, 병합, 이력 관리. 내 PC에서 독립적으로 동작 |
| **GitHub / GitLab / CodeCommit** | Git 저장소를 호스팅하는 **서비스** | 원격 백업, 협업, PR, 권한 관리, CI/CD 연동 |

서비스를 바꿔도 Git 명령은 그대로이고 `origin`의 주소만 달라집니다. 차이가 큰 부분은 **인증**입니다.

| | GitHub | GitLab | CodeCommit |
|---|---|---|---|
| 코드 리뷰 | Pull Request | Merge Request | Pull Request |
| CI/CD | GitHub Actions | GitLab CI | CodeBuild / CodePipeline / CodeDeploy |
| 인증 | 토큰, SSH 키 | 토큰, SSH 키 | **IAM 자격증명** |

> CodeCommit은 2024년 7월 신규 고객 가입이 중단되었다가, [2025년 11월 다시 신규 고객에게 열렸습니다](https://aws.amazon.com/blogs/devops/aws-codecommit-returns-to-general-availability). 데이터가 내 AWS 계정 안에 있고 IAM으로 권한을 통합 관리할 수 있다는 점이 장점입니다.
{: .prompt-info }

### Git 설정의 세 가지 범위

이 문제의 원인과 해결 모두 Git 설정 범위와 관련이 있습니다.

| 범위 | 옵션 | 파일 위치 (Windows) | 적용 대상 |
|---|---|---|---|
| system | `--system` | Git 설치 폴더의 `etc\gitconfig` | PC의 모든 사용자 |
| global | `--global` | `C:\Users\<사용자>\.gitconfig` | 내 계정의 모든 저장소 |
| local | `--local` | 저장소 안의 `.git\config` | 그 저장소에만 |

값 하나를 읽을 때는 **local > global > system** 순으로 좁은 범위가 이깁니다. 그런데 `credential.helper`처럼 **여러 값이 쌓이는 설정은 모든 범위의 값이 차례로 모두 쓰입니다.** 이 점이 이번 문제의 핵심입니다.

```powershell
git config --list --show-scope     # 범위와 함께 전체 보기
git config --list --show-origin    # 어느 파일에서 온 값인지 보기
```

## CodeCommit HTTPS 로그인은 어떻게 동작하나

CodeCommit에 HTTPS로 접속하려면 보통 이렇게 설정합니다.

```powershell
git config --local credential.helper '!aws --profile <프로필> codecommit credential-helper $@'
git config --local credential.UseHttpPath true
```

| 설정 | 의미 |
|---|---|
| `credential.helper '!aws ...'` | Git은 로그인 정보를 모르므로 **외부 도우미(aws CLI)** 에게 만들어 달라고 지정. `!`는 "외부 명령 실행", `$@`는 Git이 넘기는 인자 |
| `credential.UseHttpPath true` | CodeCommit은 로그인 값을 만들 때 **저장소 경로(`/v1/repos/...`)까지** 필요. 평소 Git은 서버 이름만 넘기므로 경로까지 넘기게 함 |

로그인은 이렇게 일어납니다.

```text
1. git push → 서버: "누구세요?"
2. Git → aws credential-helper: "로그인 정보 줘"
3. aws가 프로필의 Access Key로 서명한 "일회용 비밀번호"를 만들어 Git에 전달
4. Git이 그 값으로 로그인
```

여기서 중요한 사실은, CodeCommit의 "비밀번호"가 **Access Key로 만든 시간 제한 서명(약 15분)** 이라는 점입니다. 저장해 두었다가 나중에 다시 쓰면 반드시 실패합니다.

- PowerShell에서는 **작은따옴표**로 감싸야 `$@`가 변수로 해석되지 않습니다.
- 이 설정에는 키 값이 들어가지 않으므로 화면에 보여도 안전합니다.

> 사내 프록시가 SSL을 검사하는 환경이라면 `git config --local http.sslCAInfo <사내CA.pem>`도 필요합니다. 원리는 [AWS CLI CERTIFICATE_VERIFY_FAILED 해결기]({% post_url 2026-10-14-aws-cli-certificate-verify-failed %})에서 설명했습니다.
{: .prompt-tip }

## 원인 1: 로그인 창이 뜨는 이유

Git for Windows는 **system 범위**에 GCM(`credential.helper=manager`)이 기본으로 들어 있습니다. 그리고 도우미는 **위에서부터 차례로** 호출됩니다.

```text
① system: manager (GCM) → 로그인 창을 띄움
     ├ 값을 입력하면 → 그 값으로 인증 시도
     └ 취소하면      → "정보 없음" → Git이 다음 도우미로 넘어감
② local: !aws ...      → 키로 서명한 로그인 값 생성 → 성공
```

그래서 창을 **취소하면** AWS 도우미로 넘어가 push가 성공했던 것입니다.

> 창의 Password 칸에 **AWS Secret Key를 넣으면 안 됩니다.** CodeCommit HTTPS 로그인은 키로 만든 서명이어야 해서 로그인도 되지 않고, Windows 자격 증명 관리자에 Secret Key만 저장됩니다.
{: .prompt-danger }

## 원인 2: 두 번째 push부터 403이 나는 이유

Git은 인증에 성공하면 **등록된 모든 도우미에게 "이 로그인 값을 저장해(store)"라고 알립니다.**

```text
[첫 push 성공 후]
   ├ !aws 도우미  : 저장 기능 없음 (매번 새로 만들어 줌)
   └ manager(GCM) : 받아서 Windows 자격 증명 관리자에 저장  ← 문제

[두 번째 push]
   GCM이 먼저 호출됨 → 저장해 둔 값을 그대로 줌
   → 이미 만료된 15분짜리 서명 → 서버가 403
```

그렇다면 실패한 값을 Git이 지워 주지는 않을까요? Git 소스 코드(`http.c`)를 확인해 보면, 저장된 자격증명을 폐기(`credential_reject`)하는 건 **HTTP 401일 때뿐**입니다. 403은 일반 오류로 처리되어 폐기 신호가 가지 않습니다. 그래서 만료된 값이 계속 남아 **같은 403이 반복**됩니다.

정리하면 이렇습니다.
- 창을 취소하면 AWS 도우미로 넘어가 성공합니다.
- 하지만 **성공한 뒤에 GCM이 그 값을 저장하므로** 다음 push가 실패합니다.
- 저장된 값을 지워도 다음 성공 때 또 저장됩니다.

### 확인 방법

```powershell
cmdkey /list | Select-String "git-codecommit"
```

`Target: git:https://git-codecommit...` 줄이 보이면 이 문제가 맞습니다. 임시로는 그 항목을 지우면 됩니다.

```powershell
cmdkey /delete:"git:https://git-codecommit.<region>.amazonaws.com"
```

출력의 `User:` 값(Access Key ID)은 다른 사람에게 공유할 때 가립니다.

## 해결: 도우미 목록을 빈 값으로 초기화

`credential.helper`에 **빈 값**을 넣으면, 그 앞에 쌓인 도우미 목록(system의 GCM 포함)이 비워집니다. 빈 값 **이후**에 등록한 도우미만 쓰이므로, GCM은 호출되지도 않고 저장 신호도 받지 않습니다.

```powershell
git config --local --unset-all credential.helper
git config --local --add credential.helper '""'
git config --local --add credential.helper '!aws --profile <프로필> codecommit credential-helper $@'
git config --local credential.UseHttpPath true

# 확인
git config --show-scope --get-all credential.helper
```

기대하는 출력은 `system manager` → `local (빈 줄)` → `local !aws ...` 순서입니다. **빈 값이 반드시 `!aws`보다 먼저** 와야 합니다.

창을 없애는 편의 기능처럼 보이지만, 이 환경에서는 **403을 막기 위해 필수**입니다.

### `error: wrong number of arguments, should be 2`가 나온다면

Windows PowerShell 5.1은 외부 프로그램에 **빈 문자열 `""` 인자를 넘기지 않고 버립니다.** 그래서 Git에는 `--add credential.helper`까지만 전달되어 인자가 모자랍니다. 명령 자체의 문제가 아닙니다.

- 해결 1: 위 예시처럼 따옴표를 한 겹 더 씌웁니다: `'""'`
- 해결 2: `.git\config`를 직접 편집합니다.

  ```ini
  [credential]
  	helper =
  	helper = !aws --profile <프로필> codecommit credential-helper $@
  	UseHttpPath = true
  ```

  `helper =` 뒤에 아무것도 없는 줄이 빈 값입니다. `[credential]` 섹션이 둘로 나뉘지 않게 합니다.

확인했을 때 빈 줄 대신 `""`(따옴표 두 글자)가 그대로 보이면 값이 잘못 들어간 것이니 해결 2를 쓰세요.

### 대안: git-remote-codecommit

Credential Manager를 아예 거치지 않는 방법도 있습니다.

```powershell
pip install git-remote-codecommit
git remote set-url origin codecommit::<region>://<프로필>@<저장소>
```

## 403 진단 순서

`403`은 **서버까지 도달했다**는 뜻입니다. 인증서(SSL) 검증은 이미 통과했고, 인증이나 권한 문제입니다.

| 순서 | 확인 | 방법 |
|---|---|---|
| 1 | 저장소가 존재하는가 | `aws codecommit get-repository --repository-name <저장소> --profile <프로필>` |
| 2 | 도우미 설정이 올바른가 | `git config --show-scope --get-all credential.helper` |
| 3 | 캐시된 만료 값이 있는가 (**한 번 성공한 뒤부터 403**이면 1순위) | `cmdkey /list \| Select-String "git-codecommit"` |
| 4 | IAM 권한이 있는가 | 아래 시뮬레이션 |
| 5 | 요청 흐름 보기 | `$env:GIT_TRACE=1; $env:GIT_CURL_VERBOSE=1; git push` |

IAM 권한은 시뮬레이션으로 확인할 수 있습니다. 사용자 이름을 직접 입력하지 않도록 ARN에서 뽑아 씁니다.

```powershell
$P = "<프로필>"
$arn = aws sts get-caller-identity --profile $P --query Arn --output text

aws iam simulate-principal-policy --policy-source-arn $arn `
  --action-names codecommit:GitPush codecommit:GitPull `
  --profile $P --query "EvaluationResults[].[EvalActionName,EvalDecision]" --output table
```

| 결과 | 의미 | 조치 |
|---|---|---|
| 저장소 없음 | push할 곳이 없음 | `create-repository` 후 재시도 |
| `implicitDeny` / `explicitDeny` | 권한 부족 | 관리자에게 `codecommit:GitPull`, `GitPush` 요청 (대상 저장소를 한정하면 최소 권한) |
| 모두 `allowed`인데 403 | 캐시나 도우미 문제 | 캐시 삭제 후 도우미 초기화 |

- `aws sts get-caller-identity`가 성공하면 **키 자체는 정상**입니다.
- `list-repositories`(조회)가 되는 것과 `GitPush`(쓰기)는 **별개 권한**입니다.
- PC 시계가 15분 이상 어긋나도 서명이 무효가 되어 403이 납니다.

## 덤: 보안 습관

- 에디터에서 `credentials` 파일을 열고 줄을 선택한 채로 AI 도구에 질문하면, **선택 영역이 자동으로 첨부될 수 있습니다.** 키가 노출되었다면 바로 교체합니다 (새 키 발급 → 반영 → 기존 키 비활성화 → 삭제).
- 명령 결과를 공유할 때는 **계정 ID(12자리), 사용자명, 이메일, 키처럼 보이는 값**을 가립니다.
- `--no-verify-ssl`처럼 보안 설정을 끄는 방식으로 오류를 넘기지 말고 원인을 해결합니다.
- 실험이 끝나 저장소를 지울 때는 **이름을 꼭 확인**합니다. 삭제는 되돌릴 수 없습니다.

## 정리

- CodeCommit HTTPS 로그인은 **credential helper가 Access Key로 만든 약 15분짜리 서명**으로 합니다. Secret Key를 직접 입력하지 않습니다.
- Git for Windows의 system 범위에는 GCM이 있고, 도우미는 **차례로 모두** 호출됩니다.
- 인증에 성공하면 Git은 **모든 도우미에게 값을 저장**시킵니다. GCM이 만료될 서명을 저장하면 다음 push가 403이 됩니다.
- Git은 **401일 때만** 저장된 값을 폐기합니다. 403은 폐기하지 않아 같은 오류가 반복됩니다.
- 해결책은 **빈 값으로 도우미 목록을 초기화**해 GCM을 빼는 것입니다. PowerShell 5.1에서는 `'""'`로 쓰거나 `.git\config`를 직접 편집합니다.
