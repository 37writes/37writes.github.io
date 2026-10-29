---
title: "Amplify Hosting + Fargate 배포에서 실제로 부딪힌 함정 12가지와 해결"
date: 2026-10-29 15:05:00 +0900
categories: [AWS, 배포]
tags: [aws, amplify, fargate, ecs, cdk, cloudfront, vite, troubleshooting]
description: "웹은 Amplify Hosting, API는 Fargate로 혼자 배포하며 실제로 겪은 함정 12가지를 증상, 원인, 해결 순서로 정리합니다. 경로 공백, ARM64 exec format error, 스택 고착, mixed content, Vite 8 빌드 OOM까지 다룹니다."
---

> **시리즈: 1인 개발자의 AWS 배포**
> 1. [구조: 웹은 Amplify Hosting, API는 Fargate — 왜 이렇게 골랐나]({% post_url 2026-10-29-solo-dev-aws-deploy-architecture %})
> 2. **실제로 부딪힌 배포 함정들과 해결** ← 지금 글
> 3. CI/CD: API 이미지 빌드와 Fargate 배포 자동화 (예정)

## 어떤 구조를 올렸나

사내 웹 서비스 하나를 AWS에 혼자 올렸습니다. 구조는 이렇습니다.

- **웹(React SPA)**: Amplify Hosting. GitHub에 push하면 Amplify가 빌드해서 배포합니다.
- **로그인·데이터·파일**: Amplify Gen 2 백엔드로 만든 Cognito, DynamoDB, S3. 웹 배포와 별개로, 명령(`ampx sandbox`)으로 직접 올립니다.
- **API 서버**: 오래 열려 있는 연결(SSE)과 응답 뒤에도 계속 도는 작업이 있어서 Lambda 대신 컨테이너를 골랐습니다. ECS Fargate에서 돌고, 앞에 ALB와 CloudFront가 있습니다. CDK로 정의하고 내 Mac에서 배포 스크립트로 올립니다.

구조를 고른 이유는 [1편: 1인 개발자의 AWS 배포 구조]({% post_url 2026-10-29-solo-dev-aws-deploy-architecture %})에서 다룹니다. 이 글은 그 구조를 실제로 올리면서 막혔던 곳 12가지를 **증상 → 원인 → 해결** 순서로 정리합니다. 전부 직접 겪고 해결한 것들입니다. 함정은 한곳에 몰려 있지 않고, 아래 그림처럼 배포 경로 곳곳에서 터졌습니다.

<figure class="diagram">
{% include figures/solo-dev-aws-deploy-pitfalls/where-it-breaks.svg %}
<figcaption>API는 내 Mac에서, 웹은 Amplify 빌드 서버에서 배포되고, 함정은 두 경로의 단계마다 따로 있었습니다. 숫자는 아래 본문의 함정 번호입니다.</figcaption>
</figure>

(서비스 이름, 리소스 이름, 계정 정보는 예시 값으로 바꿨습니다. 코드도 개념을 보여 주는 최소 예시로 새로 썼습니다.)

## 내 Mac에서: 배포 도구를 돌리기 전

### 1. 경로에 공백이 있으면 ampx와 CDK가 모듈을 못 찾는다

**증상**: 프로젝트 폴더 경로에 공백이 있었습니다 (`~/Documents/My Projects/my-app` 같은 형태). 이 폴더에서 `npx ampx sandbox`나 `cdk deploy`를 돌리면 `Cannot find module` 오류로 실패했습니다.

**원인**: 제가 쓴 버전의 도구가 자산(asset) 경로를 다루는 과정에서 공백이 `%20`으로 인코딩됐고, 인코딩된 경로로 파일을 찾다가 실패했습니다. 코드에는 문제가 없고 경로 문자열의 문제입니다. 도구 버전에 따라 재현되지 않을 수도 있습니다.

**해결**: 공백 없는 경로(`/tmp/...`)에 필요한 소스만 복사(스테이징)하고 그곳에서 도구를 실행합니다. 매번 손으로 하면 빠뜨리므로 배포 스크립트가 자동으로 하게 했습니다.

```sh
STAGE=/tmp/my-api-src      # 공백 없는 경로
rm -rf "$STAGE" && mkdir -p "$STAGE/apps" "$STAGE/packages"
cp "$REPO/package.json" "$REPO/pnpm-lock.yaml" "$REPO/pnpm-workspace.yaml" "$STAGE/"
rsync -a --exclude node_modules --exclude dist "$REPO/apps/api/" "$STAGE/apps/api/"
rsync -a --exclude node_modules --exclude dist "$REPO/packages/shared/" "$STAGE/packages/shared/"   # API가 쓰는 공유 패키지
```

Amplify Hosting의 빌드 서버(리눅스)에서는 작업 경로에 공백이 없어서 이 문제가 없었습니다. 내 Mac에서 직접 돌리는 도구만 해당했습니다.

### 2. CDK가 자기 자신을 복사하다 ENAMETOOLONG

**증상**: 스테이징한 폴더에서 `cdk deploy`를 돌리니 이번에는 `ENAMETOOLONG`(경로가 너무 김) 오류가 났습니다.

**원인**: API 이미지는 모노레포 루트를 Docker 빌드 컨텍스트(이미지를 만들 때 Docker에 넘기는 폴더)로 씁니다. 공유 패키지를 함께 넣어야 해서입니다. 그런데 처음 스테이징할 때 CDK 앱 폴더와 `cdk.out`(CDK가 배포 산출물을 쓰는 폴더)을 그 컨텍스트 **안에** 두었습니다. CDK는 이미지 자산을 만들 때 컨텍스트 폴더를 `cdk.out` 아래로 복사하는데, 복사 대상 안에 `cdk.out`이 다시 들어 있는 구조가 되면서 경로가 계속 길어졌습니다. CDK 버전과 설정에 따라 출력 폴더를 알아서 빼 주기도 하지만, 제 구성에서는 이렇게 실패했습니다.

**해결**: 소스(Docker 컨텍스트)와 인프라(CDK 앱과 `cdk.out`)를 **형제 폴더**로 둡니다. 한쪽이 다른 쪽 안에 들어가지 않게 합니다.

```text
/tmp/my-api-src/     ← Docker 빌드 컨텍스트 (모노레포 소스)
/tmp/my-api-infra/   ← CDK 앱, cdk.out
```

```sh
export MONOREPO_DIR=/tmp/my-api-src   # CDK 앱은 이 경로를 이미지 컨텍스트로 씀
cd /tmp/my-api-infra && npx cdk deploy
```

형제로 두면 이 문제가 구조적으로 생기지 않습니다. 컨텍스트에는 `.dockerignore`도 두어 `node_modules`, `dist`, `cdk.out`, `.env*`를 뺍니다. 이미지가 가벼워지고, 로컬 비밀 파일이 이미지에 들어갈 위험도 줄어듭니다. 그래도 비밀 값은 처음부터 소스 폴더에 두지 않는 것이 안전합니다.

## 컨테이너 이미지와 CDK 스택

### 3. 계정에 기본 VPC가 없다

**증상**: 예제를 따라 기본 VPC를 쓰는 스택을 만들려니 VPC를 찾지 못했습니다.

**원인**: AWS 계정에는 보통 리전마다 기본(default) VPC가 있지만, 누군가 지웠거나 정리된 계정에는 없을 수 있습니다. 제가 쓴 계정이 그랬습니다.

**해결**: VPC를 CDK로 직접 만듭니다. 비용을 줄이려고 **public 서브넷만** 두고 NAT 게이트웨이는 0개로 했습니다. NAT 게이트웨이는 켜 두기만 해도 시간당 요금이 나갑니다. 대신 Fargate 태스크에 공인 IP를 붙여서 ECR, DynamoDB, S3, Bedrock에 직접 나가게 합니다.

```ts
const vpc = new ec2.Vpc(this, "Vpc", {
  maxAzs: 2,
  natGateways: 0,
  subnetConfiguration: [
    { name: "public", subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
  ],
});
const cluster = new ecs.Cluster(this, "Cluster", { vpc });

new ecsPatterns.ApplicationLoadBalancedFargateService(this, "Api", {
  cluster,
  assignPublicIp: true,                                   // 기본값 false. NAT가 없으면 꼭 켠다
  taskSubnets: { subnetType: ec2.SubnetType.PUBLIC },
  // ...
});
```

공인 IP가 없으면 태스크가 ECR에서 이미지를 받아 오지도 못합니다. 태스크가 public 서브넷에 있어도 보안 그룹이 ALB에서 오는 요청만 받게 되어 있으면 외부에서 바로 접속할 수 없습니다. 그래도 내부망에 꼭 숨겨야 하는 서비스라면 private 서브넷과 NAT(또는 VPC 엔드포인트) 비용을 감수하는 편이 맞습니다.

### 4. Fargate에서 `exec format error`

**증상**: 스택을 배포하니 이미지는 올라갔는데 태스크가 시작하자마자 꺼졌습니다. 로그에는 `exec format error` 한 줄뿐이었습니다.

**원인**: Docker는 플랫폼을 지정하지 않으면 빌드하는 머신의 아키텍처로 이미지를 만듭니다. Apple Silicon(ARM64) Mac에서 빌드하니 ARM64 이미지가 나왔습니다. 반면 Fargate는 따로 지정하지 않으면 x86_64로 태스크를 띄웁니다. 이미지와 태스크의 CPU 아키텍처가 달라 실행 파일을 실행하지 못한 것입니다.

**해결**: 이미지의 대상 아키텍처와 태스크 아키텍처를 같게 맞춥니다. 저는 태스크의 `runtimePlatform`을 ARM64로 바꾸고, 이미지 자산의 `platform`도 ARM64로 **명시**했습니다. 이미지 쪽을 명시해 두면 나중에 x86 CI 서버에서 빌드해도(에뮬레이션이라 느리지만) ARM64 이미지가 나와서 같은 문제가 다시 생기지 않습니다. ARM Mac에서는 에뮬레이션 없이 빌드하니 빠르고, ARM Fargate는 같은 사양의 x86보다 저렴합니다.

```ts
new ecsPatterns.ApplicationLoadBalancedFargateService(this, "Api", {
  runtimePlatform: {
    cpuArchitecture: ecs.CpuArchitecture.ARM64,
    operatingSystemFamily: ecs.OperatingSystemFamily.LINUX,
  },
  taskImageOptions: {
    image: ecs.ContainerImage.fromAsset(contextDir, {
      file: "apps/api/Dockerfile",
      platform: ecrAssets.Platform.LINUX_ARM64,   // 태스크와 같은 아키텍처
    }),
    containerPort: 8080,
  },
  // ...
});
```

### 5. 스택이 몇 시간째 `CREATE_IN_PROGRESS`

**증상**: 태스크가 계속 실패하던 배포에서 스택이 `CREATE_IN_PROGRESS`에서 멈춰 끝나지 않았습니다.

**원인**: CloudFormation은 ECS 서비스가 안정 상태(원하는 수의 태스크가 정상 실행)가 될 때까지 기다립니다. 태스크가 계속 실패하면 ECS는 태스크를 계속 다시 띄우고, CloudFormation은 최대 3시간까지 기다립니다. 실패를 알려 줄 장치가 없었던 것입니다.

**해결**: 멈춘 스택을 지운 뒤, ECS 배포 서킷 브레이커를 켜고 다시 배포했습니다. 서킷 브레이커가 있으면 태스크가 반복해서 실패할 때 ECS가 배포를 실패로 판정합니다. 그러면 CloudFormation도 기다리기를 멈추고 스택을 실패 처리합니다. 실패 판정까지 걸리는 시간은 태스크 시작과 헬스 체크 설정에 따라 다르지만, 3시간을 기다리지는 않습니다. (`rollback: true`는 이전에 성공한 배포가 있을 때 그 배포로 되돌리는 옵션입니다. 첫 배포는 되돌릴 대상이 없어 스택 생성 실패로 끝납니다.)

```ts
new ecsPatterns.ApplicationLoadBalancedFargateService(this, "Api", {
  circuitBreaker: { rollback: true },   // 태스크가 못 뜨면 빨리 실패 처리, 이전 배포로 롤백
  // ...
});
```

첫 배포부터 켜 두는 것을 권합니다. 4번 같은 단순한 실패도 서킷 브레이커가 없으면 몇 시간을 기다리게 됩니다.

## 브라우저: https 사이트에서 http API 부르기

### 6. Mixed content로 API 호출이 막힌다

**증상**: Amplify Hosting 사이트(https)에서 API를 부르는 요청이 전부 막혔습니다. 브라우저 콘솔에 mixed content 오류가 찍혔습니다.

**원인**: Amplify Hosting은 기본으로 https 주소를 줍니다. API의 ALB는 http였습니다. 브라우저는 https 페이지에서 http 주소를 부르는 것을 차단합니다. ALB에 https를 붙이려면 ACM 인증서가 필요하고, 인증서를 받으려면 내 도메인이 있어야 합니다. 도메인은 아직 없었습니다.

**해결**: ALB 앞에 CloudFront를 두었습니다. CloudFront 배포는 `*.cloudfront.net` 주소와 인증서를 기본으로 주므로 **도메인 없이** 브라우저에서 https로 부를 수 있습니다. API이므로 캐시는 끄고, 메서드와 헤더는 전부 넘깁니다. 그래야 `Authorization` 헤더(로그인 토큰)와 POST·PUT·DELETE 요청이 그대로 통과합니다.

```ts
const cdn = new cloudfront.Distribution(this, "ApiCdn", {
  defaultBehavior: {
    origin: new origins.LoadBalancerV2Origin(service.loadBalancer, {
      protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,   // CloudFront → ALB는 http
      readTimeout: Duration.seconds(60),   // 오리진 응답 대기 (기본 30초)
    }),
    viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
    allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
    cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
    originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
  },
});
```

웹 빌드에는 ALB 주소가 아니라 이 CloudFront 주소(`https://example.cloudfront.net`)를 API 주소 환경 변수로 넣습니다. 함께 챙길 것이 세 가지 있습니다.

- **SSE 같은 긴 응답**: ALB는 기본 유휴 시간(60초)에 연결을 끊으므로 `idleTimeout`을 늘렸습니다. CloudFront에도 오리진 응답을 기다리는 제한 시간(기본 30초, 데이터 조각 사이에도 적용)이 있어서 `readTimeout`을 60초로 늘렸습니다. 스트림이 이 시간보다 오래 조용하면 끊기므로, 서버가 그보다 짧은 간격으로 데이터를 보내야 합니다.
- **CORS**: 웹(Amplify 주소)과 API(CloudFront 주소)는 출처(origin)가 다르므로 API 서버가 CORS 응답을 따로 해야 합니다. 헤더를 넘겨 주는 `ALL_VIEWER` 정책이 CORS를 대신 처리해 주지는 않습니다. 저는 API 서버에서 CORS를 설정했습니다.
- **암호화 범위**: https는 브라우저 → CloudFront 구간입니다. CloudFront → ALB 구간은 http라서 토큰과 요청 본문이 AWS 네트워크 안에서 평문으로 갑니다. 이 구간까지 암호화해야 한다면 도메인을 사서 ALB에 인증서를 붙여야 합니다.

## Amplify Hosting 빌드

### 7. 빌드의 backend 단계가 두 번째 백엔드를 만들려다 실패한다

**증상**: GitHub를 연결한 첫 Amplify Hosting 빌드가 backend 단계에서 실패했습니다.

**원인**: Amplify Gen 2의 기본 빌드 설정은 backend 단계에서 `npx ampx pipeline-deploy`를 실행합니다. 이 명령은 **호스팅 앱과 브랜치 단위의 백엔드**를 배포합니다. 저는 이미 `ampx sandbox`로 Cognito, DynamoDB, S3를 만들어 쓰고 있었고, 호스팅 앱에는 아직 백엔드가 없었습니다. 그래서 빌드는 기존 것과 별개인 두 번째 백엔드를 새로 만들려 했고, 그러려면 빌드 역할의 추가 IAM 권한과 CDK 부트스트랩(CDK가 배포에 쓰는 버킷·역할을 계정에 미리 만드는 작업)이 필요해 실패했습니다. 성공했더라도 Cognito 사용자 풀과 테이블이 두 벌 생겨 웹과 API가 서로 다른 백엔드를 보게 될 상황이었습니다.

**해결**: `amplify.yml`에서 backend 단계를 빼고 **frontend만** 남겼습니다. 백엔드는 지금처럼 손으로 배포합니다.

```yaml
version: 1
frontend:              # backend: 단계 없음
  phases:
    preBuild:
      commands:
        - npm install -g pnpm@10
        - pnpm install --frozen-lockfile --filter "my-web..."
    build:
      commands:
        - pnpm --filter my-web build
  artifacts:
    baseDirectory: apps/web/dist
    files:
      - "**/*"
```

이렇게 하면 백엔드 변경은 push로 배포되지 않고, 배포하는 사람이 직접 올려야 합니다. 또 Amplify 공식 문서는 sandbox가 **개발용**이며 운영 워크로드용이 아니라고 안내합니다. 운영 백엔드는 호스팅 빌드에서 브랜치 단위로 배포하는(`pipeline-deploy`) 방식이 정석입니다. 저는 사내 개발 계정에 환경이 하나뿐이고 백엔드가 거의 바뀌지 않아 이 방식을 감수했습니다. 실제 사용자가 쓰는 운영 서비스이거나 백엔드를 자주 바꾼다면, 처음부터 `pipeline-deploy`로 백엔드를 만들고 빌드 역할에 필요한 권한을 주는 편이 맞습니다.

### 8. `amplify_outputs.json`이 없어서 빌드가 백엔드를 모른다

**증상**: backend 단계를 뺐더니 웹 빌드가 Cognito 설정을 읽지 못했습니다.

**원인**: 웹 앱은 `amplify_outputs.json`에서 사용자 풀 ID, 앱 클라이언트 ID, 버킷 이름 같은 값을 읽습니다. 이 파일은 backend 단계나 `ampx sandbox`가 만들어 주는데, 제 프로젝트에서는 `.gitignore`에 들어 있었습니다. 호스팅 빌드는 git에 있는 파일만 받으니 파일이 없습니다.

**해결**: `.gitignore`에서 빼고 **커밋**했습니다. 제 파일에 든 것은 공개 식별자뿐이었고, 어차피 웹 번들에 들어가 브라우저에서 누구나 볼 수 있는 값입니다. 다만 설정에 따라 이 파일에 API 키 같은 값이나 직접 추가한 출력이 들어갈 수 있으니 커밋 전에 내용을 확인합니다. 커밋하기 싫다면 빌드 중에 `npx ampx generate outputs`로 만드는 방법도 있지만, 그러려면 빌드가 백엔드 스택을 읽을 권한이 있어야 합니다. 보안은 이 값을 숨기는 것이 아니라, API가 Cognito 토큰을 검사하고 서버 역할의 IAM 권한을 좁게 주는 데서 지킵니다.

### 9. 빌드 컨테이너 메모리 부족, Vite 8을 7로 내려서 해결

가장 오래 걸린 함정입니다.

**증상**: Amplify 빌드가 `vite build` 단계에서 계속 `Build container ran out of memory`로 실패했습니다. 차례로 해 본 것들은 모두 효과가 없었습니다.

1. Node 힙 늘리기: `NODE_OPTIONS=--max-old-space-size=4096`, 이어서 `7168`
2. 소스맵 끄기, 큰 라이브러리를 청크로 나누기(`manualChunks`)
3. 빌드 컨테이너를 더 큰 사양(16GB)으로 올리기

그런데 **내 Mac에서는** 힙을 `--max-old-space-size=2048`로 줄여도 0.5초 만에 빌드가 끝났습니다.

**원인**: 원인을 바이너리 수준까지 파고들지는 못했습니다. 다만 빌드 로그의 경고가 단서였습니다.

```text
INVALID_ANNOTATION ... rolldown cannot interpret ...
```

Vite 8은 번들러로 rolldown(Rust로 만든 네이티브 번들러)을 씁니다. 같은 코드가 macOS(ARM64)에서는 금방 끝났으니 빌드 자체가 메모리를 많이 요구하는 것은 아니라고 봤습니다. 그래서 그때 쓴 Vite 8.0.x와 rolldown 초기 버전의 **리눅스용 바이너리**가 Amplify 빌드 컨테이너에서 메모리를 폭주시킨 것을 가장 유력한 원인으로 판단했습니다. `--max-old-space-size`는 Node(V8)의 JavaScript 힙 크기만 정하므로 네이티브 코드가 쓰는 메모리는 막지도 늘리지도 못합니다. 앞의 시도들이 효과가 없었던 것과도 맞습니다.

**해결**: Vite를 7로 내렸습니다. Vite 7은 프로덕션 번들링을 rolldown이 아니라 rollup이 합니다. React 플러그인도 Vite 7에 맞는 버전으로 맞췄습니다. 경고가 사라지고 빌드는 3초로 끝났습니다.

**덤으로 걸린 함정 두 개**:

- **lockfile에 Vite 8이 남아 있었습니다.** 웹은 Vite 7로 내렸는데 다음 빌드 로그에도 `vite v8...`이 찍혔습니다. 확인해 보니 API와 공유 패키지가 쓰는 vitest 4.1이 Vite 8을 끌어와 lockfile에 Vite 8이 함께 있었습니다. 저는 vitest를 3으로 내려 lockfile에서 Vite 8을 아예 없앴습니다. (pnpm `overrides`로 Vite 버전을 고정하는 방법도 있습니다.) `pnpm why vite`로 어떤 버전이 누구 때문에 깔리는지 확인할 수 있습니다.
- **빌드 캐시가 옛 설치를 되살렸습니다.** `amplify.yml`의 `node_modules` 캐시가 이전 빌드의 설치 결과를 그대로 가져와 새 lockfile이 반영되지 않았습니다. 캐시를 빼고 매번 새로 설치하게 했습니다. 이 두 가지를 정리한 뒤에야 로그에 Vite 7이 찍히고 빌드가 통과했습니다.

**교훈**: CI에서만 메모리가 부족하고 로컬에서는 재현이 안 되면, 메모리를 더 주기 전에 **네이티브 바이너리를 쓰는 도구**(번들러, 컴파일러)의 버전과 경고부터 의심합니다. 그리고 빌드 로그에 찍힌 버전이 내가 의도한 버전인지 확인합니다. 이 글은 제가 겪은 버전과 환경 기준이고, 이후 버전에서는 고쳐졌을 수 있습니다.

### 10. 무거운 루트 devDependency 때문에 설치가 느리다

OOM을 쫓으면서 처음 고친 곳입니다. OOM의 원인은 아니었지만 효과가 있어서 그대로 두었습니다.

모노레포 루트에는 인프라용 패키지(`aws-cdk-lib`, `@aws-amplify/backend` 등)가 devDependency로 있습니다. 웹 빌드에는 필요 없는데 `pnpm install`이 전부 설치하니 1,000개가 넘는 패키지를 받았습니다. 웹 패키지와 그 의존성만 설치하게 바꿨습니다.

```sh
pnpm install --frozen-lockfile --filter "my-web..."   # 끝의 ...은 의존성까지 포함
```

### 11. 배포 브랜치를 main으로 옮겼더니 첫 push에 빌드가 돌지 않는다

**증상**: 처음에는 기능 브랜치를 Amplify에 연결해 배포했습니다. 이를 main으로 옮기려고 콘솔에서 main 브랜치를 연결했습니다. 그러자 연결 직후의 첫 빌드는 실패했고, 그 뒤 main에 새 커밋을 push해도 빌드가 시작되지 않았습니다.

**원인**: 두 가지가 겹쳤습니다.

- Amplify Hosting은 저장소 전체가 아니라 **콘솔에서 연결한 브랜치만** 지켜봅니다. main을 연결하자 그 시점의 main 커밋으로 빌드가 돌았는데, 예전 main의 `amplify.yml`에는 7번에서 없앤 backend 단계가 남아 있었습니다.
- 연결 직후의 push는 자동 빌드를 시작하지 않았습니다. 이유는 확인하지 못했고, 그다음 push부터는 자동으로 빌드가 돌았습니다.

**해결**: 빌드를 직접 시작했습니다.

```sh
aws amplify start-job --app-id <앱 ID> --branch-name main \
  --job-type RELEASE --region ap-northeast-2
```

브랜치를 옮긴 뒤에는 **빌드가 실제로 돌았는지** 콘솔이나 `aws amplify list-jobs`로 확인합니다.

옛 브랜치 정리도 따로 해야 합니다. 앱 설정 `enableBranchAutoDeletion`이 `false`이면 (제 앱이 그랬습니다) GitHub에서 브랜치를 지워도 Amplify의 브랜치는 남고, 그 주소는 마지막 빌드로 계속 열립니다. `aws amplify delete-branch`로 지우거나, 앱 설정에서 자동 삭제를 켭니다.

## 권한: 에이전트에게는 읽기만

### 12. 에이전트에게 읽기 권한을 줬더니 잠깐 AccessDenied

이 작업들은 Claude Code 같은 AI 에이전트와 함께 했습니다. 에이전트가 쓰는 IAM 사용자에는 Amplify **읽기 권한만** 주었습니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["amplify:Get*", "amplify:List*"], "Resource": "*" }
  ]
}
```

에이전트는 브랜치 목록, 빌드 상태와 로그를 직접 볼 수 있습니다. 빌드 시작이나 브랜치 삭제 같은 쓰기는 사람이 내용을 확인한 뒤 관리자 프로필로 실행합니다.

**증상**: 정책을 붙인 직후 에이전트의 Amplify 조회 명령이 됐다 안 됐다 하며 잠깐 `AccessDenied`가 났습니다.

**원인**: IAM 변경은 모든 곳에 반영되기까지 시간이 걸릴 수 있습니다 (AWS 문서도 IAM이 최종적 일관성을 따른다고 안내합니다).

**해결**: 정책 자체가 맞는지부터 IAM 정책 시뮬레이터로 확인하면 "정책이 틀렸나, 아직 반영이 안 됐나"를 좁힐 수 있습니다. 시뮬레이션에는 `iam:SimulatePrincipalPolicy` 권한이 필요해서 저는 관리자 프로필로 돌렸습니다.

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:user/my-agent \
  --action-names amplify:ListApps amplify:ListBranches amplify:ListJobs amplify:GetJob \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

검사한 액션이 모두 `allowed`면 적어도 정책 문서는 맞습니다. 그다음에는 명령이 정말 그 사용자 자격 증명으로 실행되는지(`aws sts get-caller-identity`) 확인하고 잠시 뒤 다시 시도합니다. 시뮬레이터는 실제 호출의 조건을 모두 재현하지는 않으므로, 마지막 확인은 실제 명령입니다. 제 경우는 몇 분 뒤 정상으로 돌아왔습니다. 권한 시뮬레이션으로 배포 환경의 권한 누락을 찾은 사례는 [에이전트 하네스 첫 실전: 배포 환경에서만 실패하던 기능, 원인은 IAM 권한 누락]({% post_url 2026-10-28-dev-harness-first-bugfix-iam %})에 정리해 두었습니다.

## 배포 전 점검 목록

같은 구조를 올린다면 배포 전에 이것만 확인해도 위 함정 대부분을 피할 수 있습니다.

- [ ] 배포 도구를 실행하는 경로에 공백이 없는가 (있고 오류가 나면 `/tmp`로 스테이징)
- [ ] Docker 빌드 컨텍스트 안에 CDK 앱과 `cdk.out`이 들어 있지 않은가
- [ ] 계정에 기본 VPC가 있는가, 없으면 VPC를 CDK로 만드는가 (NAT 없이 public 서브넷이면 `assignPublicIp`)
- [ ] 이미지의 대상 아키텍처와 Fargate `runtimePlatform`이 같은가 (이미지 자산에 `platform`을 명시했는가)
- [ ] ECS 서비스에 `circuitBreaker: { rollback: true }`가 켜져 있는가
- [ ] 웹이 https면 API도 https인가 (도메인이 없으면 CloudFront), CORS와 긴 응답의 제한 시간은 맞췄는가
- [ ] `amplify.yml`의 backend 단계가 내가 백엔드를 배포하는 방식과 맞는가
- [ ] 호스팅 빌드가 올바른 백엔드 설정(`amplify_outputs.json`)을 받는가
- [ ] 빌드 로그에 찍힌 도구 버전이 의도한 버전인가 (`pnpm why`, 빌드 캐시)
- [ ] 브랜치를 연결하거나 옮긴 뒤 빌드가 실제로 돌았는가
- [ ] 에이전트·CI용 권한은 필요한 만큼만 주었는가

## 정리

- 함정은 대부분 **내 Mac과 클라우드의 차이**에서 나왔습니다. 경로의 공백, CPU 아키텍처, 리눅스 빌드 서버의 네이티브 바이너리가 그랬습니다. 로컬에서 된다는 것이 배포 환경에서도 된다는 뜻은 아닙니다.
- **실패가 빨리 드러나게** 만드는 설정(서킷 브레이커, 빌드가 돌았는지 확인)이 디버깅 시간을 가장 많이 줄였습니다.
- 증상이 가리키는 곳과 원인이 다른 경우가 많았습니다. 메모리 부족은 메모리를 늘려도 풀리지 않고 번들러 버전을 바꾸자 풀렸고, 권한 오류는 정책이 아니라 반영 지연이었습니다. 경고 한 줄과 "로컬에서는 되는가"를 먼저 확인합니다.

다음 편에서는 지금 손으로 하는 API 이미지 빌드와 Fargate 배포를 CI/CD로 자동화합니다.
