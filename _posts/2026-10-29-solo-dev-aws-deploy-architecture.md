---
title: "1인 개발자의 AWS 배포 구조: 웹은 Amplify Hosting, API는 Lambda 대신 Fargate를 고른 이유"
date: 2026-10-29 15:00:00 +0900
categories: [AWS, 배포]
tags: [aws, amplify, ecs, fargate, lambda, cloudfront, cognito, cdk, sse]
description: "로그인 있는 SPA와 오래 도는 작업·SSE가 있는 API를 혼자 AWS에 올린 구조를 정리합니다. 웹은 Amplify Hosting, API는 CloudFront → ALB → Fargate 태스크 1개로 나눈 이유와 권한 두 층, 배포 방식, 이 구조를 추천하는 조건을 다룹니다."
---

> **시리즈: 1인 개발자의 AWS 배포**
> 1. **구조: 웹은 Amplify Hosting, API는 Fargate** ← 지금 글
> 2. 실제로 부딪힌 배포 함정들과 해결
> 3. CI/CD: API 이미지 빌드와 Fargate 배포 자동화 (예정)

## 어떤 문제였나

혼자 만든 사내 웹 서비스를 AWS에 올려야 했습니다. 로컬에서는 Vite 개발 서버(웹)와 Node.js API 서버가 따로 돌고 있었고, 로그인도 저장소도 공개 주소도 없었습니다. 올리면서 필요한 것은 이랬습니다.

- 로그인 화면이 있는 SPA(React)
- 데이터베이스와 파일 저장소
- API 서버. 그런데 이 API에는 **요청 하나로 끝나지 않는 일**이 두 가지 있었습니다.

첫째, **오래 도는 작업**입니다. 보고서 생성 요청(`POST`)을 받으면 서버는 `202 Accepted`로 바로 답하고, 작업은 그 서버 프로세스 안에서 계속 돕니다. 브라우저는 `GET`으로 진행 상태를 주기적으로 물어봅니다(폴링).

둘째, 채팅 에이전트의 **SSE(Server-Sent Events) 장기 연결**입니다. 서버가 AI의 답을 스트리밍하다가 "이 도구는 브라우저에서 실행해 줘"라고 요청을 보내면, 브라우저가 실행 결과를 별도 `POST`로 돌려줍니다. 서버는 그 결과를 **메모리에 걸어 둔 Promise로 최대 30초** 기다립니다.

```ts
// 개념 예시: 서버 메모리에 대기 중인 도구 호출을 걸어 둔다
const pending = new Map<string, (result: unknown) => void>();

function waitForToolResult(callId: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    pending.set(callId, resolve);
    setTimeout(() => {
      pending.delete(callId);
      reject(new Error("tool timeout"));
    }, 30_000);
  });
}

// 브라우저가 POST /api/tool-result 로 결과를 보내면
app.post("/api/tool-result", async (c) => {
  const { callId, result } = await c.req.json();
  const resolve = pending.get(callId);
  if (!resolve) return c.json({ error: "unknown callId" }, 404);
  pending.delete(callId);
  resolve(result);
  return c.json({ ok: true });
});
```

이 두 가지가 구조를 거의 다 정했습니다. 이 글은 그 결과로 나온 구성과 각 선택의 이유를 정리합니다. (서비스 이름, 리소스 이름, 계정 정보는 예시 값으로 바꿨습니다.)

## 왜 Lambda가 아니라 상시 컨테이너인가

처음 떠올린 것은 "전부 서버리스"였습니다. API Gateway + Lambda면 요청이 없을 때 비용이 거의 0이고 관리할 서버도 없습니다. 하지만 위의 두 기능과 맞지 않았습니다.

- **가장 큰 이유는 메모리 상태입니다.** Lambda는 요청마다 실행 환경이 따로 잡힐 수 있고, 별도 요청이 같은 메모리에 도착한다는 보장이 없습니다. SSE 연결을 잡고 있는 실행 환경과 도구 결과 `POST`를 받는 실행 환경이 다르면, 걸어 둔 Promise를 찾을 수 없습니다.
- **`202`로 답한 뒤 같은 프로세스에서 작업을 이어 가는 구조**도 그대로 옮기기 어렵습니다. 비동기 호출이나 응답 뒤에 코드를 더 돌리는 방법이 있긴 하지만, 지금 코드의 모양(한 프로세스가 작업을 들고 있고 폴링이 그 상태를 읽는 방식)과는 다릅니다.
- **SSE 장기 연결**도 응답 스트리밍 기능으로 흉내는 낼 수 있지만, 실행 하나는 최대 15분이고 위의 메모리 문제는 그대로 남습니다.

Lambda에 맞추려면 작업을 큐(SQS)와 별도 워커로 빼고, 대기 상태를 DynamoDB 같은 외부 저장소로 옮겨야 합니다. 가능은 하지만 지금 잘 돌아가는 코드를 크게 다시 써야 합니다.

그래서 **API는 상시 실행되는 컨테이너(ECS Fargate)**로 정했습니다. 로컬에서 돌던 Node.js 프로세스를 거의 그대로 컨테이너에 넣으면 됩니다.

대가도 분명합니다. 작은 Fargate 태스크 하나가 24시간 돌고, 그 앞에 ALB가 붙습니다. 요청이 없어도 매달 고정비가 나갑니다. 가장 작은 축에 드는 태스크(0.25 vCPU, 메모리 1GB) 하나와 ALB, 공인 IPv4 주소 요금을 합쳐 월 수십 달러 수준(low tens of dollars)으로 봤습니다. 정확한 금액은 리전과 시점의 요금표로 확인해야 합니다. "전부 서버리스"보다 무겁지만, 프로세스 안에서 도는 작업과 SSE를 그대로 쓰는 값으로 받아들였습니다.

## 전체 구성

<figure class="diagram">
{% include figures/solo-dev-aws-deploy-architecture/topology.svg %}
<figcaption>브라우저는 웹을 Amplify Hosting에서 받고, API 요청은 별도의 CloudFront → ALB → Fargate 태스크 1개로 보냅니다.</figcaption>
</figure>

브라우저가 가는 길은 두 개입니다.

| 경로 | 구성 | 배포 |
|---|---|---|
| 웹 (정적 파일) | Amplify Hosting (내부적으로 CloudFront) | `main`에 push하면 자동 빌드·배포 |
| API | CloudFront → ALB → ECS Fargate (ARM64, 태스크 1개) | 로컬에서 스크립트로 배포 |

- **인증**은 Cognito User Pool입니다. 브라우저가 로그인해서 받은 토큰을 API 요청에 붙입니다.
- **데이터**는 DynamoDB 테이블 하나, **파일**은 S3 버킷 하나입니다.
- **AI 호출**은 API 서버가 Bedrock을 부릅니다.
- 리전은 서울(`ap-northeast-2`)입니다.

그림에는 주요 요청 경로만 그렸습니다. 파일 업로드처럼 브라우저가 S3에 직접 가는 경로는 아래 "권한" 절에서 다룹니다.

아래에서 구성 요소마다 왜 그렇게 했는지를 설명합니다.

### API 앞의 CloudFront는 캐시가 아니라 HTTPS 때문

ALB만 두면 API 주소는 `http://my-api-alb-123.ap-northeast-2.elb.amazonaws.com` 같은 **http** 주소입니다. ALB에 HTTPS를 붙이려면 TLS 인증서(보통 ACM으로 발급·관리)가 필요하고, 그 인증서는 내 도메인 이름으로 받아야 합니다. ALB 기본 주소로는 받을 수 없습니다.

그런데 Amplify Hosting이 주는 웹 주소는 **https**입니다. https 페이지에서 http API를 부르면 브라우저가 **혼합 콘텐츠(mixed content)**로 막습니다.

커스텀 도메인은 아직 미루기로 했으므로, ALB 앞에 **CloudFront 배포를 하나 더** 붙였습니다. CloudFront는 기본 주소(`https://d111111abcdef8.cloudfront.net`)에 인증서를 무료로 붙여 주므로, 도메인 없이 API를 https로 열 수 있습니다.

이 CloudFront는 캐시 용도가 아닙니다. 그래서 설정은 "그대로 통과"에 맞춥니다.

```ts
// 개념 예시 (CDK)
new cloudfront.Distribution(this, "ApiCdn", {
  defaultBehavior: {
    origin: new origins.LoadBalancerV2Origin(alb, {
      protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY, // CloudFront → ALB는 http
    }),
    viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
    allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,          // POST·PUT·DELETE도 통과
    cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,          // 캐시 끔
    originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER, // 헤더·쿼리 전부 전달
  },
});
```

- **캐시 끔**: API 응답이 캐시되면 다른 사용자의 데이터가 섞일 수 있고, SSE 스트림도 깨집니다.
- **메서드 전부 허용**: 기본값은 `GET`·`HEAD`만 통과합니다.
- **헤더 전부 전달**: 그래야 `Authorization` 헤더(Cognito 토큰)가 서버까지 갑니다.

https가 되는 구간은 **브라우저 → CloudFront**까지입니다. CloudFront → ALB 구간은 AWS 안이긴 해도 평문 http입니다. 이 구간까지 암호화하려면 결국 도메인과 인증서가 필요합니다.

SSE는 타임아웃도 챙겨야 합니다. 연결이 오래 열려 있고, 서버가 도구 결과를 기다리는 동안(최대 30초)은 아무것도 보내지 않을 수 있기 때문입니다.

- **ALB 유휴 시간 제한**(idle timeout): 기본 60초 → 10분으로 늘렸습니다.
- **CloudFront 오리진 응답 대기 시간**(response timeout): 기본 30초 → 60초로 늘렸습니다. 이 값은 첫 응답뿐 아니라 응답 조각 사이의 간격에도 적용되므로, 서버가 조용히 기다리는 30초보다 길어야 합니다.

### 태스크가 1개인 이유

Fargate 서비스의 태스크 수(`desiredCount`)는 **1**입니다. 앞에서 본 "메모리에 걸어 둔 도구 호출 맵" 때문입니다.

태스크가 2개면 ALB가 요청을 나눠 보냅니다. SSE 연결은 태스크 A에 있는데 도구 결과 `POST`가 태스크 B로 가면, B의 맵에는 그 `callId`가 없으니 404가 납니다.

늘리려면 대기 상태를 Redis나 DynamoDB 같은 외부 저장소로 빼고, 결과를 연결이 있는 태스크에 전달하는 방법이 있어야 합니다. 지금 규모에서는 1개로 충분하므로 확장은 보류했습니다. 그 대신 태스크가 뜨지 못할 때 빨리 실패하고 되돌리도록 배포 circuit breaker를 켜 두었습니다.

다만 "항상 1개"는 아닙니다. `desiredCount`는 평소 유지할 목표 수이고, 기본 롤링 배포 설정에서는 보통 **새 태스크가 뜬 뒤 옛 태스크가 내려가므로 잠깐 2개가 겹칩니다.** 옛 태스크가 내려가면 그 안에서 돌던 작업과 SSE 연결, 대기 중인 도구 호출도 같이 사라집니다. 태스크가 재시작될 때도 마찬가지입니다.

그래서 작업 상태는 메모리에만 두지 않고 DynamoDB에 기록합니다. 작업이 도는 동안 주기적으로 갱신 시각을 남기고, 일정 시간 갱신이 없는 작업은 실패로 보여 줍니다. 작업이 사라져도 브라우저가 "진행 중"을 영원히 기다리지는 않게 하는 정도입니다. 배포하는 순간 쓰던 사용자는 작업을 다시 요청해야 합니다. 이 구조의 한계입니다.

### NAT Gateway 없는 VPC

이 계정에는 기본 VPC가 없었습니다. 그래서 CDK로 VPC를 새로 만들었는데, **public 서브넷만** 두고 NAT Gateway는 0개로 했습니다.

```ts
// 개념 예시 (CDK)
const vpc = new ec2.Vpc(this, "Vpc", {
  maxAzs: 2,
  natGateways: 0,
  subnetConfiguration: [{ name: "public", subnetType: ec2.SubnetType.PUBLIC }],
});
```

Fargate 태스크를 private 서브넷에 두면 Bedrock·DynamoDB·S3·ECR에 나가기 위해 NAT Gateway나 서비스별 VPC 엔드포인트가 필요합니다. 둘 다 시간당 요금이 붙는 항목이 있어서(S3·DynamoDB용 게이트웨이 엔드포인트는 무료), 1인 서비스에서는 태스크 비용보다 커질 수도 있습니다. 대신 태스크를 public 서브넷에 두고 공인 IP를 줘서 바로 나가게 했습니다. 들어오는 트래픽은 보안 그룹이 ALB에서 오는 것만 허용합니다.

### ARM64 컨테이너

이미지는 ARM64로 빌드하고, Fargate 태스크도 ARM64(Graviton)로 실행합니다. Apple Silicon Mac에서 빌드한 이미지를 그대로 쓸 수 있고, 같은 사양이면 ARM Fargate가 x86보다 쌉니다. 태스크 정의와 이미지 빌드 양쪽에 아키텍처를 똑같이 적어야 한다는 점은 2편에서 다룹니다.

## Amplify Gen 2는 어디까지 쓰나

Amplify라고 하면 보통 "웹 호스팅 + 백엔드까지 한 번에"를 떠올립니다. 이 프로젝트는 Amplify를 **일부만** 씁니다. 여기서 Amplify는 코드로 백엔드를 정의하는 **Gen 2**(`ampx`, `@aws-amplify/backend`)입니다.

| 맡은 것 | 도구 | 배포 방법 |
|---|---|---|
| 웹 호스팅 | Amplify Hosting | `main` push → 자동 |
| 인증·DB·스토리지 (Cognito, DynamoDB, S3) | Amplify Gen 2 백엔드 (`amplify/` 폴더, 코드로 정의) | 로컬에서 `ampx sandbox --once`로 직접 |
| API (ALB, Fargate, CloudFront) | AWS CDK 스택 (Amplify 밖) | 로컬에서 `deploy.sh` |

Amplify Gen 2의 데이터 기능은 AppSync(GraphQL) 모델이 기본입니다. 이 서비스는 DynamoDB 테이블 하나에 PK/SK로 접근하는 방식이라, 테이블은 Amplify 백엔드 안에 CDK 코드로 직접 정의했습니다.

```ts
// 개념 예시: amplify/backend.ts
const backend = defineBackend({ auth, storage });

const dataStack = backend.createStack("app-data");
const table = new Table(dataStack, "MainTable", {
  partitionKey: { name: "PK", type: AttributeType.STRING },
  sortKey: { name: "SK", type: AttributeType.STRING },
  billingMode: BillingMode.PAY_PER_REQUEST,
});

// 웹과 API가 읽을 수 있게 amplify_outputs.json에 이름을 내보낸다
backend.addOutput({ custom: { tableName: table.tableName } });
```

몇 가지를 정했습니다.

- **`amplify.yml`은 frontend만** 둡니다. 처음에는 Hosting 빌드가 백엔드까지 배포하게(`backend` 단계) 했다가 뺐습니다. 이미 손으로 배포한 백엔드와 충돌했기 때문입니다. 자세한 경위는 2편에서 다룹니다.
- **백엔드는 `ampx sandbox --once`로 손으로 배포**합니다. 다만 Amplify 문서는 sandbox를 개발자용 환경으로 안내하고, 운영 워크로드용이 아니라고 밝힙니다. 지금은 이렇게 두었지만, 정식 운영 환경이라면 다시 정해야 할 부분입니다.
- **`amplify_outputs.json`은 커밋**합니다. 이 파일에는 User Pool ID, 클라이언트 ID, 테이블·버킷 이름 같은 **공개 식별자**만 들어 있습니다. 어차피 웹 번들에 들어가 브라우저로 내려가는 값이고, 비밀은 없습니다. 커밋해 두면 Hosting 빌드와 API 배포 스크립트가 같은 파일을 읽어 **같은 Cognito 풀·테이블·버킷**을 가리킵니다.

## 권한은 두 층으로 나눈다

권한 질문을 두 개로 나누면 설계가 단순해집니다.

| 층 | 묻는 것 | 누가 판단하나 |
|---|---|---|
| 앱 권한 | "이 **사용자**가 앱을 써도 되나?" | Cognito JWT. API가 보호된 모든 라우트에서 토큰을 검증하고 `sub`를 사용자 ID로 씁니다. |
| AWS 권한 | "이 **서버**가 Bedrock·DynamoDB·S3를 불러도 되나?" | Fargate 태스크 IAM 역할. 필요한 동작과 리소스만 허용합니다. |

토큰 검증은 "로그인한 사람인가"까지만 답합니다. "이 데이터가 이 사람 것인가"는 API가 따로 지킵니다. DynamoDB에는 키 앞에 사용자 ID(`sub`)를 붙여 저장하고, 요청한 사용자의 키만 읽고 씁니다.

사용자에게는 AWS 권한을 거의 주지 않습니다. 예외는 **파일 업로드**입니다. 브라우저는 API가 서명해 준 URL(presigned URL)로 S3에 직접 파일을 올리고, 그 경로는 사용자별(`user/<사용자 ID>/…`)입니다. API는 요청한 사용자의 경로에 있는 파일만 다시 읽습니다. Amplify Storage 규칙도 로그인한 사용자에게 자기 경로만 허용합니다. 이 규칙의 "사용자 ID"는 User Pool의 `sub`가 아니라 Cognito Identity Pool이 주는 identity ID라는 점은 헷갈리기 쉽습니다. Bedrock·DynamoDB는 사용자가 직접 부를 수 없고, 반드시 API 서버를 거칩니다.

API 키 같은 **비밀은 Secrets Manager**에 두고, ECS가 태스크를 시작할 때 환경변수로 넣어 줍니다. 코드나 CDK 소스에는 들어가지 않습니다. 여기서 역할이 하나 더 나옵니다.

- **태스크 실행 역할**(execution role): ECS가 태스크를 띄울 때 쓰는 역할입니다. 이미지를 ECR에서 받고, 비밀을 Secrets Manager에서 읽어 환경변수로 넣습니다.
- **태스크 역할**(task role): 앱 코드가 AWS를 부를 때 쓰는 역할입니다. Bedrock·DynamoDB·S3 권한은 여기에 둡니다.

비밀은 태스크가 시작할 때 한 번 읽으므로, 비밀 값을 바꾸면 새 태스크를 띄워야 반영됩니다.

```ts
// 개념 예시 (CDK)
const apiKey = secretsmanager.Secret.fromSecretNameV2(this, "ApiKey", "my-app/external-api-key");

taskImageOptions: {
  secrets: { EXTERNAL_API_KEY: ecs.Secret.fromSecretsManager(apiKey) },
  environment: { TABLE_NAME: tableName, S3_BUCKET: bucketName },
}
```

태스크 역할에 권한이 빠지면 "로컬에서는 되는데 배포하면 안 되는" 문제가 생깁니다. 실제로 겪은 사례는 [배포 환경에서만 실패하던 기능, 원인은 IAM 권한 누락]({% post_url 2026-10-28-dev-harness-first-bugfix-iam %})에 정리했습니다.

## 웹과 API 연결

- **개발**: Vite 개발 서버의 `/api` 프록시가 로컬 API로 넘깁니다. 같은 출처(origin)라 CORS가 필요 없습니다.
- **운영**: 빌드할 때 `VITE_API_URL`에 API의 CloudFront 주소를 넣습니다. 이 값은 Amplify 앱의 환경변수로 설정해 두고, 웹의 fetch 코드는 이 값을 앞에 붙여 요청합니다.

```ts
// 개념 예시
const API_BASE = import.meta.env.VITE_API_URL ?? ""; // 개발에서는 빈 문자열 → /api 프록시
fetch(`${API_BASE}/api/reports`, { headers: { Authorization: `Bearer ${idToken}` } });
```

운영에서는 웹(`*.amplifyapp.com`)과 API(`*.cloudfront.net`)의 출처가 다르므로 CORS가 필요합니다. 지금은 허용 출처를 `*`로 열어 두었습니다. 데이터를 바꾸는 라우트는 모두 Cognito 토큰을 요구하므로, 다른 사이트가 토큰 없이 사용자의 데이터를 건드릴 수는 없다고 판단했습니다. 그래도 정확한 웹 주소로 좁히는 것이 맞으므로, 허용 출처를 환경변수로 받게 해 두고 나중에 좁힐 예정입니다.

## 배포는 지금 어떻게 하나

| 대상 | 방법 |
|---|---|
| 웹 | `main`에 push하면 Amplify Hosting이 빌드·배포 |
| 백엔드 (Cognito·DB·S3) | 바뀔 때만 로컬에서 `ampx sandbox --once` |
| API | 로컬에서 `deploy.sh` |

API 배포 스크립트는 이런 순서로 돕니다.

1. 저장소를 **공백 없는 경로**(`/tmp/...`)에 복사합니다. 저장소 경로에 공백이 있으면 CDK 자산 번들링이 실패했기 때문입니다 (2편에서 다룹니다).
2. ARM64 Docker 이미지를 빌드합니다.
3. ECR에 올리고 `cdk deploy`로 스택을 갱신합니다.

적용하기 전에는 `deploy.sh --diff`로 **무엇이 바뀌는지 먼저 봅니다**. 이 모드는 `cdk diff`만 실행하고, 배포된 리소스에는 변경을 적용하지 않습니다. IAM 정책이나 네트워크가 바뀌는 배포라면 이 미리보기를 확인한 뒤에 적용합니다.

웹은 push만 하면 되지만, API는 아직 사람이 손으로 배포합니다. 이 부분을 GitHub Actions로 자동화하는 것은 3편에서 다룰 예정입니다.

## 비용 감시: Bedrock 일일 알람

고정비(Fargate·ALB)는 예측할 수 있지만, AI 호출 비용은 쓰는 만큼 늘어납니다. 그래서 Bedrock 비용을 지켜보는 CloudWatch 알람을 두 개 걸었습니다. CloudWatch에 올라오는 Bedrock 사용량 지표에 **지표 수식(Metric Math)**으로 단가를 곱해 하루 비용을 추산하고, 기준을 넘으면 SNS로 메일을 보냅니다. 청구서 금액이 아니라 추산이므로, 어떤 모델과 리전을 수식에 넣었는지에 따라 실제와 차이가 날 수 있습니다.

| 알람 | 기준 (예시) | 뜻 |
|---|---|---|
| 페이스 | 하루 $10 | 이대로 가면 한 달 $300 |
| 급증 | 하루 $30 | 뭔가 잘못 돌고 있다 |

1인 개발에서는 이상 징후를 볼 사람이 나 하나입니다. 대시보드를 매일 열 거라고 기대하기보다 메일이 오게 해 두는 편이 확실합니다.

## 이 구조를 추천하는 조건, 추천하지 않는 조건

**이런 조건이면 이 구조가 맞습니다.**

- API에 **응답 후에도 프로세스 안에서 계속 도는 작업**이나 **SSE·WebSocket 같은 장기 연결**이 있다.
- 서버 메모리에 잠깐 들고 있는 상태가 있고, 당장 외부 저장소로 뺄 여유가 없다.
- 로컬에서 돌던 Node.js(또는 다른) 서버를 **거의 그대로** 올리고 싶다.
- 월 수십 달러의 고정비를 감당할 수 있다.

**이런 조건이면 다른 구조를 먼저 검토할 만합니다.**

- API가 짧은 요청/응답뿐이라면, **API Gateway + Lambda**가 더 싸고 단순할 수 있습니다. 요청이 적은 서비스라면 차이가 더 커집니다.
- 오래 걸리는 작업이 있어도 큐와 워커로 나눌 수 있다면 서버리스로 갈 수 있습니다. 다만 코드를 다시 짜는 비용이 듭니다.
- 사용자가 많아 태스크를 여러 개 띄워야 한다면, 메모리 상태를 먼저 밖으로 빼야 합니다. 이 글의 "태스크 1개" 전제는 맞지 않습니다.
- 이미 커스텀 도메인이 있다면 ALB에 ACM 인증서를 바로 붙이면 되므로, API 앞의 CloudFront가 꼭 필요하지는 않습니다.

## 버린 안과 미룬 것

- **커스텀 도메인**: 미뤘습니다. 지금은 CloudFront 기본 주소로 https를 얻습니다.
- **태스크 여러 개**: 메모리 상태 때문에 보류했습니다.
- **Amplify Hosting이 백엔드까지 배포**: 손으로 배포한 백엔드와 충돌해서 포기했습니다. Hosting은 웹만 맡습니다.

## 정리

- 오래 도는 작업과 SSE 장기 연결 때문에 API는 **Lambda가 아니라 Fargate 상시 컨테이너**로 올렸습니다. 대가는 월 수십 달러의 고정비입니다.
- 웹은 **Amplify Hosting**이 `main` push마다 배포합니다. 인증·DB·스토리지는 Amplify Gen 2 백엔드로 코드에 정의하고, API는 Amplify 밖의 CDK 스택입니다.
- API 앞의 **CloudFront는 https를 얻기 위한 것**입니다. 캐시를 끄고 메서드·헤더를 전부 통과시킵니다.
- 메모리 상태 때문에 **태스크는 1개**, 비용 때문에 **NAT Gateway는 0개**입니다.
- 권한은 **앱 권한(Cognito JWT)**과 **AWS 권한(태스크 IAM 역할)** 두 층으로 나눴습니다.

다음 편에서는 이 구조를 실제로 올리면서 부딪힌 배포 함정들과 해결 방법을 정리합니다.
