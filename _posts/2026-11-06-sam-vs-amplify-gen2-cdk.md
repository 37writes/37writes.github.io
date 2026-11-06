---
title: "SAM이냐 Amplify Gen 2 + CDK냐: 둘 다 CloudFormation인데 무엇이 다른가"
date: 2026-11-06 10:45:00 +0900
categories: [AWS, 배포]
tags: [aws-concepts, aws, sam, amplify, amplify-gen2, cdk, cloudformation, infrastructure-as-code]
description: "SAM 템플릿으로 만든 백엔드를 Amplify Gen 2 + CDK로 옮기기로 하면서 정리했습니다. 셋 다 CloudFormation 스택을 만든다는 공통점, SAM·CDK·Gen 2가 놓인 층, '+CDK'가 뜻하는 두 가지(createStack, cfnResources), 고를 때 기준을 다룹니다."
---

회사 작업에서 현장 장비를 모니터링하는 웹 대시보드를 만들고 있었습니다. 백엔드는 AWS SAM 템플릿(YAML) 하나였습니다. 이 템플릿 하나에 장비 등록(Thing)·IoT 정책, 로그인을 맡는 Cognito 사용자 풀과 자격 증명 풀, 가입 처리와 정책 붙이기를 맡은 Lambda 함수 몇 개, 웹이 부르는 HTTP API가 다 들어 있었습니다. 웹 화면은 Amplify Hosting에 따로 올릴 생각이었습니다.

그러다 AI 에이전트(Claude Code)에게 이렇게 물었습니다.

> SAM하고 Amplify Gen 2 + CDK 차이가 뭐야? 이 구조가 더 좋다면 이걸로 바꾸자. Cognito는 새로 만들어서 기존 사용자를 다시 등록해도 돼.

다른 프로젝트에서는 이미 Amplify Gen 2 + CDK 구조를 쓰고 있었습니다. 에이전트는 비교 표를 보여 주고 "이 프로젝트에도 Gen 2가 더 맞다"고 답했습니다. 저는 옮기기로 했습니다. 그런데 결정은 했어도 이 질문에는 답하지 못한 상태였습니다.

> SAM, CDK, Amplify Gen 2는 각각 어느 층에 있는 도구이고, "Gen 2 **+ CDK**"의 "+CDK"는 정확히 무엇을 말하는가?

이 글은 그 답을 공식 문서 기준으로 정리하고, 그때 한 결정으로 돌아가 주의할 점을 적습니다.

## 1. 공통 바닥: 셋 다 결국 CloudFormation 스택이다

AWS CloudFormation은 "템플릿에 적은 리소스를 **스택(stack)**이라는 단위로 만들고, 고치고, 지우는 서비스"입니다. SAM도, CDK도, Amplify Gen 2도 최종 결과물은 CloudFormation 스택입니다. 그래서 세 도구의 차이는 "무엇을 만드나"가 아니라 아래 두 가지입니다.

- **무엇으로 쓰나**: YAML 템플릿인가, TypeScript 같은 프로그래밍 언어인가
- **얼마나 미리 묶어 주나**: 리소스를 하나씩 적는가, "로그인" 같은 기능 단위로 한 번에 받는가

<figure class="diagram">
{% include figures/sam-vs-amplify-gen2-cdk/layers.svg %}
<figcaption>SAM과 CDK는 CloudFormation 바로 위에, Amplify Gen 2는 CDK 위에 있습니다. "+CDK"는 Gen 2 안에서 CDK로 내려가 새 리소스를 추가하거나(createStack), 생성된 리소스의 설정을 고치는(cfnResources) 두 갈래입니다.</figcaption>
</figure>

## 2. AWS SAM: CloudFormation 템플릿에 줄임 문법을 더한 것

[AWS SAM](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html)(Serverless Application Model)은 두 부분으로 되어 있습니다.

- **SAM 템플릿**: [CloudFormation 템플릿의 확장](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam-overview.html)입니다. 맨 위에 `Transform: AWS::Serverless-2016-10-31`을 적으면 `AWS::Serverless::Function`, `AWS::Serverless::HttpApi` 같은 줄임 문법을 쓸 수 있습니다. 배포할 때 SAM이 이 줄임 문법을 일반 CloudFormation 리소스로 **펼칩니다(transform)**. 공식 문서의 예시에서는 23줄짜리 SAM 템플릿이 200줄이 넘는 CloudFormation 템플릿이 됩니다.
- **SAM CLI**: 템플릿을 다루는 명령줄 도구입니다. `sam build`(배포 준비), `sam deploy`(CloudFormation으로 배포), `sam local invoke`(로컬 컨테이너에서 함수 실행), `sam sync --watch`(고친 코드를 개발 스택에 바로 반영) 같은 명령이 있습니다. `sam sync`는 함수 코드처럼 서비스 API로 바꿀 수 있는 변경은 CloudFormation 배포를 거치지 않고 바로 반영하기도 해서, [공식 문서](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/using-sam-cli-sync.html)는 개발 환경에만 쓰고 운영은 `sam deploy`나 CI/CD 파이프라인으로 배포하라고 권합니다.

중요한 점은 **SAM 문법과 CloudFormation 문법을 한 템플릿에 섞어 쓸 수 있다**는 것입니다. 함수와 API는 SAM 줄임 문법으로, Cognito나 IoT처럼 SAM 전용 문법이 없는 리소스는 CloudFormation 리소스 그대로 적습니다.

아래는 구조를 보여 주는 템플릿 조각입니다. 함수 구현(`src/` 안의 코드)과 API에 로그인 인증을 연결하는 설정은 생략했습니다.

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Transform: AWS::Serverless-2016-10-31
Resources:
  UserPool:
    Type: AWS::Cognito::UserPool          # CloudFormation 리소스를 그대로 쓴다
    Properties:
      UsernameAttributes: [email]
      AutoVerifiedAttributes: [email]
      DeletionProtection: ACTIVE
  UserPoolClient:
    Type: AWS::Cognito::UserPoolClient
    Properties:
      UserPoolId: !Ref UserPool
      GenerateSecret: false
  HelloFunction:
    Type: AWS::Serverless::Function       # SAM이 함수·실행 역할·권한으로 펼친다
    Properties:
      Runtime: nodejs22.x
      Handler: index.handler
      CodeUri: src/
      Events:
        Hello:
          Type: HttpApi                   # HTTP API와 경로도 함께 만든다
          Properties:
            Path: /hello
            Method: GET
```

함수와 API는 짧지만, 로그인 쪽은 사용자 풀과 클라이언트를 CloudFormation 속성 이름 그대로 하나씩 적어야 합니다. 자격 증명 풀, 로그인한 사용자가 맡을 IAM 역할, 그 둘을 잇는 연결까지 더하면 템플릿은 금방 길어집니다.

세 가지를 한 문장씩 풀면 이렇습니다. **사용자 풀**은 가입·로그인과 사용자 관리를 맡습니다. **자격 증명 풀**은 로그인한 사용자(또는 게스트)에게 AWS 서비스에 직접 접근할 임시 자격 증명을 내줍니다. **IAM 역할**은 그 임시 자격 증명으로 무엇을 할 수 있는지 정합니다.

SAM에 대해 흔히 오해하는 점도 두 가지 짚어 둡니다.

- **환경을 여러 개 둘 수 있습니다.** SAM CLI 설정 파일 [`samconfig.toml`](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-config.html)에는 `[default]`, `[prod]`처럼 이름 붙은 환경을 여러 개 두고 `--config-env`로 고를 수 있습니다. 환경마다 `stack_name`을 다르게 주면 스택이 따로 생깁니다. 다만 "개발자마다", "Git 브랜치마다" 자동으로 만들어 주는 기능은 아니고, 직접 나눠 쓰는 방식입니다.
- **CDK와 같이 쓸 수도 있습니다.** 공식 문서는 SAM CLI의 로컬 테스트 기능으로 CDK 앱을 보완하는 쓰임도 안내합니다. SAM과 CDK가 서로 배타적인 선택지는 아닙니다.

## 3. AWS CDK: 코드로 쓰고, 템플릿으로 합성한다

[AWS CDK](https://docs.aws.amazon.com/cdk/v2/guide/home.html)(Cloud Development Kit)는 TypeScript, Python 같은 프로그래밍 언어로 인프라를 적습니다. `cdk synth`를 하면 그 코드가 CloudFormation 템플릿으로 **합성(synthesize)**되고, `cdk deploy`는 그 템플릿으로 스택을 배포합니다. SAM이 "템플릿을 펼치는" 쪽이라면 CDK는 "코드를 실행해서 템플릿을 만드는" 쪽입니다.

CDK 코드는 **구성 요소(construct)**를 조립해서 만듭니다. [공식 문서](https://docs.aws.amazon.com/cdk/v2/guide/constructs.html)는 구성 요소를 세 층으로 나눕니다.

| 층 | 다른 이름 | 무엇인가 | 예 |
|---|---|---|---|
| **L1** | CFN 리소스 | CloudFormation 리소스 하나와 **일대일**. 추상화 없음. 이름이 `Cfn`으로 시작 | `CfnUserPool`, `CfnThing` |
| **L2** | curated | 리소스 하나를 감싸되, 쓸 만한 기본값과 `grant` 같은 도우미 메서드를 준다 | `UserPool`, `Table` |
| **L3** | patterns | 여러 리소스를 묶어 한 가지 일을 하는 구성 | 로드 밸런서 + 컨테이너 서비스 묶음 |

위 층일수록 적게 써도 되고, 아래 층일수록 CloudFormation 속성을 하나하나 직접 고를 수 있습니다. 이 L1이 뒤에 나올 "+CDK"의 두 번째 뜻과 이어집니다.

일반적인 CDK 배포에서는 배포에 쓰는 S3 버킷과 IAM 역할을 계정·리전마다 미리 만들어 두는 **부트스트랩(bootstrap)**이 필요합니다. [`cdk deploy` 문서](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-deploy.html)에 따르면 에셋이 없고 합성된 템플릿이 51,200바이트보다 작은 스택은 예외로, 부트스트랩하지 않은 환경에도 배포됩니다. 기본 부트스트랩이 주는 권한을 좁히는 방법은 [CDK 배포 역할에서 AdministratorAccess 빼기]({% post_url 2026-11-05-cdk-least-privilege-bootstrap %})에 정리했습니다.

## 4. Amplify Gen 2: CDK 위에 얹은 풀스택 프레임워크

[Amplify Gen 2 문서](https://docs.amplify.aws/react/how-amplify-works/concepts/)는 Amplify가 **AWS CDK 위에 얹혀 있다**고 밝힙니다. 그래서 Gen 2 백엔드를 배포할 때도 CDK처럼 계정·리전이 [부트스트랩돼 있어야 합니다](https://docs.amplify.aws/react/build-a-backend/troubleshooting/cdktoolkit-stack/).

Gen 2가 CDK 위에 더해 주는 것은 크게 세 가지입니다.

1. **기능 단위로 미리 묶은 구성 요소**: `defineAuth`(로그인), `defineData`(데이터), `defineStorage`(파일), `defineFunction`(함수). 문서에 따르면 Data와 Auth는 CDK L3 구성 요소를 감싼 것입니다. 이메일 로그인은 이 정도면 됩니다.

   ```ts
   // amplify/auth/resource.ts
   import { defineAuth } from "@aws-amplify/backend";

   export const auth = defineAuth({
     loginWith: { email: true },
   });
   ```

   이 몇 줄 뒤에서 사용자 풀, 앱 클라이언트, 자격 증명 풀, 로그인한 사용자와 게스트용 IAM 역할이 함께 만들어집니다. SAM 템플릿에서 하나씩 적던 것들입니다.

2. **환경을 만드는 방식**: 개발자마다 자기 [클라우드 sandbox](https://docs.amplify.aws/react/deploy-and-host/sandbox-environments/setup/)(`npx ampx sandbox`)를 띄웁니다. 공유 환경(운영, 스테이징 등)은 Git 브랜치와 일대일로 대응하고, Amplify 콘솔에 브랜치를 연결하면 그 브랜치의 프런트엔드와 백엔드가 함께 배포됩니다([fullstack branch deployments](https://docs.amplify.aws/react/deploy-and-host/amplify-hosting/branch-deployments/)).

3. **웹으로 설정 전달**: 백엔드의 출력(사용자 풀 ID, 클라이언트 ID 등)이 [`amplify_outputs.json`](https://docs.amplify.aws/react/reference/amplify_outputs/)으로 생깁니다. 로컬에서는 sandbox가, Amplify의 CI/CD에서는 앱 ID와 브랜치를 기준으로 자동으로 만듭니다. 웹은 이 파일로 Amplify 라이브러리를 설정합니다.

`defineBackend`, `amplify_outputs.json`을 커밋하는 이유, sandbox를 운영에 쓰지 않는 이유는 [1인 개발자의 AWS 배포 구조]({% post_url 2026-10-29-solo-dev-aws-deploy-architecture %})의 "Amplify Gen 2는 어디까지 쓰나"에 적었습니다. 여기서는 SAM과 비교하는 데 필요한 부분만 다룹니다.

## 5. "+CDK"의 두 가지 뜻

Gen 2가 CDK 위에 있다는 사실에서 "+CDK"의 뜻이 나옵니다. `define*`가 주는 범위를 벗어날 때, 같은 백엔드 안에서 **CDK로 내려가는 길이 두 갈래** 있습니다.

**(a) Amplify에 기능이 없는 리소스는 CDK 스택을 더해서 만든다.**
Amplify에는 IoT Core용 `define*` 기능이 없습니다. IoT Core의 장비(Thing)·정책이나 영상 스트림 같은 리소스는 [`backend.createStack()`](https://docs.amplify.aws/react/build-a-backend/add-aws-services/custom-resources/)으로 백엔드 안에 CloudFormation 스택을 하나 더 만들고, 그 안에 일반 CDK 코드로 적습니다. 문서에 따르면 이렇게 정의한 리소스는 Amplify 백엔드와 **함께 배포됩니다.** 스택은 여러 개 만들 수 있고, 한 스택에 리소스를 여러 개 넣을 수 있습니다.

**(b) `define*`에 옵션이 없는 설정은 그 아래 L1 리소스를 직접 고친다.**
`defineAuth`는 자주 쓰는 설정만 옵션으로 줍니다. 그 밖의 설정은 [`backend.auth.resources.cfnResources`](https://docs.amplify.aws/react/build-a-backend/add-aws-services/overriding-resources/)로 꺼낸 L1 구성 요소(`cfnUserPool`, `cfnIdentityPool` 등)의 속성을 바꿔서 넣습니다. L1은 CloudFormation 속성과 일대일이므로, CloudFormation 문서에 있는 속성이면 대부분 이 길로 닿습니다.

두 갈래를 한 파일에 쓰면 이렇습니다. 새로 쓴 최소 예시입니다. 맨 위의 `defineBackend`는 `defineAuth` 등으로 정의한 기능을 하나의 백엔드로 묶습니다.

```ts
// amplify/backend.ts
import { defineBackend } from "@aws-amplify/backend";
import { CfnThing } from "aws-cdk-lib/aws-iot";
import { auth } from "./auth/resource";

const backend = defineBackend({ auth });

// (a) Amplify에 기능이 없는 리소스: 같은 백엔드 안에 CDK 스택을 하나 더 만든다
const deviceStack = backend.createStack("devices");
// thingName을 비워 두면 CloudFormation이 고유한 이름을 붙인다
// (sandbox·브랜치마다 이름이 겹치지 않는다)
const thing = new CfnThing(deviceStack, "SensorThing", {});
backend.addOutput({ custom: { thingName: thing.ref } });

// (b) defineAuth에 옵션이 없는 설정: 그 아래 L1(CloudFormation) 리소스를 직접 고친다
const { cfnUserPool, cfnIdentityPool } = backend.auth.resources.cfnResources;
cfnUserPool.deletionProtection = "ACTIVE";
cfnIdentityPool.allowUnauthenticatedIdentities = false;
```

마지막 줄은 그냥 넣은 예가 아닙니다. Amplify 문서에 따르면 Gen 2는 [게스트 접근(로그인하지 않은 사용자의 임시 자격 증명)을 **기본으로 켭니다**](https://docs.amplify.aws/react/build-a-backend/auth/concepts/guest-access/). 끄는 방법도 `defineAuth` 옵션이 아니라 이 `cfnIdentityPool` 수정입니다. 로그인한 사람만 쓰는 대시보드라면 먼저 확인할 줄입니다.

(b)에는 문서의 경고가 붙어 있습니다. override를 쓰면 **Amplify 라이브러리나 클라이언트 설정이 제대로 해석하지 못하는 백엔드**가 될 수 있으니, 바꾼 것은 반드시 스테이징 환경에서 시험하라는 것입니다. 이 글에서는 삭제 보호와 게스트 끄기를 예로 들었지만, 이 두 설정도 영향이 없는 것은 아닙니다. 게스트 자격 증명을 쓰는 기능이 있다면 게스트 끄기가 그 기능을 멈추고, 삭제 보호는 환경을 지우는 절차를 바꿉니다. 제 판단으로는 로그인 방식이나 속성 구조를 바꾸는 설정일수록 더 조심해야 하고, 어느 쪽이든 게스트에 기대는 기능과 삭제 절차까지 확인합니다.

정리하면 "Amplify Gen 2 + CDK"는 **Amplify와 CDK라는 두 도구를 나란히 쓴다**는 뜻이 아닙니다. **하나의 Gen 2 백엔드 안에서, 기능은 `define*`로 받고, 없는 것은 CDK로 더하고, 모자란 설정은 L1으로 고친다**는 뜻입니다.

## 6. 한 표로 비교

공식 문서로 확인한 것만 적었습니다.

| | SAM | CDK | Amplify Gen 2 |
|---|---|---|---|
| 작성 | YAML/JSON 템플릿 (선언형) | TypeScript, Python 등 (코드) | TypeScript (`amplify/` 폴더) |
| CloudFormation과의 관계 | 템플릿 확장, 배포 때 펼침 | 코드를 템플릿으로 합성 | CDK 위에 얹힘 |
| 추상화 | 서버리스 리소스 줄임 문법 | L1·L2·L3 구성 요소 | `define*` 기능 단위 |
| 로그인(Cognito) 정의 | CloudFormation 리소스로 하나씩 | L2 `UserPool` 등으로 조립 | `defineAuth` 몇 줄 |
| 웹으로 설정 전달 | 스택 출력(Outputs)을 직접 읽어 씀 | Outputs를 JSON으로 내보낼 수 있음(`--outputs-file`), 웹 설정 연결은 직접 구성 | `amplify_outputs.json` 자동 생성, Amplify 라이브러리가 바로 읽음 |
| 환경 나누기 | `samconfig.toml` 환경, 스택 이름 | 스택·앱을 코드로 나눔 | 개발자별 sandbox, 브랜치별 배포 |
| 로컬 실행 | `sam local invoke` 등 | (SAM CLI로 로컬 테스트 가능) | 클라우드 sandbox (로컬 에뮬레이터가 아님) |
| Git 연결형 웹 호스팅 통합 | 호스팅 리소스·파이프라인을 별도 구성 | 호스팅 리소스·파이프라인을 별도 구성 | Amplify Hosting과 같은 앱에서 브랜치별 배포 |
| 배포 준비물 | 올릴 S3 버킷 (`--resolve-s3`로 자동 생성, 또는 `--s3-bucket`) | 계정·리전 부트스트랩 (일반적인 경우) | 계정·리전 부트스트랩 (CDK 기반) |

## 그때 왜 옮겼나

다시 처음 장면으로 돌아갑니다. 에이전트의 비교 표에서 저를 움직인 차이는 이랬습니다.

- 로그인 정의가 YAML 수십 줄에서 `defineAuth` 몇 줄로 줄어든다.
- 웹이 쓰는 ID와 주소를 스크립트로 만들던 설정 파일 대신 `amplify_outputs.json`이 생긴다.
- 웹 호스팅과 배포가 한 Amplify 앱에서, Git push로 이뤄진다.
- 개발자별 sandbox와 브랜치별 환경이 생긴다.
- IoT·영상처럼 Amplify에 없는 것은 같은 백엔드 안의 CDK 코드로 둔다.
- 무엇보다 다른 프로젝트에서 이미 같은 구조를 써 와서 익숙하다.

다만 이 목록을 다시 읽어 보면 **"SAM이 못 하는 것"과 "그 프로젝트가 그렇게 짰던 것"이 섞여 있습니다.** 설정 파일을 스크립트로 만든 것, 호스팅을 별도 스택으로 손으로 배포하던 것은 그 프로젝트의 구성이었지 SAM의 한계가 아닙니다. SAM도 `samconfig.toml`로 환경을 여러 개 둘 수 있습니다. 공정하게 말하면 "SAM이 나빠서"가 아니라 **"웹 앱의 로그인·설정 전달·호스팅이 중심인 이 경우에 Gen 2가 더 맞았다"**입니다.

대가도 분명했습니다.

- **한 번 다시 만들고 다시 검증해야 합니다.** 템플릿을 옮겨 적는 것이 아니라 새 백엔드를 새로 배포하는 일입니다.
- **Cognito 사용자 풀이 새로 생깁니다.** 새 사용자 풀에는 기존 사용자가 없으므로 다시 가입해야 합니다. 사용자를 옮겨 오는 방법(사용자 이전 Lambda 트리거 등)도 있지만, 개발 단계이고 사용자가 모두 개발자여서 재가입으로 정했습니다.
- **옛 SAM 스택은 지우지 않고 그대로 둡니다.** 새 백엔드가 검증될 때까지 화면 확인은 옛 스택으로 하고, 옮긴 뒤에 삭제 여부를 따로 정하기로 했습니다.

이 글을 쓰는 지금도 옮기는 작업은 진행 중입니다. 새 백엔드는 아직 배포 전이라, 결과(배포 성공, 검증 통과)는 이 글에 적지 않습니다.

## 다음에 조심할 것

- **sandbox는 운영용이 아닙니다.** [공식 문서](https://docs.amplify.aws/react/deploy-and-host/sandbox-environments/setup/)는 클라우드 sandbox를 개발용으로 안내하고 운영 워크로드용이 아니라고 밝힙니다. 운영은 브랜치 배포로 둡니다.
- **삭제 보호를 켠 리소스는 정리 절차를 따로 적어 둡니다.** CloudFormation 문서에 따르면 `DeletionProtection: ACTIVE`인 사용자 풀은 보호를 끄기 전에는 지울 수 없습니다. 실수로 지우는 것을 막는 대신, sandbox나 시험 환경을 지울 때(`npx ampx sandbox delete`)도 이 풀만큼은 먼저 보호를 꺼야 한다고 보고 정리 순서에 넣어 둡니다.
- **게스트 접근 기본값을 확인합니다.** Gen 2는 게스트 접근을 기본으로 켭니다. 쓰지 않는다면 `cfnIdentityPool.allowUnauthenticatedIdentities = false`로 끕니다.
- **override 뒤에는 시험합니다.** `cfnResources`로 바꾼 설정은 Amplify 라이브러리가 기대하지 않는 모양일 수 있습니다. 문서의 권고대로 스테이징(또는 sandbox)에서 로그인부터 확인합니다.
- **두 체계가 한동안 함께 삽니다.** 옛 SAM 스택과 새 Gen 2 백엔드가 같은 계정에 동시에 있으면 사용자 풀, IoT 정책 같은 리소스가 두 벌이 됩니다. 이름이 겹치지 않게 하고, 웹이 어느 쪽을 가리키는지 늘 확인하고, 옮긴 뒤 옛 스택을 지울 시점을 미리 정해 둡니다. 두 벌인 동안은 비용도 두 번 나올 수 있습니다.
- **비교 표를 읽을 때 "도구의 한계"와 "그 프로젝트의 구성"을 나눕니다.** 이번에 받은 표에도 둘이 섞여 있었습니다. 다른 사람에게 이 결정을 설명할 때도 같은 구분을 지킵니다.

## 정리

- SAM, CDK, Amplify Gen 2는 모두 **CloudFormation 스택**을 만듭니다. 차이는 무엇으로 쓰고(YAML이냐 코드냐), 얼마나 미리 묶어 주느냐(리소스 단위냐 기능 단위냐)입니다.
- **SAM**은 CloudFormation 템플릿에 서버리스 줄임 문법을 더하고 배포 때 펼칩니다. SAM CLI의 로컬 실행과 개발 중의 `sam sync`가 강점입니다.
- **CDK**는 코드를 CloudFormation 템플릿으로 합성합니다. 구성 요소는 L1(CloudFormation과 일대일)·L2·L3 층으로 나뉩니다.
- **Amplify Gen 2**는 CDK 위에 얹은 프레임워크입니다. `define*` 기능, 개발자별 sandbox와 브랜치별 배포, `amplify_outputs.json`을 줍니다.
- **"+CDK"**는 같은 Gen 2 백엔드 안에서 (a) 없는 리소스를 `createStack()`으로 더하고, (b) 모자란 설정을 `cfnResources`의 L1 속성으로 고친다는 뜻입니다.
- 고르는 기준은 이렇게 잡습니다. 함수와 API가 중심인 서버리스 백엔드라면 **SAM**으로 충분합니다. 웹 앱의 로그인·데이터·호스팅이 중심이라면 **Gen 2**가 손이 덜 갑니다. 둘의 범위를 넘는 인프라는 **CDK**로 적습니다. Gen 2를 골랐다면 그 CDK를 같은 백엔드 안에 둘 수 있습니다.
