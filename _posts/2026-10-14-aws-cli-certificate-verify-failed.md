---
title: "AWS CLI CERTIFICATE_VERIFY_FAILED 해결기: 사내 프록시, CA 신뢰 사슬, 그리고 자격증명 관리"
date: 2026-10-14 15:10:00 +0900
categories: [AWS, 보안]
tags: [aws, aws-cli, iam, sts, tls, certificate, proxy]
description: "사내 프록시 환경에서 AWS CLI가 CERTIFICATE_VERIFY_FAILED를 내는 원인과 ca_bundle로 해결하는 방법, 그리고 그 과정에서 정리한 IAM·STS 자격증명 방식과 TLS 인증서 신뢰 구조를 설명합니다."
---

## 어떤 문제였나

회사 PC에서 AWS CLI로 S3 목록을 조회했더니 이런 오류가 났습니다.

```text
SSL validation failed for https://s3.ap-northeast-2.amazonaws.com/
[SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate
```

처음에는 키가 잘못된 줄 알았지만, 이 오류는 **자격증명(키) 문제가 아니라 인증서 신뢰 문제**입니다. 원인을 이해하려면 TLS 인증서가 어떻게 신뢰를 얻는지부터 알아야 했고, 그 김에 AWS 자격증명 관리 방식도 함께 정리했습니다.

이 글의 순서는 다음과 같습니다.

1. TLS 인증서의 신뢰 구조 (CA, 신뢰 사슬, 신뢰 저장소)
2. 사내 프록시가 있으면 왜 오류가 나는가
3. 해결 방법
4. 덤: AWS 자격증명 관리 방식과 IAM·STS 관계

## 1. 인증서는 어떻게 신뢰를 얻는가

### SSL/TLS와 SSH는 다르다

먼저 자주 헷갈리는 두 가지를 구분합니다.

| | SSL/TLS | SSH |
|---|---|---|
| 용도 | 웹/API 통신 **암호화** (HTTPS) | 원격 서버 **로그인·명령 실행·파일 전송** |
| 예시 | 브라우저, `aws` CLI, REST API | 서버 터미널 접속, `git@github.com` |
| 신원 확인 | 서버가 **인증서**를 제시하고, 클라이언트가 그 인증서를 서명한 **CA를 믿는지** 검증 | 서버 **호스트 키**를 최초 접속 때 저장, 로그인은 비밀번호나 키 파일 |
| 기본 포트 | 443 | 22 |

SSL은 옛 이름이고 지금은 후속 버전인 TLS를 씁니다. 관행적으로 둘 다 "SSL"이라고 부릅니다. AWS CLI의 통신은 HTTPS, 즉 TLS입니다.

### CA와 신뢰의 사슬

인터넷에서는 "이 서버가 진짜 AWS 서버인가?"를 확인할 방법이 필요합니다. 이때 **CA(인증기관)** 가 공증인 역할을 합니다. CA가 "이 인증서의 주인은 진짜 이 서버다"라고 서명해 주는 것입니다.

```text
Root CA               ← 신뢰의 출발점. 스스로 서명(self-signed)
  └ Intermediate CA      ← Root가 서명해 준 실무 발급 기관
       └ 서버 인증서        ← 실제 서버가 제시하는 인증서
```

클라이언트가 Root CA를 믿으면, 그 아래에서 발급된 인증서를 모두 믿게 됩니다.

### 신뢰 저장소(Trust Store)는 프로그램마다 다르다

여기가 이번 문제의 핵심입니다. "믿을 Root CA 목록"은 프로그램마다 따로 갖고 있습니다.

| 프로그램 | 쓰는 신뢰 목록 |
|---|---|
| Windows, Edge, Chrome | **Windows 인증서 저장소** (`certmgr`, `Cert:\LocalMachine\Root`) |
| AWS CLI, Python | **자체 번들** (certifi) |

Amazon, DigiCert 같은 공개 Root CA는 양쪽 모두에 기본으로 들어 있습니다. 하지만 **사내 CA는 보통 IT 부서가 Windows 저장소에만 배포**합니다.

## 2. 사내 프록시가 있으면 왜 오류가 나는가

평소에는 이렇게 동작합니다.

```text
내 PC ─────── TLS ───────► AWS 서버
   AWS가 Amazon 인증서 제시 → CLI 번들에 Amazon Root 있음 → 통과
```

그런데 많은 회사가 보안 장비로 **SSL Inspection**을 합니다. 프록시가 암호화된 트래픽을 열어 악성코드나 정보 유출을 검사하는 구조입니다.

```text
내 PC ──TLS①──► 사내 프록시 ──TLS②──► AWS 서버
         │
         └ 프록시가 "AWS 서버인 척" 인증서를 즉석에서 만들어
           사내 CA로 서명해 제시
```

- **브라우저**는 Windows 저장소에 사내 Root CA가 있으므로 통과합니다.
- **AWS CLI**는 자체 번들에 사내 Root CA가 없으므로 "모르는 CA가 서명했다"며 거부합니다. 이것이 `CERTIFICATE_VERIFY_FAILED`입니다.

브라우저로는 AWS 콘솔이 잘 열리는데 CLI만 실패한다면 이 구조를 의심하면 됩니다. `HTTPS_PROXY` 환경변수가 설정되어 있다면 의심 1순위입니다.

> 이 구조에서는 프록시가 통신 내용을 복호화해 볼 수 있습니다. 회사 보안 정책 범위의 일이지만, 알고는 있는 게 좋습니다.
{: .prompt-info }

### 흔한 오해

- "AWS가 회사 CA를 모른다"가 **아니라** "**내 PC의 AWS CLI**가 회사 CA를 모른다"입니다.
- 사내 CA를 등록하는 것은 AWS에 무언가를 알리는 게 아니라, **내 CLI의 신뢰 목록에 추가**하는 것입니다. AWS 서버 쪽은 아무것도 바뀌지 않습니다.

## 3. 해결 방법

### ① 사내 Root CA가 Windows 저장소에 있는지 확인

보통 IT 부서가 이미 배포해 두었습니다. 보안 담당 부서에 요청하기 전에 먼저 확인해 봅니다.

```powershell
Get-ChildItem Cert:\LocalMachine\Root |
  Where-Object { $_.Subject -match '<회사 이름 일부>' } |
  Select-Object Subject, NotAfter, Thumbprint
```

### ② 공개 인증서를 PEM으로 내보내기

**공개 인증서만** 내보냅니다. 개인키는 다루지 않습니다. 중간 CA가 있다면 함께 한 파일에 이어 붙입니다.

```powershell
$c = Get-Item "Cert:\LocalMachine\Root\<Thumbprint>"
("-----BEGIN CERTIFICATE-----`n" +
  [Convert]::ToBase64String($c.RawData, 'InsertLineBreaks') +
  "`n-----END CERTIFICATE-----") | Out-File -Encoding ascii $HOME\.aws\company-ca.pem
```

### ③ AWS CLI에 알려주기

프로필별로 지정하는 방법을 권장합니다.

```ini
# ~/.aws/config
[profile dev]
region = ap-northeast-2
ca_bundle = C:\Users\<사용자>\.aws\company-ca.pem
```

또는 환경변수 `AWS_CA_BUNDLE=<pem 경로>`를 씁니다. 터미널 세션에만 적용할 수도 있고, 사용자 환경변수로 등록해 영구 적용할 수도 있습니다.

### ④ 확인

```powershell
aws sts get-caller-identity --profile dev
```

### 주의할 점

- **`--no-verify-ssl`로 검증을 끄면 안 됩니다.** 오류는 사라지지만 중간자 공격에 그대로 노출됩니다.
- `ca_bundle`과 `AWS_CA_BUNDLE`은 기본 신뢰 목록에 **추가되는 게 아니라 대체**합니다. 그래서 프록시를 거치지 않는 환경(집 등)에서는 오히려 실패할 수 있습니다. 그럴 때는 해당 줄을 주석 처리하거나, 공개 CA 번들과 사내 CA를 한 파일에 합쳐 씁니다.
- 사내 인증서에도 **만료일**이 있습니다. 만료 전에 다시 내보내야 합니다.
- 파일은 PEM 형식이어야 합니다. `.cer`/`.crt`가 DER(바이너리) 형식이면 변환이 필요합니다.

## 4. 덤: AWS 자격증명 관리 방식 정리

인증서 문제를 해결하고 나니 `credentials` 파일 자체도 다시 보게 되었습니다. AWS에서 자격증명을 쓰는 방식은 크게 네 가지이고, 건물 출입증에 비유하면 이해하기 쉽습니다.

| # | 방식 | 한 줄 설명 | 만료 | 주 용도 |
|---|---|---|---|---|
| 1 | **IAM Identity Center (SSO)** | 회사 계정(+MFA)으로 로그인하면 **임시 키** 자동 발급 | 수 시간 | 사람이 CLI/콘솔 쓸 때 (가장 권장) |
| 2 | **IAM Role** (EC2/ECS/Lambda 등) | 서버나 서비스에 붙이는 출입증. 파일로 저장할 키가 없음 | 자동 갱신 | AWS 안에서 도는 워크로드 |
| 3 | **AssumeRole (STS)** | 평소 권한에서 **잠깐 다른 Role의 권한을 빌림** | 보통 1시간 | 계정 간 접근, 권한 상승 |
| 4 | **IAM User Access Key** | ID/Secret 쌍을 파일에 저장해 영구 사용 | **없음** (삭제 전까지) | 위 방법이 불가능할 때만 |

- `credentials` 파일에 `aws_access_key_id`/`aws_secret_access_key`가 있다면 4번 방식입니다.
- 영구 키는 `AKIA...`, 임시 키는 `ASIA...`로 시작하고, 임시 키에는 **Session Token**이 추가로 붙습니다.
- 4번은 유출되면 누구나 내 권한을 그대로 쓸 수 있어서, 가장 흔한 AWS 보안 사고의 원인입니다.

### 4번(영구 키)을 써야 한다면

- 최소 권한 원칙: 필요한 Action과 Resource만 허용합니다.
- 사용자에 MFA를 설정합니다.
- **90일마다 교체**하고, 안 쓰는 키는 삭제합니다. 사용자당 키를 2개까지 가질 수 있어서 무중단 교체가 가능합니다.
- `credentials` 파일은 본인만 읽을 수 있게 권한을 제한합니다.
- 코드, `.env`, 저장소, 채팅에 키를 붙여넣지 않습니다 (`.gitignore`에 `.aws/`, `.env`).
- 앱에서 쓰는 시크릿은 Secrets Manager나 SSM Parameter Store(SecureString)에 둡니다.

### IAM, Policy, Role, STS의 관계

| 개념 | 정체 | 비유 |
|---|---|---|
| **IAM** | 누가 무엇을 할 수 있는지 관리하는 서비스 전체 | 건물 보안 관리 시스템 |
| **Policy** | 허용/거부를 적은 **권한 규칙 문서(JSON)** | 출입 규칙표 |
| **User / Role** | Policy가 붙는 **주체(신분)** | 사원증 / 임시 출입증 틀 |
| **STS** | Role을 쓸 수 있게 **임시 토큰을 발급**하는 창구 | 임시 출입증 발급 데스크 |

Policy는 혼자서는 효력이 없고, User나 Role에 **붙어야(attach)** 적용됩니다.

```json
{
  "Effect": "Allow",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::my-bucket/*"
}
```

- **User**는 특정 사람에게 고정된 신분입니다. Policy가 직접 붙고 영구 키를 가집니다.
- **Role**은 주인이 없는 빈 신분입니다. 조건을 만족하는 누구든 잠시 입을 수 있고, 영구 키가 없습니다.

Role에는 Policy가 두 종류 붙습니다.

1. **Permission Policy**: 이 Role을 입으면 **무엇을 할 수 있는가**
2. **Trust Policy**: **누가 이 Role을 입을 수 있는가** (`sts:AssumeRole`을 허용할 대상)

```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::<계정ID>:user/<사용자>" },
  "Action": "sts:AssumeRole"
}
```

AssumeRole은 이런 순서로 동작합니다.

```text
1. 나(User)가 STS에 요청: "AdminRole을 입고 싶다" (sts:AssumeRole)
2. AWS가 양쪽을 확인
   ├ Role의 Trust Policy : 이 사람이 입어도 되는가?
   └ 내 User의 Policy    : 나에게 sts:AssumeRole 호출 권한이 있는가?
3. 둘 다 통과 → STS가 임시 키 발급 (예: 1시간)
4. 임시 키로 작업 → 그 Role의 Permission Policy 권한만 적용
5. 시간이 지나면 자동 만료
```

양쪽 모두 허용해야 성공하고, 어느 한쪽에라도 명시적 `Deny`가 있으면 실패합니다.

### `credentials`와 `config` 관리 습관

계정이나 용도별로 **프로필을 분리**합니다. 두 파일은 헤더 표기가 다르니 주의합니다.

```ini
# ~/.aws/credentials  (키 — 절대 공유 금지)
[dev]
aws_access_key_id = ****
aws_secret_access_key = ****
```

```ini
# ~/.aws/config  (키가 아닌 설정, default 외에는 "profile " 접두어)
[profile dev]
region = ap-northeast-2
output = json
```

```powershell
aws s3 ls --profile dev           # 명령마다 프로필 지정
$env:AWS_PROFILE = "dev"          # 터미널 세션 동안 고정
aws sts get-caller-identity       # 지금 어느 계정·사용자인지 확인 (작업 전 습관)
```

- `[default]`에는 가장 안전한 계정(읽기 전용이나 개발용)을 두거나 비워 둡니다. `--profile`을 빼먹었을 때 사고를 막아 줍니다.
- 같은 키를 여러 프로필에 중복 저장하지 않습니다. 교체하거나 폐기할 때 빠뜨리기 쉽습니다.
- 키 현황은 `aws iam list-access-keys --user-name <사용자명>`으로 점검하고, `CreateDate`가 오래되었으면 교체합니다.

### 키가 유출되었다면

1. 해당 키를 즉시 **비활성화한 뒤 삭제**합니다.
2. **CloudTrail**로 그 키가 한 활동을 확인합니다.
3. 의심스러운 리소스(EC2, IAM 사용자·Role)를 정리합니다.
4. 새 키를 발급하고, 필요하면 AWS Support에 신고합니다.

평소에는 IAM Access Analyzer(과도한 권한), GuardDuty(비정상 사용 탐지), Billing Alarm(비용 급증으로 유출 감지)으로 모니터링할 수 있습니다.

### 덤의 덤: Windows에서 AWS CLI 업데이트

AWS CLI v2는 Windows에 별도 `update` 명령이 없습니다. 공식 MSI를 다시 받아 덮어 설치하면 되고, `credentials`와 `config`는 그대로 유지됩니다.

```powershell
aws --version
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
```

## 정리

- `CERTIFICATE_VERIFY_FAILED`의 본질은 **"서명한 CA를 클라이언트가 모른다"** 입니다. 해결책은 클라이언트의 신뢰 목록에 그 CA를 추가하는 것입니다.
- 브라우저와 AWS CLI는 **서로 다른 신뢰 목록**을 씁니다. 사내 프록시 환경에서 CLI만 실패한다면 사내 Root CA를 `ca_bundle`에 지정합니다.
- 검증을 끄는 `--no-verify-ssl`은 해결책이 아닙니다.
- 자격증명은 **임시 키(SSO, Role, AssumeRole)를 영구 키보다 우선**합니다.
- **Policy는 규칙 문서, User/Role은 규칙이 붙는 주체, STS는 Role을 빌릴 때 임시 키를 주는 창구**입니다.
- 작업 전에는 `aws sts get-caller-identity`로 지금 어느 계정인지 확인하는 습관을 들입니다.
