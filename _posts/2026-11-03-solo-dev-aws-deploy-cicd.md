---
title: "CDK 손 배포 스크립트를 CI/CD 전에 다듬기: synth·diff·deploy 세 모드와 자동화 점검 목록"
date: 2026-11-03 15:00:00 +0900
categories: [AWS, 배포]
tags: [aws, cdk, fargate, deploy, ci-cd, github-actions, oidc, shell]
description: "Fargate API를 아직 로컬 스크립트로 배포하는 1인 개발자가 CI/CD 전에 해 둔 일을 정리합니다. synth·diff·deploy 세 모드, 오프라인 합성, rm -rf 전 경로 검사, amplify_outputs.json 순서 의존, 자동화할 때 바꿀 점검 목록을 다룹니다."
---

> **시리즈: 1인 개발자의 AWS 배포**
> 1. [구조: 웹은 Amplify Hosting, API는 Fargate]({% post_url 2026-10-29-solo-dev-aws-deploy-architecture %})
> 2. [실제로 부딪힌 배포 함정들과 해결]({% post_url 2026-10-29-solo-dev-aws-deploy-pitfalls %})
> 3. **CI/CD 전에: 손 배포 스크립트 다듬기와 자동화 계획** ← 지금 글

## 지금 어디까지 왔나

혼자 만든 사내 웹 서비스를 AWS에 올렸습니다. 웹은 Amplify Hosting, API는 CloudFront → ALB → Fargate 구조입니다. 왜 이렇게 골랐는지는 1편에서, 올리면서 부딪힌 함정은 2편에서 정리했습니다.

이 시리즈의 마지막 편은 원래 "API 배포를 GitHub Actions로 자동화한 이야기"가 될 예정이었습니다. 그런데 **자동화는 아직 하지 않았습니다.** API는 지금도 제 Mac에서 배포 스크립트로 올립니다. 대신 자동화로 옮기기 전에, 손으로 돌리는 스크립트를 실수하기 어려운 모양으로 다듬어 두었습니다.

이 글은 그 두 가지를 다룹니다.

- 손 배포 스크립트를 `--synth`·`--diff`·`--deploy` 세 모드로 나누고 안전장치를 넣은 방법과 이유
- CI/CD로 옮길 때 무엇을 바꿔야 하는지 점검 목록 (**아직 구현하지 않은 계획**입니다)

아직 로컬 스크립트로 배포하면서 "언제, 어떻게 자동화하지"를 고민하는 분께 도움이 되면 좋겠습니다. (서비스 이름, 리소스 이름, 계정 정보는 예시 값으로 바꿨습니다. 코드도 개념을 보여 주는 최소 예시로 새로 썼습니다.)

## 지금 배포 경로는 셋, CI는 검사만

<figure class="diagram">
{% include figures/solo-dev-aws-deploy-cicd/deploy-paths.svg %}
<figcaption>자동으로 배포되는 것은 웹뿐입니다. 백엔드와 API는 사람이 순서대로 올리고, CI는 검사만 합니다.</figcaption>
</figure>

- **웹**: `main`에 push하면 Amplify Hosting이 빌드·배포합니다. `amplify.yml`에는 frontend 단계만 있습니다.
- **백엔드**(Cognito·DynamoDB·S3): 바뀔 때 제가 `ampx sandbox --once`로 올립니다.
- **API**(Fargate CDK 스택): 제가 `deploy.sh`로 올립니다.
- **CI**(GitHub Actions): push와 PR마다 typecheck, lint, test를 돌립니다. 배포 단계는 없습니다.

세 경로는 서로 독립이 아닙니다. 백엔드를 배포하면 `amplify_outputs.json`이 생기고, 웹 빌드와 API 배포 스크립트가 둘 다 이 파일을 읽습니다. 이 순서 문제는 아래 "백엔드와 API 사이의 순서"에서 다룹니다.

## 배포 스크립트를 세 모드로 나눴다

처음 배포 스크립트는 실행하면 끝까지 갔습니다. 소스를 복사하고, 이미지를 만들고, 스택을 바꿉니다. 중간에 "AWS 없이 템플릿만 확인하고 싶다"거나 "무엇이 바뀌는지만 보고 싶다"는 선택지가 없었습니다. 그래서 인자로 어디까지 갈지 고르게 했습니다. 한 번에 만들지는 않았습니다. `--synth`와 아래의 경로 검사를 먼저 넣고, `--diff`는 그다음에 추가했습니다.

```sh
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---deploy}"          # 인자가 없으면 --deploy
case "$MODE" in
  --synth|--diff|--deploy) ;;
  *) echo "usage: deploy.sh [--synth|--diff|--deploy]" >&2; exit 2 ;;
esac
```

모르는 인자는 사용법을 출력하고 **종료 코드 2**로 끝냅니다. 그래서 오타(`--dif`)가 기본값인 `--deploy`로 흘러가지 않습니다. 배포 실패(1)와 사용법 오류(2)를 종료 코드로 나눠 두면, 나중에 CI 로그에서도 "스크립트를 잘못 불렀다"와 "배포가 실패했다"를 구분할 수 있습니다.

인자 없이 실행하면 `--deploy`가 된다는 점은 주의할 부분입니다. 모드를 넣기 전처럼 `bash deploy.sh` 한 줄로 배포할 수 있지만, 그만큼 인자를 빠뜨리면 바로 적용까지 갑니다. 자동화할 때는 모드를 늘 명시하는 편이 안전합니다.

세 모드는 같은 준비 단계를 지나고, 어디서 멈추느냐만 다릅니다.

<figure class="diagram">
{% include figures/solo-dev-aws-deploy-cicd/three-modes.svg %}
<figcaption>세 모드는 같은 준비 단계를 지나고 멈추는 곳만 다릅니다. synth는 AWS를 부르지 않고, diff는 스택을 바꾸지 않으며, 스택을 바꾸는 것은 deploy뿐입니다.</figcaption>
</figure>

## `--synth`: AWS에 닿지 않는 합성

`--synth`는 CDK 앱을 CloudFormation 템플릿으로 합성만 하고 끝납니다. 스택 코드를 고친 뒤 "합성이 깨지지 않는지, 템플릿이 생각한 모양인지"를 AWS 자격 증명 없이 확인하려고 만들었습니다.

그런데 그냥 `cdk synth`를 돌리면 AWS에 닿는 곳이 두 군데 있었습니다.

1. **계정 ID.** 스크립트는 다른 모드에서 `aws sts get-caller-identity`로 계정 ID를 읽어 `CDK_DEFAULT_ACCOUNT`에 넣습니다. 이 호출은 자격 증명이 있어야 합니다.
2. **가용 영역(AZ) 조회.** 스택에 계정과 리전을 정해 두면, VPC를 만들 때 CDK가 그 계정·리전의 AZ 목록을 조회합니다. CDK는 이렇게 AWS에서 읽어 온 값을 **컨텍스트**로 `cdk.context.json`에 저장해 두고 다음 합성부터 그 값을 씁니다 ([CDK 문서: Context values](https://docs.aws.amazon.com/cdk/v2/guide/context.html)).

그래서 `--synth`에서는 둘 다 막았습니다.

```sh
if [[ $MODE == --synth ]]; then
  # 계정은 환경변수로 직접 받는다 (STS를 부르지 않는다)
  : "${CDK_DEFAULT_ACCOUNT:?--synth needs CDK_DEFAULT_ACCOUNT}"
  R="$CDK_DEFAULT_REGION"
  # 오프라인 합성용 AZ 고정값. staging 폴더 안에만 쓴다
  printf '{"availability-zones:account=%s:region=%s": ["%sa", "%sc"]}\n' \
    "$CDK_DEFAULT_ACCOUNT" "$R" "$R" "$R" > cdk.context.json
  npx cdk synth --lookups=false --quiet
  exit 0
fi
```

```sh
CDK_DEFAULT_ACCOUNT=123456789012 bash deploy.sh --synth
```

- **계정 ID를 환경변수로 받습니다.** 없으면 바로 멈춥니다. 예시 값을 넣어도 합성은 됩니다.
- **AZ 두 개를 고정한 컨텍스트 파일**을 미리 써 둡니다. 키 형식(`availability-zones:account=...:region=...`)은 CDK 문서에 나온 형식 그대로입니다.
- **`--lookups=false`**: 컨텍스트 조회를 하지 않습니다. 조회가 필요한 값이 빠져 있으면 합성이 실패합니다 ([CDK CLI 전역 옵션](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd.html)). 고정값을 빠뜨렸을 때 몰래 AWS를 부르지 않고 실패로 드러나게 하려는 것입니다.
- 합성이 끝나면 바로 `exit 0`이므로 bootstrap, 이미지 빌드·push, 배포 단계까지 가지 않습니다.

여기서 하나 조심할 점이 있습니다. CDK 문서는 `cdk.context.json`의 캐시 값을 **손으로 고치지 말라**고 안내합니다. AZ 같은 값은 계정에서 읽어 와야 정확하기 때문입니다. 제 고정값은 오프라인 확인용 가짜 값이므로, 이 값이 실제 배포에 섞이면 안 됩니다. 스크립트는 staging 폴더를 실행할 때마다 지우고 새로 만들기 때문에, `--synth`에서 쓴 파일이 다음 `--deploy`로 넘어가지 않습니다. 같은 이유로 `--synth`로 만든 템플릿은 "합성이 되는지"를 보는 용도이고, 실제 배포될 템플릿과 AZ 이름까지 같다고 보면 안 됩니다.

## `--diff`: 바꾸지 않고 미리 보기

`--diff`는 계정 ID를 STS로 읽은 뒤 `cdk diff`만 돌리고 끝납니다.

```sh
export CDK_DEFAULT_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

if [[ $MODE == --diff ]]; then
  npx cdk diff || true    # 미리보기는 결과와 상관없이 0으로 끝낸다
  exit 0
fi
```

`|| true`를 붙인 이유는 스크립트 맨 위의 `set -e` 때문입니다. `cdk diff`는 `--fail` 옵션을 주면 차이가 있을 때 종료 코드 1로 끝납니다 ([CDK 문서: cdk diff](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-diff.html)). 어떤 이유로든 `cdk diff`가 0이 아닌 값으로 끝나면 `set -e`가 스크립트를 그 자리에서 멈춥니다. 미리보기는 "보는" 단계이니 결과를 끝까지 보여 주고 정상 종료하게 했습니다.

대가도 있습니다. `|| true`는 **진짜 오류도 삼킵니다.** 자격 증명이 만료됐거나 합성이 실패해도 스크립트는 0으로 끝납니다. 사람이 터미널에서 출력을 읽을 때는 괜찮지만, CI에서 "미리보기 단계 통과"를 근거로 다음 단계를 진행한다면 위험합니다. 자동화할 때 가장 먼저 고칠 줄입니다.

"스택은 바꾸지 않는다"는 말도 정확히 해 둘 필요가 있습니다. `cdk diff`는 기본값(`--method auto`)에서 정확한 교체 정보를 보여 주려고 CloudFormation **변경 세트(change set)**를 만들고, 만들 수 없으면 템플릿끼리만 비교합니다. 문서의 예시 출력을 보면 비교 전에 자산을 빌드하고 게시하는(Building, Publishing) 줄도 찍힙니다. 배포된 리소스는 바뀌지 않지만, AWS에 아무것도 하지 않는 명령은 아니라는 뜻입니다. 그래서 `--diff`에도 자격 증명이 필요합니다.

## `--deploy`: 매번 bootstrap, 승인 프롬프트는 끔

기본값인 `--deploy`는 세 단계입니다.

```sh
# 1) bootstrap: 이미 돼 있으면 필요할 때만 갱신, 아니면 아무 일도 없음
npx cdk bootstrap "aws://$CDK_DEFAULT_ACCOUNT/$CDK_DEFAULT_REGION"

# 2) 적용: 확인 프롬프트 없이, 스택 출력을 파일로 남긴다
npx cdk deploy --require-approval never --outputs-file "$SRC/outputs.json"

# 3) 웹 빌드에 넣을 API 주소를 출력
node -e 'console.log(require(process.argv[1]).MyApiStack.ApiUrl)' "$SRC/outputs.json"
```

**bootstrap을 매번 돌립니다.** CDK 문서는 환경을 여러 번 bootstrap해도 괜찮다고 안내합니다. 이미 bootstrap된 환경이면 필요할 때만 bootstrap 스택을 갱신하고, 아니면 아무 일도 하지 않습니다 ([CDK 문서: Bootstrap your environment](https://docs.aws.amazon.com/cdk/v2/guide/bootstrapping-env.html)). 손으로 배포할 때는 "이 계정·리전은 bootstrap했던가"를 기억할 필요가 없어서 편했습니다. 다만 제 원래 스크립트는 bootstrap 출력을 몇 줄만 남기고 실패도 무시하게(`|| true`) 해 두었습니다. 이러면 bootstrap이 실패해도 다음 `cdk deploy`에서야 "bootstrap이 안 됐다"는 오류로 드러납니다.

**`--require-approval never`의 뜻.** `cdk deploy`의 기본값은 `broadening`입니다. 권한(IAM)이나 보안 그룹 규칙이 **넓어지는** 변경이면 적용 전에 사람에게 확인을 받습니다. `never`는 이 확인을 끕니다 ([CDK 문서: cdk deploy](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-deploy.html)). 스크립트가 중간에 멈춰 입력을 기다리지 않게 하려고 껐습니다.

그러면 승인은 어디서 하나요. 지금은 **사람이 먼저 `--diff`를 보는 습관**이 승인 역할을 합니다. IAM 정책이나 네트워크가 바뀌는 변경이면 `--diff` 출력을 읽고 나서 `--deploy`를 돌립니다. 혼자 손으로 배포할 때는 이걸로 충분했지만, 습관은 자동화되지 않습니다. 자동화할 때는 이 자리를 **명시적인 승인 단계**로 바꿔야 합니다 (아래 점검 목록).

**`--outputs-file`**은 배포가 끝난 뒤 스택 출력(Outputs)을 JSON 파일로 씁니다. 키는 스택 이름입니다. 스크립트는 여기서 API의 CloudFront 주소(`ApiUrl`)를 꺼내 출력하고, 저는 이 값을 웹 빌드의 `VITE_API_URL`로 씁니다.

## 지우기 전에 경로를 검사한다

배포 스크립트는 공백 없는 `/tmp` 경로에 소스를 복사(staging)해서 그곳에서 CDK를 돌립니다. 소스 폴더와 CDK 앱 폴더는 형제로 둡니다. 왜 이렇게 했는지는 2편의 [경로 공백과 `ENAMETOOLONG`]({% post_url 2026-10-29-solo-dev-aws-deploy-pitfalls %}) 항목에 정리했습니다.

문제는 staging을 새로 만들기 전에 옛 폴더를 **`rm -rf`로 지운다**는 점입니다. 그리고 두 경로는 환경변수로 덮어쓸 수 있게 해 두었습니다. 검사가 없으면 실수로 `MY_API_SRC=$HOME`처럼 넣었을 때 스크립트가 홈 폴더를 지웁니다. 그래서 지우기 전에 검사합니다. 원래 스크립트는 네 가지를 봅니다.

1. 두 경로에 공백이 없다.
2. 둘 다 `/tmp/my-api-*` 패턴에 맞는다.
3. 두 경로가 같지 않다.
4. 한쪽이 다른 쪽 안에 들어 있지 않다 (중첩은 `ENAMETOOLONG`의 원인이었습니다).

그런데 2번에는 빈틈이 있습니다. bash의 `[[ ... == 패턴 ]]`에서 `*`는 `/`까지 포함한 아무 문자열에나 맞습니다. 그래서 `/tmp/my-api-x/../../etc` 같은 값도 `/tmp/my-api-*` 패턴을 통과합니다. 아래 예시는 한 단계 더 좁혀서 **`/tmp` 바로 아래의 이름 하나**만 허용합니다.

```sh
SRC="${MY_API_SRC:-/tmp/my-api-src}"
INFRA="${MY_API_INFRA:-/tmp/my-api-infra}"

die() { echo "$1" >&2; exit 2; }

# /tmp 바로 아래, 영문·숫자·_·- 로 된 이름 하나만 허용
# → 공백, '..', 하위 폴더가 모두 걸러지고, 둘 다 /tmp 바로 아래이니 중첩도 생길 수 없다
for p in "$SRC" "$INFRA"; do
  [[ $p =~ ^/tmp/my-api-[A-Za-z0-9_-]+$ ]] || die "허용하지 않는 staging 경로: $p"
done
[[ $SRC != "$INFRA" ]] || die "두 staging 경로가 같습니다"

rm -rf "$SRC" "$INFRA"
```

검사에 걸리면 사용법 오류와 같은 종료 코드 2로 멈춥니다. 지우는 명령이 있는 스크립트라면, 지울 대상을 "검사를 통과한 것"이 아니라 "허용한 모양에 맞는 것"으로 좁히는 편이 덜 놀랍니다.

staging에 복사할 때는 `node_modules`, `dist`, `cdk.out`, `.env*`를 빼고, 이미지 빌드 컨텍스트에는 `.dockerignore`를 새로 씁니다. 복사 단계에서 한 번, Docker 빌드 단계에서 한 번 거르는 두 겹입니다. 로컬의 `.env` 파일은 `/tmp` 복사본에도 들어가지 않고, 혹시 뭔가 섞여 들어가도 이미지에는 실리지 않게 하려는 것입니다.

## 백엔드와 API 사이의 순서: `amplify_outputs.json`

API 태스크의 환경변수(테이블 이름, 버킷 이름, 사용자 풀 ID 등)는 `amplify_outputs.json`에서 옵니다. 이 파일은 Amplify 백엔드를 배포할 때(`ampx sandbox --once`) 생기고, 공개 식별자만 들어 있어서 레포에 커밋해 둡니다 (커밋한 이유는 [2편]({% post_url 2026-10-29-solo-dev-aws-deploy-pitfalls %})의 8번). 배포 스크립트는 이 파일이 없으면 바로 멈춥니다.

```sh
[ -f "$REPO/amplify_outputs.json" ] || {
  echo "amplify_outputs.json이 없습니다. 백엔드를 먼저 배포하세요" >&2; exit 1; }
```

이 검사는 파일이 **있는지**만 봅니다. 파일이 **최신인지**는 모릅니다. 그래서 순서를 사람이 기억해야 합니다.

1. 백엔드를 바꾸고 `ampx sandbox --once`로 배포한다.
2. 새 `amplify_outputs.json`을 커밋하고 `main`에 push한다. 웹은 이 push로 자동 빌드되어 새 값을 씁니다.
3. **API도 다시 배포한다.** API는 push로 배포되지 않으므로, 이 단계를 잊으면 API는 옛 값을 계속 씁니다.

자동화가 이 순서를 대신 기억해 주기를 바라는 것도 자동화하려는 이유 중 하나입니다. 다만 API 배포만 자동화해도 백엔드 배포는 여전히 손으로 하므로, 순서 문제가 저절로 사라지지는 않습니다.

## CI/CD로 옮길 때 바꿀 것 (아직 구현하지 않은 계획)

여기부터는 **계획**입니다. 지금 CI는 push·PR에서 typecheck, lint, test만 돌립니다. 앞으로 하려는 것은 세 가지입니다.

- API 이미지 빌드(ARM64), ECR push, Fargate 배포를 GitHub Actions에서
- diff 미리보기를 보고 **승인한 뒤** 적용
- 장기 액세스 키 대신 **OIDC**로 AWS 역할을 맡기

아래는 손 배포 스크립트의 각 부분이 자동화에서 어떻게 바뀌어야 하는지 정리한 점검 목록입니다. GitHub·AWS 기능에 관한 내용은 공식 문서로 확인한 범위만 적었습니다.

### 1. 자격 증명: 로컬 프로필 → OIDC 역할

지금은 제 Mac의 AWS 프로필로 배포합니다. CI에 장기 액세스 키를 시크릿으로 넣는 대신, GitHub Actions의 OIDC 토큰을 AWS 역할의 임시 자격 증명으로 바꾸는 방식을 쓰려고 합니다. GitHub 문서 기준으로 필요한 것은 이렇습니다 ([GitHub 문서: Configuring OpenID Connect in Amazon Web Services](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)).

- IAM에 OIDC 공급자 `https://token.actions.githubusercontent.com`을 추가하고, 대상(audience)은 `sts.amazonaws.com`
- 역할의 신뢰 정책에서 `sub` 조건으로 **어떤 레포·브랜치·환경의 워크플로만** 이 역할을 맡을 수 있는지 좁히기
- 워크플로에 `permissions: id-token: write`를 주고, `aws-actions/configure-aws-credentials`로 역할을 맡기

```json
"Condition": {
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": "repo:my-org/my-app:environment:production"
  }
}
```

(문서의 형태를 줄인 예시이고, 아직 적용 전입니다.) `sub`를 레포 전체가 아니라 배포 환경(environment)이나 `main` 브랜치로 좁혀 두면, 아무 브랜치의 워크플로나 배포 역할을 맡는 일을 막을 수 있습니다.

### 2. bootstrap은 CI 밖으로

손 배포에서는 매번 bootstrap을 돌려도 괜찮았습니다. 하지만 CDK 문서가 안내하는 bootstrap 최소 권한에는 `cloudformation:*`, `iam:*`, `ecr:*`, `s3:*`, `ssm:*`가 들어 있습니다 ([CDK 문서: Bootstrap your environment](https://docs.aws.amazon.com/cdk/v2/guide/bootstrapping-env.html)). CI가 매번 bootstrap을 하면 CI 역할에도 이 넓은 권한이 필요합니다. bootstrap은 사람이 관리자 권한으로 한 번(그리고 템플릿이 갱신될 때) 하고, CI는 배포만 하게 나누는 쪽으로 생각하고 있습니다.

### 3. `--require-approval never` 자리를 승인 단계로

지금 승인 역할을 하는 것은 "사람이 먼저 `--diff`를 본다"는 습관입니다. 자동화에서는 이걸 단계로 만들어야 합니다. 후보는 두 가지입니다.

- **GitHub environment의 required reviewers.** 배포 job이 특정 environment를 쓰게 하면, 지정한 사람이 승인해야 job이 시작됩니다. 다만 GitHub Free·Pro·Team 플랜에서는 required reviewers를 **공개 레포에서만** 쓸 수 있습니다 ([GitHub 문서: Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)). 비공개 레포라면 플랜부터 확인해야 합니다.
- **CDK 변경 세트를 나눠서 실행.** `cdk deploy --method prepare-change-set`으로 변경 세트만 만들고, 검토한 뒤 `--method execute-change-set`으로 그 변경 세트를 실행합니다. CDK 문서도 이 옵션을 변경 세트 승인 절차가 있을 때 쓰라고 안내합니다 ([CDK 문서: cdk deploy](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-deploy.html)). 지금처럼 `diff`와 `deploy`를 따로 돌리면 그 사이에 코드가 바뀌어도 모르지만, 같은 변경 세트를 실행하면 **본 것과 적용하는 것이 같아집니다.**

### 4. `|| true` 빼기

`--diff`의 `|| true`와 bootstrap의 실패 무시는 사람이 출력을 읽는다는 전제에서만 괜찮습니다. CI에서는 미리보기가 실패하면 실패로 끝나야 합니다. 그렇지 않으면 "미리보기 통과 → 승인 → 적용"의 첫 칸이 아무것도 보장하지 않습니다.

### 5. ARM64 이미지를 어디서 빌드할지

Fargate 태스크와 이미지는 ARM64입니다 (아키텍처를 맞추지 않으면 생기는 `exec format error`는 [2편]({% post_url 2026-10-29-solo-dev-aws-deploy-pitfalls %})의 4번). CI에서 ARM64 이미지를 만드는 길은 두 가지입니다.

- **arm64 러너.** GitHub 호스티드 러너에 `ubuntu-24.04-arm` 같은 arm64 리눅스 러너가 있습니다. 공개 레포와 비공개 레포 모두 쓸 수 있지만 사양과 과금이 다릅니다. 공개 레포는 4 CPU·16GB에 무료, 비공개 레포는 2 CPU·8GB이고 계정의 포함 사용량을 쓴 뒤 분 단위로 과금됩니다 ([GitHub 문서: GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
- **x86 러너 + QEMU.** Docker 문서는 `docker/setup-qemu-action`으로 QEMU를 설정해 다른 플랫폼 이미지를 빌드하는 방법을 안내합니다 ([Docker 문서: Multi-platform image with GitHub Actions](https://docs.docker.com/build/ci/github-actions/multi-platform/)). 이미지 자산에 플랫폼을 ARM64로 명시해 두었으므로, x86에서 빌드해도 ARM64 이미지가 나옵니다.

어느 쪽을 쓸지는 아직 정하지 않았습니다. 빌드 시간과 비용을 실제로 재 보고 정할 생각입니다.

### 6. staging과 컨텍스트 파일

- **공백 경로 staging**: GitHub 호스티드 리눅스 러너의 작업 경로에는 아마 공백이 없을 것입니다. 2편에서 Amplify Hosting 빌드 서버(리눅스)에 이 문제가 없었던 것과 같은 이유입니다. 하지만 확인 전이라 staging을 바로 빼지는 않을 생각입니다.
- **형제 폴더 구조**는 공백과 별개입니다. Docker 빌드 컨텍스트 안에 `cdk.out`이 들어가면 생기는 문제이므로, CI에서도 CDK 앱 폴더 위치는 따로 챙겨야 합니다.
- **`cdk.context.json` 커밋 검토**: 지금 스크립트는 staging에 `cdk.json`과 CDK 앱만 복사하므로, `--deploy`는 매번 AZ를 새로 조회합니다. CDK 문서는 `cdk.json`과 `cdk.context.json`을 소스 관리에 커밋하라고 안내합니다. 그러지 않으면 CI 파이프라인 같은 다른 환경의 배포 결과가 달라질 수 있다는 이유입니다 ([CDK 문서: Context values](https://docs.aws.amazon.com/cdk/v2/guide/context.html)). 자동화할 때는 실제 계정에서 조회한 컨텍스트를 커밋하는 쪽을 검토하려고 합니다.

### 7. PR에서는 `--synth`부터

`--synth`는 자격 증명이 필요 없으니, OIDC나 승인 단계를 만들기 전에도 PR 검사에 붙일 수 있는 후보입니다. 스택 코드가 합성되는지는 배포 전에 PR에서 먼저 알 수 있습니다.

### 8. 순서 의존은 남는다

API 배포를 자동화해도 백엔드는 손으로 배포합니다. `amplify_outputs.json`이 바뀐 커밋이면 API 배포도 돌게 하는 식으로, 순서를 워크플로 조건에 담을 방법을 함께 정해야 합니다.

## 정리

- 자동으로 배포되는 것은 웹뿐이고, 백엔드와 API는 손으로, CI는 검사만 합니다. **자동화는 아직 구현 전입니다.**
- 손 배포 스크립트는 **`--synth`(AWS에 닿지 않음) · `--diff`(스택을 바꾸지 않음) · `--deploy`(바꿈)** 세 모드로 나눴습니다. 모르는 인자는 종료 코드 2로 멈춥니다.
- `--synth`는 계정 ID를 환경변수로 받고 AZ를 고정한 컨텍스트와 `--lookups=false`로 오프라인 합성합니다. 고정값은 매번 새로 만드는 staging 안에만 둡니다.
- `--deploy`는 확인 프롬프트를 끄므로(`--require-approval never`), 지금은 사람이 먼저 `--diff`를 보는 습관이 승인 역할을 합니다. 자동화할 때는 이 자리를 승인 단계로 바꿔야 합니다.
- `rm -rf` 전에는 staging 경로를 검사합니다. 패턴 검사만으로는 `..`을 막지 못하므로, 허용할 모양을 좁게 정하는 편이 안전합니다.
- `amplify_outputs.json`은 있는지만 확인할 수 있고 최신인지는 모릅니다. 백엔드를 바꾸면 API도 다시 배포해야 합니다.

손으로 배포하는 동안 스크립트에 모드와 안전장치를 넣어 두면, 자동화할 때 "어디를 승인 단계로 바꾸고 어디서 실패를 드러낼지"가 이미 드러나 있습니다. 이 시리즈는 여기까지입니다. 읽어 주셔서 감사합니다.
