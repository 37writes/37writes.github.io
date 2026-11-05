---
title: "CDK 배포 역할에서 AdministratorAccess 빼기: 전용 bootstrap, 실행 정책, 권한 경계 두 개"
date: 2026-11-05 10:30:00 +0900
categories: [AWS, 배포]
tags: [aws, cdk, iam, permissions-boundary, least-privilege, cloudformation]
description: "cdk bootstrap 기본값은 CloudFormation 실행 역할에 AdministratorAccess를 붙입니다. 공유 계정에서 한 프로젝트만 좁은 권한으로 배포하려고 전용 준비 스택, 실행 정책, 권한 경계 두 개를 만들고 독립 검증에서 찾은 권한 상승 구멍을 막은 과정을 정리합니다."
---

> **시리즈: 관리자 권한 없이 CDK 배포하기**
> 1. **전용 bootstrap, 실행 정책, 권한 경계 두 개** ← 지금 글
> 2. [최소 권한 CDK 첫 배포에서 막힌 곳: 태그 액션 함정과 CloudTrail로 권한 좁히기]({% post_url 2026-11-05-cdk-least-privilege-first-deploy %})

## CDK가 만든 역할에 관리자 권한이 붙어 있었다

사내 프로젝트 하나를 CDK로 AWS에 올리기 전에 계정부터 살펴봤습니다. 이 계정에는 예전에 만들어 둔 CDK 준비 스택(`CDKToolkit`, qualifier `hnb659fds`)이 이미 있었습니다. 여러 프로젝트가 같이 쓰는 공유 자원입니다. 그런데 이 스택의 CloudFormation 실행 역할(`cdk-hnb659fds-cfn-exec-role-…`)에 `AdministratorAccess`가 붙어 있었습니다.

`cdk deploy`를 하면 CDK CLI가 템플릿을 CloudFormation에 넘기고, 실제로 자원을 만드는 것은 CloudFormation이 맡는 이 **실행 역할**입니다. 실행 역할에 `AdministratorAccess`가 붙으면, 계정의 상위 정책(SCP 등)과 서비스 제약이 허용하는 범위에서 매우 넓은 변경을 할 수 있습니다. 템플릿에 실수나 악의가 섞이면 다른 프로젝트 자원을 건드리거나 관리자 권한을 가진 IAM 주체를 만드는 것도 실행 역할 수준에서는 막히지 않습니다. 이건 누가 잘못 설정한 것이 아니라 **기본값**입니다. [CDK bootstrap 문서](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-bootstrap.html)에도 "기본적으로 스택은 `AdministratorAccess` 정책의 전체 관리자 권한으로 배포된다"고 적혀 있습니다.

공유 스택은 제 소유가 아니라서 고치지도 지우지도 않기로 했습니다. 대신 이 프로젝트만 쓰는 준비 스택을 따로 만들고, 그 실행 역할을 이 프로젝트 자원만 다룰 수 있게 좁혔습니다. 이 글은 그 과정입니다.

- 전용 준비 스택을 **기본 템플릿 그대로, 매개변수만 바꿔** 만드는 법
- 실행 정책 하나와 **권한 경계 두 개**(실행 역할용, 앱 역할용)를 나눈 이유
- 정책과 경계를 **함께 넣은 시뮬레이션**으로 확인하는 법
- 다른 모델에게 맡긴 독립 검증이 찾아낸 **권한 상승 경로**와 막은 방법

결과부터 말하면 아직 배포 전 단계입니다. 합성 결과 검사와 정책 시뮬레이션까지 통과했고, 실제 첫 배포에서 막힌 곳은 2편에서 다룹니다. (계정 ID, 이름 접두사, 버킷 이름은 모두 예시 값으로 바꿨습니다. 정책과 코드도 개념을 보여 주는 최소 예시로 새로 썼습니다.)

## 전체 구조: 누가 무엇을 묶나

<figure class="diagram">
{% include figures/cdk-least-privilege-bootstrap/permission-layers.svg %}
<figcaption>보호 정책 셋은 관리자가 먼저 만듭니다. 역할에 붙인 정책(identity-based policy)으로 얻는 권한 기준으로, 실행 역할은 실행 정책과 실행 역할 경계로, 앱이 만드는 역할은 IAM 액션이 없는 앱 역할 경계로 묶입니다.</figcaption>
</figure>

등장하는 것은 다섯 가지입니다.

| 이름(예시) | 무엇 | 누가 만드나 | 어디에 붙나 |
|---|---|---|---|
| `MyProjCdkToolkit` | 프로젝트 전용 준비 스택 (qualifier `myproj1`) | 관리자가 `cdk bootstrap`으로 | 계정·리전 하나 |
| `MyProjCdkExec` | 실행 정책: 프로젝트 자원만 만들고 고치고 지운다 | 관리자가 원문 JSON으로 | 실행 역할 (`cdk-myproj1-cfn-exec-role-…`) |
| `MyProjCdkBoundary` | 실행 역할 경계: 실행 정책과 대부분 같은 허용(PassRole만 다름) + 모든 거부 | 관리자가 원문 JSON으로 | 실행 역할의 권한 경계 |
| `MyProjAppBoundary` | 앱 역할 경계: 앱이 실제로 쓰는 호출만, IAM 액션 없음 | 관리자가 원문 JSON으로 | 앱이 만드는 모든 역할의 권한 경계 |
| 앱 역할 정책 | Lambda 등이 쓰는 역할별 정책 | CDK 앱 | 앱 역할 |

세 정책(실행 정책과 경계 둘)은 CDK가 아니라 **관리자가 원문 JSON으로 만듭니다.** 준비 스택이 이 정책들을 참조하므로 먼저 있어야 하고, 무엇보다 실행 역할이 자기를 묶는 정책을 고칠 수 있으면 묶는 의미가 없기 때문입니다. 이 셋을 이 글에서는 **보호 정책**이라고 부르겠습니다. 여기에 더해, 관리자가 개발자 IAM 사용자에게 붙이는 **사용자 정책 둘**(예시 이름 `MyProjUserInvoke`, `MyProjUserDataRead`)도 관리자가 원문으로 만들고, 보호 정책과 같은 변경·부착 거부 목록에 넣습니다. 이유는 아래 (a)에서 설명합니다.

배포 명령은 지금처럼 사람이 관리자 자격으로 실행합니다. 달라지는 것은 사람의 권한이 아니라 **CloudFormation이 템플릿을 실행할 때의 권한**입니다. 앱 코드에 실수가 있든, 템플릿이 바뀌었든, CloudFormation이 실행 역할로 부르는 API는 실행 역할에 붙인 정책과 그 경계가 허용하는 범위 안에 머뭅니다. 자원 정책이 역할 세션에 직접 주는 권한 같은 다른 경로는 따로 평가해야 하고, 명시적 Deny는 어느 경로든 이깁니다.

## 1. 전용 준비 스택: 기본 템플릿 + 매개변수

### qualifier만 바꿔서는 권한이 분리되지 않는다

CDK는 qualifier로 준비 스택을 여러 개 둘 수 있게 합니다. qualifier가 다르면 버킷·역할 이름이 겹치지 않습니다. 하지만 [CDK bootstrap 사용자 지정 문서](https://docs.aws.amazon.com/cdk/v2/guide/bootstrapping-customizing.html)는 이렇게 경고합니다. qualifier 변경은 원래 CDK 자체의 자동 테스트끼리 이름을 나누려는 것이고, **CloudFormation 실행 역할의 IAM 권한을 아주 정밀하게 좁히지 않는 한, 한 계정에 준비 스택을 둘 두어도 권한 분리 이점은 없다**고요.

그래서 이 글의 핵심은 새 qualifier가 아니라 그 스택의 실행 역할에 **무엇을 붙이느냐**입니다.

### 명령

```sh
npx cdk bootstrap aws://123456789012/ap-northeast-2 \
  --qualifier myproj1 \
  --toolkit-stack-name MyProjCdkToolkit \
  --toolkit-bucket-name myproj-cdk-assets-123456789012-apne2 \
  --bootstrap-kms-key-id AWS_MANAGED_KEY \
  --cloudformation-execution-policies arn:aws:iam::123456789012:policy/MyProjCdkExec \
  --custom-permissions-boundary MyProjCdkBoundary \
  --termination-protection false
```

| 옵션 | 하는 일 |
|---|---|
| `--qualifier` | 준비 스택 자원 이름에 붙는 값. 역할 이름이 `cdk-myproj1-*`가 됩니다 |
| `--toolkit-stack-name` | 공유 `CDKToolkit`과 겹치지 않는 스택 이름 |
| `--toolkit-bucket-name` | 자산(Lambda zip 등) 버킷 이름. 바꾸면 앱 쪽 합성기에도 같은 이름을 적어야 합니다 (아래) |
| `--bootstrap-kms-key-id AWS_MANAGED_KEY` | 자산 버킷을 AWS 관리 키로 암호화. 요금이 붙는 고객 관리 키를 만들지 않습니다 |
| `--cloudformation-execution-policies` | 실행 역할에 붙일 관리형 정책 ARN. **이걸 주지 않으면 `AdministratorAccess`가 붙습니다** |
| `--custom-permissions-boundary` | 실행 역할에 붙일 권한 경계의 **이름**(ARN이 아님) |

KMS는 공식 문서상 기본도 AWS 관리 키입니다. 그래도 명령에 적어 두었습니다. 고객 관리 키(`--bootstrap-customer-key`)는 키마다 월 요금이 붙으니, 기본값 해석에 기대지 않고 명령만 보고 알 수 있게 하려는 것입니다.

`--custom-permissions-boundary`는 [CDK 권한 경계 문서](https://docs.aws.amazon.com/cdk/v2/guide/customize-permissions-boundaries.html)에 따르면 준비 템플릿의 CloudFormation 실행 역할에 붙습니다. 나머지 준비 역할(deploy, lookup, 파일·이미지 게시)에는 붙지 않습니다. 이 점은 뒤의 "준비 역할 넷" 절에서 다시 나옵니다.

이 명령을 실제로 돌리기 전에 고정한 CDK 버전(2.1147.0)에서 `npx cdk bootstrap --show-template`로 템플릿을 로컬에 출력해 보고(템플릿 버전 32), 어떤 자원이 생기는지 확인했습니다. `--show-template`은 AWS에 아무것도 만들지 않고 템플릿만 표준 출력으로 내보냅니다.

### 템플릿은 고치지 않는다

처음에는 준비 템플릿을 내려받아 역할 이름을 프로젝트 이름 규칙에 맞게 고치는 안도 생각했습니다. 버렸습니다. 템플릿을 고치면 CDK를 올릴 때마다 새 기본 템플릿과 내 수정본을 다시 맞춰야 합니다. 대신 역할 이름이 `cdk-myproj1-*`로 정해지는 것은 받아들였습니다. 이름으로 알아보기 어려운 대신, 권한은 이름이 분명한 관리형 정책(`MyProjCdkExec`)에 모여 있으니 "어느 정책이 무엇을 하는지"는 정책 쪽에서 알 수 있습니다.

### 앱 쪽: 합성기에 qualifier와 버킷 이름을 맞춘다

qualifier나 버킷 이름을 바꿨으면 앱의 합성기(`DefaultStackSynthesizer`)에도 같은 값을 알려야 합니다. 특히 버킷 이름을 놓치기 쉽습니다. 합성기의 기본 버킷 이름은 `cdk-${Qualifier}-assets-${AWS::AccountId}-${AWS::Region}`이라서([합성 사용자 지정 문서](https://docs.aws.amazon.com/cdk/v2/guide/customize-synth.html)), qualifier만 맞추면 합성기는 `cdk-myproj1-assets-…`라는, 존재하지 않는 버킷에 자산을 올리려 합니다. 첫 자산 게시가 거기서 실패합니다.

```ts
// bin/app.ts (예시)
import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { AppStack } from '../lib/app-stack';

const ACCOUNT = '123456789012';
const app = new cdk.App();

const synthesizer = () => new cdk.DefaultStackSynthesizer({
  qualifier: 'myproj1',
  fileAssetsBucketName: `myproj-cdk-assets-${ACCOUNT}-apne2`, // --toolkit-bucket-name과 같게
});

const stack = new AppStack(app, 'MyProjApp', {
  env: { account: ACCOUNT, region: 'ap-northeast-2' },
  synthesizer: synthesizer(),
});

// 이 스택이 만드는 모든 IAM 역할에 앱 역할 경계를 붙인다
iam.PermissionsBoundary.of(stack).apply(
  iam.ManagedPolicy.fromManagedPolicyArn(
    stack, 'AppBoundary', `arn:aws:iam::${ACCOUNT}:policy/MyProjAppBoundary`),
);
```

스택이 여럿이면 합성기와 `PermissionsBoundary.of(...)`를 스택마다 똑같이 적용합니다.

설정을 맞췄다고 믿지 않고 합성 결과(`cdk.out`)로 확인했습니다. 실제로 쓴 검사 스크립트는 더 길지만, 핵심은 세 가지입니다.

```sh
npx cdk synth --quiet

# 1. 공유 준비 스택(기본 qualifier)을 참조하는 곳이 0건이어야 한다
grep -rl hnb659fds cdk.out && echo "공유 준비 스택 참조 있음" && exit 1

# 2. 자산 목적지 버킷이 전용 버킷 하나뿐이어야 한다
jq -r '.files[].destinations[].bucketName' cdk.out/*.assets.json | sort -u

# 3. Lambda 코드 위치도 같은 버킷이어야 한다
jq -r '.Resources[] | select(.Type=="AWS::Lambda::Function")
       | .Properties.Code.S3Bucket' cdk.out/*.template.json | sort -u
```

2와 3이 `myproj-cdk-assets-123456789012-apne2` 한 줄만 내면 통과입니다.

## 2. 정책 셋: 실행 정책, 실행 역할 경계, 앱 역할 경계

### 권한 경계를 하나로 쓰면 안 되는 이유

권한 경계는 역할에 붙인 정책(identity-based policy)이 줄 수 있는 **최대 권한**입니다. 그 경로로 얻는 권한은 "역할에 붙은 정책 ∩ 경계"이고, 둘 중 어디든 명시적 Deny가 있으면 Deny가 이깁니다. 같은 계정의 자원 정책이 역할 세션에 직접 주는 권한은 경계만으로 막히지 않을 수 있어서 따로 봐야 합니다([IAM 권한 경계 문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)).

처음에는 경계 하나를 실행 역할에도, 앱이 만드는 역할에도 쓰면 간단하겠다고 생각했습니다. 그런데 두 역할이 필요한 권한은 성격이 완전히 다릅니다.

- **실행 역할**은 배포를 하므로 IAM 역할·정책을 만들고 고칠 수 있어야 합니다.
- **앱 역할**(Lambda 실행 역할 등)은 모델 호출, Lambda·S3·SQS·시크릿 읽기, 로그 쓰기처럼 앱이 실제로 하는 호출만 하면 됩니다. IAM은 필요 없습니다.

경계 하나에 둘을 담으면 배포용 IAM 관리 권한이 앱 역할 경계에도 들어가 앱 경계가 약해집니다. 반대로 배포 자원만 넣으면 앱 실행에 필요한 호출이 빠집니다. 그래서 둘로 나눴고, **앱 역할 경계에는 IAM 액션을 하나도 넣지 않았습니다.** 오히려 `iam:*`를 명시적으로 거부합니다.

### 실행 정책과 실행 역할 경계 (요약 예시)

실행 정책과 실행 역할 경계는 허용 범위가 대부분 같고, PassRole만 실행 정책은 고정 ARN 목록, 경계는 접두사로 다르게 둡니다. 거부 문장은 경계에 모두 두고, 실행 정책에는 일부만 둡니다(이유는 아래 "정책 크기 한도"). 아래는 둘에 들어가는 IAM 문장을 하나로 합쳐 줄인 예시입니다. S3·Lambda·SQS 같은 서비스 자원은 `myproj-*`/`MyProj*` 접두사 ARN으로 같은 모양의 허용 문장을 서비스마다 둡니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:PutRolePermissionsBoundary"],
      "Resource": "arn:aws:iam::123456789012:role/MyProj*",
      "Condition": {"StringEquals": {
        "iam:PermissionsBoundary": "arn:aws:iam::123456789012:policy/MyProjAppBoundary"}}
    },
    {
      "Effect": "Allow",
      "Action": ["iam:GetRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole",
                 "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
                 "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"],
      "Resource": ["arn:aws:iam::123456789012:role/MyProj*",
                   "arn:aws:iam::123456789012:policy/MyProj*"]
    },
    {
      "Effect": "Allow",
      "Action": ["iam:AttachRolePolicy", "iam:DetachRolePolicy"],
      "Resource": "arn:aws:iam::123456789012:role/MyProj*",
      "Condition": {"ArnLike": {"iam:PolicyARN": "arn:aws:iam::123456789012:policy/MyProj*"}}
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": ["arn:aws:iam::123456789012:role/MyProjApiFnRole",
                   "arn:aws:iam::123456789012:role/MyProjWorkerFnRole"],
      "Condition": {"StringEquals": {"iam:PassedToService": "lambda.amazonaws.com"}}
    },
    {
      "Sid": "DenyProtectedEdit",
      "Effect": "Deny",
      "Action": ["iam:CreatePolicy*", "iam:DeletePolicy*", "iam:SetDefaultPolicyVersion", "iam:*Tag*"],
      "Resource": ["arn:aws:iam::123456789012:policy/MyProjCdk*",
                   "arn:aws:iam::123456789012:policy/MyProjAppBoundary",
                   "arn:aws:iam::123456789012:policy/MyProjUserInvoke",
                   "arn:aws:iam::123456789012:policy/MyProjUserDataRead"]
    },
    {
      "Sid": "DenyProtectedAttach",
      "Effect": "Deny",
      "Action": ["iam:Attach*Policy", "iam:Detach*Policy"],
      "Resource": "*",
      "Condition": {"ArnLike": {"iam:PolicyARN": [
        "arn:aws:iam::123456789012:policy/MyProjCdk*",
        "arn:aws:iam::123456789012:policy/MyProjAppBoundary",
        "arn:aws:iam::123456789012:policy/MyProjUserInvoke",
        "arn:aws:iam::123456789012:policy/MyProjUserDataRead"]}}
    },
    {
      "Sid": "DenyUserGroupAttach",
      "Effect": "Deny",
      "Action": ["iam:AttachUserPolicy", "iam:DetachUserPolicy",
                 "iam:AttachGroupPolicy", "iam:DetachGroupPolicy"],
      "Resource": "*"
    },
    {
      "Sid": "DenyInlineAndBoundaryRemoval",
      "Effect": "Deny",
      "Action": ["iam:Put*Policy", "iam:Delete*PermissionsBoundary", "iam:PutUserPermissionsBoundary"],
      "Resource": "*"
    },
    {
      "Sid": "DenyOtherBoundary",
      "Effect": "Deny",
      "Action": ["iam:CreateRole", "iam:PutRolePermissionsBoundary"],
      "Resource": "*",
      "Condition": {"StringNotEquals": {
        "iam:PermissionsBoundary": "arn:aws:iam::123456789012:policy/MyProjAppBoundary"}}
    },
    {
      "Sid": "DenyBootstrapRoles",
      "Effect": "Deny",
      "Action": "iam:*",
      "Resource": "arn:aws:iam::123456789012:role/cdk-myproj1-*"
    },
    {
      "Sid": "DenySecretForceDelete",
      "Effect": "Deny",
      "Action": "secretsmanager:DeleteSecret",
      "Resource": "*",
      "Condition": {"Bool": {"secretsmanager:ForceDeleteWithoutRecovery": "true"}}
    }
  ]
}
```

허용 쪽에서 눈여겨볼 곳은 둘입니다.

- **역할 만들기**는 새 역할의 경계가 앱 역할 경계일 때만 허용합니다(`iam:PermissionsBoundary` 조건). 경계 없는 역할이나 다른 경계를 단 역할은 `DenyOtherBoundary`가 막습니다.
- **보호 대상**에는 보호 정책 셋과 **사용자 정책 둘**(`MyProjUserInvoke`, `MyProjUserDataRead`)이 모두 들어갑니다. 허용 문장의 `policy/MyProj*`에 이 다섯도 걸리지만, 명시적 Deny가 이깁니다. 사용자 정책 이름을 보호 접두사 밖으로 옮기더라도 그 ARN을 이 두 거부 목록에 넣어야 합니다.
- **PassRole**은 접두사(`MyProj*`)가 아니라 앱이 만드는 역할의 **고정 ARN 목록**입니다. 이유는 아래 검증 절의 (b)에서 설명합니다. 실제로는 실행 정책에 앱 역할 11개의 ARN을 나열하고, 경계에는 접두사를 두어 교집합이 그 11개가 되게 했습니다.

### 명시적 Deny가 왜 이렇게 많은가

거부 문장은 대부분 "실행 역할이 **자기를 묶는 것**을 풀 수 없게" 하려는 것입니다.

| 거부 | 막는 경로 |
|---|---|
| 보호 정책의 만들기·새 버전·기본 버전 바꾸기·삭제·태그 | 실행 역할이 자기 경계에 `Allow *` 버전을 만들면, 그다음 자기 실행 정책도 넓힐 수 있습니다 |
| 사용자 정책 둘의 만들기·새 버전·기본 버전 바꾸기·삭제 | 이미 사용자에게 붙은 정책은 새로 붙이지(Attach) 않아도, 새 버전을 기본으로 만드는 것만으로 사용자 권한이 바뀝니다 (아래 (a)) |
| 보호 정책·사용자 정책 붙이기·떼기 | 경계 정책을 다른 곳에 붙이거나 떼서 구조를 흔드는 것 |
| 모든 사용자·그룹 정책 붙이기·떼기, 인라인 정책 쓰기 | 경계 없는 IAM 사용자에게 권한을 실어 우회하는 것 (아래 (a)) |
| 권한 경계 지우기, 앱 경계가 아닌 경계로 역할 만들기 | 경계 없는 역할을 만들어 그 역할로 일하는 것 |
| 준비 스택 역할(`cdk-myproj1-*`)의 모든 IAM 액션 | 실행 역할이 자기 자신이나 deploy 역할의 신뢰·정책을 바꾸는 것 |
| 시크릿 즉시 삭제 | 아래 (e) |

"역할을 만들 때는 앱 경계를 붙여라"라는 조건만으로는 부족합니다. 그 조건은 **경계 정책의 내용**이 바뀌는 것을 막지 못합니다. 경계 정책 자체를 고칠 수 없게 따로 거부해야 합니다. CDK 권한 경계 문서도 경계를 만든 뒤 "IAM 주체가 경계를 벗어나지 못하게 막아야 한다"며 IAM 사용자 가이드의 위임 예제를 가리킵니다.

### 앱 역할 경계 (요약 예시)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "lambda:InvokeFunction",
     "Resource": "arn:aws:lambda:ap-northeast-2:123456789012:function:MyProj*"},
    {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
     "Resource": ["arn:aws:s3:::myproj-data", "arn:aws:s3:::myproj-data/*"]},
    {"Effect": "Allow", "Action": ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"],
     "Resource": "arn:aws:sqs:ap-northeast-2:123456789012:myproj-*"},
    {"Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
     "Resource": "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:myproj/*"},
    {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
     "Resource": "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/lambda/MyProj*"},
    {"Sid": "DenyAllIam", "Effect": "Deny", "Action": "iam:*", "Resource": "*"}
  ]
}
```

앱 역할이 역할별 정책(identity-based policy)으로 얻는 권한은 이 경계와 그 정책의 교집합입니다. 경계는 "역할별 정책을 아무리 넓혀도 여기까지"라는 상한이고, 역할마다 어떤 데이터에 닿는지는 역할별 정책이 정합니다. 같은 계정의 자원 정책이 역할 ARN에 주는 권한은 이 경계의 제한을 받지만, 역할 세션 ARN에 직접 주는 권한은 경계의 implicit deny만으로는 막히지 않을 수 있습니다(명시적 Deny는 그래도 이깁니다). 그래서 버킷·큐 정책을 둘 때는 따로 봅니다.

### 앱 코드: 인라인 정책 대신 이름 고정 역할 + 관리형 정책

위 실행 정책으로는 CDK의 흔한 작성법 몇 가지가 배포되지 않습니다. 정책 쪽을 넓히는 대신 앱 코드를 맞췄습니다.

- `bucket.grantRead(fn)` 같은 `grant*()`, `addToPolicy()`, `addToRolePolicy()`는 역할의 **인라인 정책**(`AWS::IAM::Policy`)을 만듭니다. 실행 정책·경계의 `iam:Put*Policy` 거부와 부딪힙니다.
- `lambda.Function`에 역할을 넘기지 않으면 CDK가 기본 역할을 만들고 AWS 관리형 정책 `AWSLambdaBasicExecutionRole`을 붙입니다. `AttachRolePolicy`는 `policy/MyProj*`인 고객 관리형 정책일 때만 허용하므로 막힙니다.
- 자동 생성 역할 이름은 PassRole의 고정 ARN 목록과 맞는다는 보장이 없습니다.

그래서 역할 이름을 고정하고, `MyProj*` 고객 관리형 정책을 명시적으로 만들어 붙이고, Lambda에는 그 역할을 직접 넘깁니다. 로그 쓰기 권한도 그 정책에 넣습니다. 이 예시는 로그 그룹 `/aws/lambda/MyProjApiFn`을 CDK 자원으로 먼저 만든다는 전제라서, 앱 역할에는 `logs:CreateLogGroup` 없이 스트림 만들기와 로그 쓰기만 줍니다. 로그 그룹을 만들지 않으면 첫 호출에서 Lambda가 로그 그룹을 만들려다 거부되어 로그가 남지 않을 수 있습니다.

```ts
// lib/app-stack.ts (예시: 역할 1개 + 관리형 정책 1개)
const role = new iam.Role(this, 'ApiFnRole', {
  roleName: 'MyProjApiFnRole',            // PassRole 고정 ARN과 같은 이름
  assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
});

new iam.ManagedPolicy(this, 'ApiFnPolicy', {
  managedPolicyName: 'MyProjApiFnPolicy', // MyProj* 고객 관리형 정책
  roles: [role],
  statements: [
    new iam.PolicyStatement({
      actions: ['logs:CreateLogStream', 'logs:PutLogEvents'],
      resources: [`arn:aws:logs:${this.region}:${this.account}:log-group:/aws/lambda/MyProjApiFn:*`],
    }),
    new iam.PolicyStatement({
      actions: ['s3:GetObject'],
      resources: ['arn:aws:s3:::myproj-data/*'],
    }),
  ],
});

// 로그 그룹은 CDK가 만든다 (역할에 CreateLogGroup을 주지 않으려고)
const logGroup = new logs.LogGroup(this, 'ApiFnLogs', {
  logGroupName: '/aws/lambda/MyProjApiFn',
  retention: logs.RetentionDays.ONE_MONTH,
});

new lambda.Function(this, 'ApiFn', {
  functionName: 'MyProjApiFn',
  role,                                   // 기본 역할(AWS 관리형 정책 부착)을 만들지 않게 직접 넘긴다
  logGroup,                               // 위 로그 그룹으로 보낸다. grant 호출은 없다
  runtime: lambda.Runtime.PYTHON_3_13,
  handler: 'handler.handler',
  code: lambda.Code.fromAsset('lambda/api'),
});
// bucket.grantRead(fn), logGroup.grantWrite(role), fn.addToRolePolicy(...)는 쓰지 않는다 (인라인 정책이 생긴다)
```

실제로는 역할과 정책을 IAM 전용 스택에 모으고, Lambda 스택에서는 `iam.Role.fromRoleName(this, 'ApiFnRole', 'MyProjApiFnRole', { mutable: false })`로 가져왔습니다. `mutable: false`면 Lambda 쪽 스택이 그 역할에 정책을 덧붙이지 않습니다. 다만 `grant*()`를 오류로 잡아 주는 것이 아니라 조용히 무시합니다(`addGrantsToResources` 기본값 `false`). 그래서 필요한 권한은 처음부터 IAM 스택의 관리형 정책에 넣어야 합니다. 또 이름으로 가져오기만 하면 두 스택 사이의 의존 관계가 자동으로 생기지 않으므로, IAM 스택을 먼저 배포하거나 `lambdaStack.addDependency(iamStack)`로 순서를 적어 둡니다. `PermissionsBoundary.of()`는 경계를 붙여 줄 뿐이고, 이 작성법을 대신해 주지 않습니다.

이것도 합성 결과로 확인합니다. 앞의 `cdk.out` 검사에 아래를 더했습니다.

```sh
# 4. 인라인 정책 0건 (별도 인라인 정책 자원 네 유형과 Role/User/Group의 Policies 속성)
jq '[.Resources[] | select(
  .Type == "AWS::IAM::Policy" or
  .Type == "AWS::IAM::RolePolicy" or
  .Type == "AWS::IAM::UserPolicy" or
  .Type == "AWS::IAM::GroupPolicy" or
  ((.Type == "AWS::IAM::Role" or .Type == "AWS::IAM::User" or .Type == "AWS::IAM::Group")
   and ((.Properties.Policies // []) | length) > 0)
)] | length' cdk.out/*.template.json
# 5. 역할 이름과 관리형 정책 이름이 모두 MyProj*, 역할에 직접 붙은 관리형 정책(ManagedPolicyArns) 없음
#    이 예시의 부착 방식에서는 Role.ManagedPolicyArns가 비어 있고, 연결은 ManagedPolicy.Roles에 있다
jq -r '.Resources[] | select(.Type == "AWS::IAM::Role") | [.Properties.RoleName, ((.Properties.ManagedPolicyArns // []) | length)] | @tsv' cdk.out/*.template.json
jq -r '.Resources[] | select(.Type == "AWS::IAM::ManagedPolicy") | .Properties.ManagedPolicyName' cdk.out/*.template.json
```

glob은 변수에 담지 않고 명령마다 직접 씁니다. macOS 기본 셸인 zsh에서는 `T='cdk.out/*.template.json'`처럼 변수에 담은 별표가 파일 이름으로 펼쳐지지 않습니다. 4는 템플릿마다 `0`, 5는 이름이 모두 `MyProj*`이고 둘째 칸이 `0`이면 통과입니다. 관리형 정책 이름이 보호 정책·사용자 정책 이름과 겹치지 않는지도 같이 봅니다.

## 3. 확인: 정책과 경계를 함께 넣은 시뮬레이션

정책을 하나씩 넣어 Allow가 나오는지 보는 것으로는 유효 권한을 증명할 수 없습니다. 실행 정책에서 Allow여도 경계에서 막히면 실제로는 Deny입니다. 그래서 **실행 정책과 경계를 함께 넣은** `simulate-custom-policy`로 봤습니다. 실제 계정의 정책을 바꾸지 않는 읽기 전용 API입니다.

```sh
aws iam simulate-custom-policy \
  --policy-input-list "$(cat MyProjCdkExec.json)" \
  --permissions-boundary-policy-input-list "$(cat MyProjCdkBoundary.json)" \
  --action-names iam:CreateRole \
  --resource-arns arn:aws:iam::123456789012:role/MyProjTestRole \
  --context-entries "ContextKeyName=iam:PermissionsBoundary,ContextKeyType=string,ContextKeyValues=arn:aws:iam::123456789012:policy/MyProjAppBoundary" \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]'
```

같은 명령으로 액션×자원 표를 만들어 기대값과 비교했습니다.

- **Allow여야 하는 것**: 프로젝트 자원 만들기·고치기·지우기, 앱 경계를 단 역할 만들기
- **Deny여야 하는 것**: 다른 프로젝트 ARN, 보호 정책 변경, 경계 없는 역할 만들기, 사용자·그룹 정책 붙이기, 준비 스택 역할 고치기
- **앱 역할**: 앱 경계 + 역할별 정책을 함께 넣어 필요한 호출은 Allow, IAM 액션은 모두 Deny

두 가지를 주의했습니다.

- **여러 ARN을 한 요청에 넣으면** 결과의 종합 `EvalDecision` 하나로 판단하지 않습니다. 자원별 결과인 `ResourceSpecificResults[].EvalResourceDecision`을 봐야 어떤 ARN이 막혔는지 알 수 있습니다. 헷갈리면 요청 하나에 액션 하나, 자원 하나만 넣는 편이 낫습니다.
- 시뮬레이션은 넣어 준 정책·경계·문맥 키의 IAM 판정일 뿐입니다. SCP, 서비스 자체의 검증, 실제 배포 성공은 증명하지 않습니다.

이전 글 [에이전트 하네스 첫 실전]({% post_url 2026-10-28-dev-harness-first-bugfix-iam %})에서는 이미 붙어 있는 정책을 `simulate-principal-policy`로 봤습니다. 이번에는 아직 만들지 않은 정책을 원문으로 시험해야 해서 `simulate-custom-policy`를 썼습니다.

시뮬레이션과 함께 보호 정책 셋과 사용자 정책 둘, 다섯 원문에 `aws accessanalyzer validate-policy`도 돌렸습니다(문법·보안 경고). 앱 스택의 변경 미리보기는 `cdk diff --method=template`로 했습니다. 기본 방식은 정확한 비교를 위해 CloudFormation 변경 세트를 만들려고 해서 AWS에 쓰기가 일어납니다. 자세한 이야기는 [CDK 손 배포 스크립트를 CI/CD 전에 다듬기]({% post_url 2026-11-03-solo-dev-aws-deploy-cicd %})에 정리했습니다.

## 4. 독립 검증이 찾은 구멍들

여기까지 만들고 스스로 검사하면 다 통과했습니다. 그다음 다른 모델(Codex)에게 독립 검증을 맡겼습니다. 제 시뮬레이션 표를 다시 돌리는 게 아니라 "이 실행 역할로 권한을 넓힐 수 있는 경로가 있는가" 같은 공격 질문을 기준으로 표를 새로 짜게 했습니다. 처음 결과는 **불합격**이었습니다. 이 절이 이 글에서 가장 쓸모 있는 부분일 것 같습니다.

### (a) 사용자 정책을 거쳐 관리자 수준까지 올라가는 경로

<figure class="diagram">
{% include figures/cdk-least-privilege-bootstrap/escalation-path.svg %}
<figcaption>실행 역할 경계는 실행 역할 자신의 권한만 묶습니다. 실행 역할이 쓴 정책 내용은 묶지 않으므로, 경계 없는 사용자에게 이미 붙은 정책의 새 기본 버전을 만들 수 있으면 우회됩니다.</figcaption>
</figure>

처음 설계에서는 CDK 앱이 개발자 IAM 사용자에게 붙일 정책 둘(앱 호출용, 데이터 읽기용)도 만들었습니다. 정책 이름이 프로젝트 접두사라서 실행 정책의 `iam:CreatePolicy*` 허용에 걸렸고, 그 사용자에게 붙이는 것도 허용돼 있었습니다.

검증자가 짚은 경로는 이렇습니다. 실행 역할이 그 사용자 정책의 **새 버전**을 `Effect: Allow`, `Action: "*"`, `Resource: "*"` 내용으로 만들면서 `SetAsDefault=true`로 지정합니다([CreatePolicyVersion](https://docs.aws.amazon.com/IAM/latest/APIReference/API_CreatePolicyVersion.html)). 정책은 이미 사용자에게 붙어 있으니 새로 붙일(Attach) 필요가 없고, 새 기본 버전의 권한이 그대로 그 사용자에게 적용됩니다. 그 사용자에게는 권한 경계가 없으므로, 시뮬레이션상 그 사용자는 IAM 정책 수준(SCP 등 상위 정책은 넣지 않은 판정)의 관리자 권한까지 올라갔습니다. 거꾸로 실행 역할 경계 정책의 새 버전을 만드는 것도 Allow였습니다.

**실행 역할 경계는 실행 역할 자신이 할 수 있는 호출을 제한할 뿐, 그 역할이 만든 정책 문서의 내용까지 제한하지는 않습니다.** 공격 전제는 배포될 템플릿이나 실행 역할을 누군가 통제하는 상황이지만, 바로 그 상황을 막으려고 실행 역할을 좁힌 것이니 그냥 넘길 수 없는 구멍입니다. 게다가 제 합성 검사 스크립트는 사용자 정책 내용을 `Allow *`로 바꾼 사본도 전부 통과시켰습니다.

고친 방법:

- 사용자 정책 둘은 **관리자가 원문으로 만들고 직접 붙입니다.** CDK는 만들지도 붙이지도 않습니다.
- 실행 정책과 경계가 **모든 사용자·그룹의 정책 붙이기·떼기**와 그 사용자 정책들의 만들기·새 버전·기본 버전 바꾸기·삭제를 거부합니다. 부착 거부만으로는 부족합니다. 이미 붙어 있는 정책은 새 버전만으로 바뀌기 때문입니다.
- 합성 검사가 사용자 정책 원문의 내용(허용 액션·자원 범위)까지 봅니다.

중간에 "관리자가 정책을 만들고 CDK가 붙이기만 한다"는 안도 시도했지만 CloudFormation으로는 되지 않았습니다. CloudFormation에는 **이미 있는 IAM 사용자에게 관리형 정책을 붙이는 단독 자원이 없고**, CDK에서 `User.fromUserName()`으로 가져온 사용자에 `addManagedPolicy()`를 부르면 `ValidationError`(`CannotAddManagedPolicyImported`)가 납니다. 결국 더 좁은 지금 안으로 갔습니다.

### (b) PassRole은 권한 경계를 검사하지 않는다

처음 PassRole은 `role/MyProj*` 접두사였습니다. 앱이 만드는 역할은 모두 앱 경계가 붙으니 괜찮다고 생각했습니다. 그런데 PassRole은 넘기는 역할에 **경계가 있는지 검사하지 않습니다.** 나중에 누군가 같은 접두사로 경계 없는 역할을 만들면, 실행 역할은 그 역할도 Lambda에 넘길 수 있습니다. 시뮬레이션에서 가상의 `MyProjUnboundedRole`을 Lambda에 넘기는 것이 Allow로 나왔습니다(지금 계정에 그런 역할이 있는 것은 아닙니다).

→ 앱이 만드는 역할 **11개의 고정 ARN 목록**과 `iam:PassedToService`(Lambda 등 실제로 넘기는 서비스)로 좁혔습니다.

### (c) 조건이 붙은 Deny를 통과시킨 검사

(a)를 고친 뒤 재검증에서 이번에는 **검사 스크립트**가 걸렸습니다. 합성 검사는 "사용자 정책 변경을 거부하는 Deny 문장이 있는가"를 이렇게 봤습니다.

```ts
// 고치기 전(단순화): Deny 문장 어딘가에 대상 ARN 문자열이 들어 있기만 하면 통과
st.Effect === 'Deny' && JSON.stringify(st).includes(protectedArn)
```

검증자는 Deny 문장에 **절대 성립하지 않는 조건**(요청한 주체의 ARN이 정책 ARN과 같을 때만 거부)을 붙인 사본을 만들었습니다. 문자열은 그대로 들어 있으니 검사는 통과했지만, 실제 시뮬레이션에서는 Deny가 적용되지 않아 사용자 정책 만들기가 Allow였습니다.

→ 무조건이어야 하는 거부는 **`Condition`과 `NotAction`·`NotResource`가 없는 Deny**이고, 그 `Action`·`Resource` 와일드카드가 검사하려는 요청과 맞을 때만 인정하게 바꿨습니다. 와일드카드는 IAM처럼 `*`와 `?`를 처리하고, 액션은 대소문자를 구별하지 않습니다.

```ts
// 고친 뒤: 조건 없는 Deny가 요청(액션·자원)과 와일드카드로 맞아야 통과
const glob = (p: string, flags = '') => new RegExp('^' + p
  .replace(/[.+^$(){}|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$', flags);
const unconditionalDeny = (stmts: any[], action: string, res: string) => stmts.some(st =>
  st.Effect === 'Deny' && !('Condition' in st) && !('NotAction' in st) && !('NotResource' in st) &&
  [st.Action].flat().some((a: string) => glob(a, 'i').test(action)) &&  // 액션: 대소문자 무시
  [st.Resource].flat().some((r: string) => glob(r).test(res)));          // 자원: 그대로
```

이 검사는 우리 정책에 쓰는 액션·ARN 패턴을 대상으로 한 것이고, IAM 정책 평가 전체를 구현한 것은 아닙니다. 실제 판정은 여전히 시뮬레이션이 맡습니다.

그리고 검증자가 만든 조건부 Deny 사본으로 다시 돌려 **이번에는 실패하는지**(29개 검사 중 25개만 통과) 확인했습니다. 검사가 정상 원문을 통과시키는 것만 보면 부족합니다. **위험한 사본을 실패시키는지**까지 봐야 그 검사를 믿을 수 있습니다.

### (d) 넓은 와일드카드가 끄려던 기능을 남겼다

쓰지 않을 기능이 하나 있었습니다(AgentCore의 Memory). 그래서 그 기능의 `CreateMemory`만 허용 목록에서 뺐습니다. 그런데 다른 자원 관리를 위해 둔 `Get*`·`Update*`·`Delete*` 와일드카드가 프로젝트 이름의 Memory 자원 ARN에도 맞아서, 만들기만 빠지고 조회·수정·삭제는 남아 있었습니다.

→ "빼기"를 허용 목록에서 지우는 것으로 끝내지 않고, 실행 정책과 경계 둘 다에 **무조건 Deny 두 개**를 넣었습니다. 하나는 Memory 자원 ARN(`…:memory/*`)의 모든 액션, 다른 하나는 자원 `*`에 대한 `*Memor*` 액션(자원 유형이 없는 목록 액션까지 잡으려고)입니다. 그다음 부정 시뮬레이션 행을 추가해 Memory 관련 액션이 모두 explicitDeny인지 확인했습니다. 다만 CloudFormation 리소스 스키마를 보면 Harness의 생성·갱신·삭제 핸들러 권한 목록에 Memory 액션이 들어 있습니다. Memory를 끈 설정에서 핸들러가 실제로 그 API를 부르는지는 배포 전에 확인할 수 없었고, 이 무조건 Deny가 생성이나 **삭제**를 막을 수도 있습니다. 2편에서 확인할 항목입니다.

### (e) CloudFormation의 시크릿 삭제는 기본이 즉시 삭제

Secrets Manager 시크릿은 보통 지워도 복구 기간(7~30일)이 있습니다. 그래서 "스택을 지워도 30일 안에 복구할 수 있다"고 문서에 적어 두었는데, 틀렸습니다. [CloudFormation DeletionPolicy 문서](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-deletionpolicy.html)에 따르면 CloudFormation이 `AWS::SecretsManager::Secret`을 지울 때 기본은 **복구 기간 없는 즉시 삭제**(`ForceDeleteWithoutRecovery`)입니다.

→ 시크릿은 `RemovalPolicy.RETAIN`으로 스택 삭제에서 남기고, 지울 때는 사람이 [DeleteSecret](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_DeleteSecret.html)에 `--recovery-window-in-days 30`을 줘서 예약 삭제합니다. 실행 역할 경계는 `secretsmanager:ForceDeleteWithoutRecovery`가 `true`인 삭제를 거부합니다.

### (f) "값 없이 시크릿을 만든다"는 IAM으로 보장할 수 없다

실행 역할에는 `GetSecretValue`·`PutSecretValue`·`UpdateSecret`을 주지 않았습니다. 이미 있는 시크릿의 값은 읽지도 바꾸지도 못합니다. 하지만 `CreateSecret`은 요청에 값(`SecretString`)을 실을 수 있고, **이를 막는 IAM 조건 키가 없습니다.** 그래서 "시크릿은 빈 채로 만들고 값은 사람이 넣는다"는 IAM이 아니라 합성 검사(템플릿에 `SecretString`·`GenerateSecretString`이 없는지)와 배포 전 템플릿 확인이 보장합니다. 문서에도 그렇게 구분해 적었습니다. 그리고 리소스 스키마상 시크릿의 읽기·갱신 핸들러에는 `GetSecretValue`·`UpdateSecret`이 들어 있어서, 값 API를 뺀 실행 역할로 CloudFormation이 시크릿을 갱신할 수 있는지도 실제 배포에서 확인해야 합니다(2편).

### (g) 준비 역할 넷은 이 계정을 신뢰한다

준비 스택에는 실행 역할 말고도 역할이 넷 더 있습니다(lookup, deploy, 파일 게시, 이미지 게시). 실행 역할은 CloudFormation 서비스만 신뢰하지만, 이 넷은 **이 계정을 신뢰**합니다. 계정 안에서 그 역할의 `sts:AssumeRole` 권한이 있는 주체는 누구나 맡을 수 있다는 뜻입니다. 기본 템플릿 그대로면 lookup 역할에는 `ReadOnlyAccess`가 붙고, deploy 역할은 CloudFormation 작업 권한이 넓습니다. 권한 경계도 실행 역할에만 붙습니다.

템플릿을 고치지 않기로 했으니, 배포는 관리자만 하도록 운영하고 **이번 개발자 사용자에게는 이 넷의 AssumeRole을 주지 않았습니다.** 배포 전에는 그 사용자에게 붙을 정책 원문으로 시뮬레이션해 넷 모두 implicitDeny인지 확인했습니다. 이건 그 사용자의 정책 조합에서 거부를 확인한 것이지, 계정 안의 다른 비관리자 주체까지 막도록 신뢰 정책을 바꾼 것은 아닙니다. 그래서 새 정책·그룹·역할을 누군가에게 줄 때마다 같은 확인을 다시 해야 합니다. 배포 뒤에는 실제 사용자 ARN으로 `simulate-principal-policy`를 다시 봅니다.

## 자원 유형이 없는 Create 액션

모든 액션을 이름 접두사 ARN으로 묶을 수 있는 것은 아닙니다. [서비스 권한 참조](https://docs.aws.amazon.com/service-authorization/latest/reference/list_bedrock-agentcore.html)에서 액션의 "Resource types" 칸이 비어 있으면 `Resource: "*"`로만 줄 수 있습니다. 이 프로젝트에서는 AgentCore의 `CreateGateway`·`CreateHarness`·`CreateAgentRuntime`과 일부 `List*`가 그랬습니다. 만들기 액션이라서 그런 것은 아닙니다. 같은 만들기라도 `iam:CreateRole`이나 `s3:CreateBucket`은 ARN으로 묶이고, `CreateAgentRuntimeEndpoint`도 runtime ARN으로 묶을 수 있습니다. ARN 제한이 되는지는 액션별 권한 참조로 판단합니다.

이럴 때는 조건 키로 묶습니다.

```json
{
  "Effect": "Allow",
  "Action": ["bedrock-agentcore:CreateGateway", "bedrock-agentcore:CreateHarness"],
  "Resource": "*",
  "Condition": {"StringEquals": {
    "aws:RequestedRegion": "ap-northeast-2",
    "aws:RequestTag/project": "myproj"
  }}
}
```

- `aws:RequestedRegion`으로 리전을, `aws:RequestTag/<키>`로 "이 태그를 달고 만드는 요청"만 허용합니다. 템플릿의 자원에도 같은 태그를 답니다.
- 요청 태그 조건을 지원하는지는 액션마다 다릅니다. 서비스 권한 참조의 "Condition keys" 칸에서 `aws:RequestTag/${TagKey}`가 있는지 확인합니다. 조건 키가 없는 `List*`는 리전 조건만 둘 수 있습니다.
- 만든 뒤의 고치기·지우기는 ARN이 있으니 이름 접두사 ARN으로 묶습니다.
- 이 요청 태그 조건은 Gateway·Harness 만들기에만 걸었습니다. `CreateAgentRuntime`은 권한 참조상 요청 태그를 지원하지만, Harness가 대신 부를 때 태그를 실어 보내는지 확인하지 못해 당시에는 리전 조건만 두었습니다. 첫 배포에서 확인하고 좁힐 항목입니다(2편).

남는 틈도 적어 둡니다. 태그만 맞으면 이름 접두사 밖의 Gateway·Harness도 만들 수 있습니다. 다만 고치기·지우기는 이름 접두사 ARN으로 묶었으므로, 그렇게 만든 자원을 실행 역할이 다시 고치거나 지울 수는 없습니다.

S3에도 비슷한 함정이 있습니다. S3 버킷 ARN에는 리전이 없어서 ARN으로는 버킷의 리전을 묶을 수 없습니다. 처음 정책은 이 점을 놓쳐, 시뮬레이션에서 다른 리전에 프로젝트 이름 버킷을 만드는 요청이 Allow로 나왔습니다. 버킷 만들기는 `s3:LocationConstraint`가 서울 리전일 때만 허용하도록 따로 묶었습니다([S3 서비스 권한 참조](https://docs.aws.amazon.com/service-authorization/latest/reference/list_s3.html)).

## 정책 크기 한도

관리형 정책 하나는 **공백을 빼고 6,144자**까지입니다. 허용 문장에 거부 문장까지 다 넣다 보니 실행 정책이 이 한도에 걸렸습니다.

- 거부는 **경계에 모두** 두고, 실행 정책에는 일부만 같이 두었습니다. 경계의 명시적 Deny는 실행 정책 내용과 상관없이 이깁니다. 그래서 두 원문은 허용 범위가 대부분 같아도(PassRole 목록만 다름) 내용과 해시가 다릅니다.
- 허용 문장의 `Sid`를 뺐습니다(거부 문장의 `Sid`는 남겼습니다).

## 그래도 남는 위험

이 구조가 막지 못하는 것도 분명히 적어 둡니다.

- **실행 역할은 앱 역할 정책의 새 버전을 만들 수 있습니다.** CDK가 정책을 고치려면 필요한 권한입니다. 앱 역할은 IAM이 없는 앱 경계로 묶이지만, 각 역할이 어느 데이터까지 닿는지는 역할별 정책에 달렸습니다. 배포마다 템플릿 비교로 봅니다.
- **배포 역할 자체는 신뢰해야 합니다.** Lambda 코드나 버킷 정책을 바꿀 수 있는 역할이므로, 직접 `GetObject` 권한이 없어도 코드나 자원 정책을 통한 간접 접근은 가능합니다.
- 시뮬레이션은 실제 배포가 아닙니다. CloudFormation 핸들러가 내부에서 부르는 API, 서비스 쪽 검증은 첫 배포에서야 드러납니다. 배포 전에 남긴 확인 항목은 이렇습니다(모두 2편).
  - Memory 무조건 Deny가 Harness 핸들러의 생성·삭제와 부딪히는지. 생성 성공으로 삭제 성공을 대신하지 않고 둘 다 시험합니다. 거부로 삭제가 막히면 앱 역할·실행 역할·준비 스택·보호 정책부터 지우지 않고, 남은 자원과 실패한 호출을 먼저 확인합니다.
  - 시크릿 핸들러가 `GetSecretValue`·`UpdateSecret`을 부르는지
  - `CreateAgentRuntime`에 태그가 실리는지(지금은 리전 조건만)

## 결과 (배포 전)

| 확인 | 결과 |
|---|---|
| 합성 + 검사 스크립트 | 29/29 통과 |
| 정책+경계 함께 넣은 시뮬레이션 | 기대와 다른 결과 0 / 170행 |
| `validate-policy` (정책 원문 다섯) | 발견 0 |
| 조건부 Deny 사본 | 검사 실패(25/29) — 의도대로 |
| 다른 모델 재검증 | 1차 불합격 → 2차 불합격 → 3차 합격 |

이 수치는 글에 실은 요약 JSON이 아니라 **실제 원문 정책**(서비스별 허용 문장 전체 포함) 기준입니다.

배포 뒤에는 실행 역할에 실행 정책 하나만 붙고 인라인 정책이 없으며 경계가 붙었는지, 앱 역할 11개에 모두 앱 경계가 붙었는지, 공유 `CDKToolkit`의 상태와 마지막 갱신 시각이 그대로인지 확인할 계획입니다. 이 결과는 2편에서 다룹니다.

## 점검 목록

비슷한 구성을 만든다면 이 순서로 확인해 보세요.

1. `cdk bootstrap`에 `--cloudformation-execution-policies`를 줬는가 (안 주면 `AdministratorAccess`)
2. qualifier와 **버킷 이름**을 합성기에도 같게 적었는가, `cdk.out`에 기본 qualifier가 0건인가
3. 실행 역할 경계와 앱 역할 경계를 나눴는가, 앱 경계에 IAM 액션이 없는가
4. 보호 정책(실행 정책·경계 둘)과 **사용자에게 붙는 정책**의 변경·새 기본 버전·삭제·부착을 명시적으로 거부했는가
5. 실행 역할이 **경계 없는 주체(사용자·그룹)**에 정책을 붙이거나, 그 주체에 붙은 정책을 바꿀 수 있는 경로가 없는가
6. PassRole이 접두사가 아니라 고정 ARN 목록인가, 앱 역할 이름이 그 목록과 같게 고정돼 있는가
7. 앱 코드가 `grant*()`·`addToRolePolicy()`·기본 Lambda 역할 대신 `MyProj*` 관리형 정책을 쓰는가, 합성 결과에 인라인 정책 0건인가
8. 끄려는 기능을 허용 목록에서 지우는 데서 그치지 않고 무조건 Deny로 막았는가
9. 시크릿의 CloudFormation 삭제 동작을 확인했는가
10. 정책과 경계를 **함께** 넣어 시뮬레이션했는가, 여러 ARN이면 자원별 결과를 봤는가
11. 검사 스크립트가 **위험한 사본을 실패시키는지** 확인했는가

## 정리

- `cdk bootstrap` 기본값은 실행 역할에 `AdministratorAccess`를 붙입니다. 새 qualifier만으로는 권한이 나뉘지 않고, 실행 역할에 붙이는 정책이 핵심입니다.
- 기본 템플릿은 그대로 두고 매개변수(실행 정책, 경계, 버킷 이름)만 바꿨습니다. 버킷 이름을 바꾸면 합성기에도 맞춰야 합니다.
- 경계는 실행 역할용과 앱 역할용 둘로 나눴습니다. 앱 경계에는 IAM이 없습니다.
- 가장 큰 구멍은 "실행 역할 경계는 그 역할이 쓴 정책 내용을 묶지 않는다"는 점이었습니다. 경계 없는 사용자에게 닿는 정책은 CDK 밖에서 관리자가 관리합니다.
- 내 검사가 통과했다는 것만으로는 부족했습니다. 다른 모델이 공격 질문으로 표를 새로 짜고, 일부러 망가뜨린 사본을 검사가 잡는지 봐야 했습니다.

이 좁은 권한으로 실제 첫 배포를 하면서 막힌 곳(태그 액션 함정)과, CloudTrail 기록으로 권한을 더 좁힌 과정은 다음 편 [최소 권한 CDK 첫 배포에서 막힌 곳: 태그 액션 함정과 CloudTrail로 권한 좁히기]({% post_url 2026-11-05-cdk-least-privilege-first-deploy %})에서 다룹니다.
