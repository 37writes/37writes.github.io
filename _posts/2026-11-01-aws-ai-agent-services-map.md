---
title: "AWS로 AI 에이전트 만들기 전에 알아야 할 서비스 지도: Bedrock, AgentCore, Strands Agents"
date: 2026-11-01 23:00:00 +0900
categories: [AWS, AI 에이전트]
tags: [aws, bedrock, agentcore, strands-agents, mcp, rag, guardrails]
description: "AWS에서 모델·도구·로그인을 갖춘 AI 에이전트 서비스를 만들 때 필요한 서비스를 두뇌(Bedrock), 손발(AgentCore Gateway), 루프(Strands Agents), 실행 장소(Runtime), 로그인(Cognito)으로 나눠 정리하고, 직접 호출해 본 결과와 만드는 순서를 함께 담았습니다."
---

## 어떤 문제였나

Claude Code를 Anthropic API가 아니라 Amazon Bedrock에 연결해서 쓰고 있었습니다. 대부분은 똑같이 동작했는데, 한 가지가 없었습니다. **웹 검색**입니다. 제 환경에서는 도구 목록에 `WebSearch`가 아예 보이지 않았고, 주소를 아는 페이지 하나를 가져오는 `WebFetch`만 있었습니다.

이유를 따라가 보니 도구가 **어디서 실행되는가**의 문제였습니다.

- **클라이언트 도구**: 모델이 "이 명령을 실행해"라고 말하면 Claude Code가 내 컴퓨터에서 실행합니다. 파일 읽기, Bash 같은 것들입니다. 모델을 어디서 빌려 오든 상관없이 동작합니다.
- **서버 도구**: 모델을 제공하는 쪽 서버가 직접 실행합니다. Anthropic API의 웹 검색이 여기에 속합니다. 모델을 Bedrock에서 빌려 오면 Anthropic 서버가 대신 검색해 주는 부분이 같이 빠집니다.

그래서 빠진 웹 검색을 **내 쪽 도구로 다시 붙이는 방법**을 찾기 시작했고, AWS에서는 Amazon Bedrock AgentCore의 Gateway와 Web Search 커넥터가 그 답이었습니다. 그런데 문서를 열자마자 이름이 쏟아졌습니다. Bedrock, AgentCore Runtime, Gateway, Identity, Memory, Strands Agents, Knowledge Bases, Guardrails…

이 글은 그 이름들을 **"에이전트를 만들 때 어떤 순서로 무엇이 필요해지는가"**로 엮은 지도입니다. 서비스 설명은 2026-11-01에 공식 문서로 다시 확인했고, 직접 호출해 본 결과는 따로 "직접 확인한 것" 절에 모았습니다. (계정 정보와 리소스 이름은 예시 값으로 바꿨습니다.)

## 에이전트 = 두뇌 + 손발 + 루프

먼저 설명 틀 하나를 정하고 갑니다.

- **두뇌(모델)**: 생각하고, 어떤 도구를 쓸지 고릅니다.
- **손발(도구)**: 실제로 무언가를 합니다. 검색, 사내 API 호출, 문서 조회 같은 것들입니다.
- **루프(에이전트 프레임워크)**: 모델에게 묻고 → 모델이 고른 도구를 실행하고 → 결과를 다시 모델에게 주는 일을 답이 나올 때까지 반복합니다.

Claude Code도 이 구조입니다. Claude Code 자체는 모델이 아니라 **루프 + 로컬 도구** 프로그램이고, 두뇌는 Anthropic API나 Bedrock에서 빌려 씁니다. 그래서 Bedrock으로 바꿔도 클라이언트 도구는 그대로 돌고, 서버 도구만 빠졌던 것입니다.

이 틀에서 중요한 점이 하나 있습니다. **새 모델이 나오면 두뇌만 갈아 끼우면 됩니다.** 잘 만들어 둔 도구와 데이터는 계속 씁니다. 그래서 오래 남는 자산은 도구와 데이터 쪽입니다.

AWS 서비스를 이 틀에 놓으면 이렇게 됩니다.

| 역할 | AWS에서 | 한 줄 설명 |
|---|---|---|
| 두뇌 | Amazon Bedrock | 여러 회사의 모델을 하나의 API로 호출 |
| 손발 | AgentCore Gateway (+ Lambda, Knowledge Bases, 커넥터) | 도구를 MCP 엔드포인트 하나로 묶어 제공 |
| 루프 | Strands Agents (또는 LangGraph 등) | 모델과 도구를 오가는 코드 라이브러리 |
| 실행 장소 | AgentCore Runtime | 그 루프 코드를 올려서 돌리는 서버리스 환경 |
| 로그인 | Amazon Cognito (+ IAM) | 사람은 로그인해서 토큰을 받고, 서버는 IAM 역할로 AWS를 호출 |

이제 하나씩 봅니다.

## 1. 두뇌: Amazon Bedrock

Bedrock은 여러 회사의 파운데이션 모델을 하나의 AWS API로 쓰게 해 주는 완전관리형 서비스입니다. 공식 문서 기준으로 100개 이상의 모델이 있고, 공급자는 Amazon(Nova), Anthropic(Claude), DeepSeek, Moonshot AI(Kimi), MiniMax, OpenAI, xAI 등입니다.

### 호출 방법은 여러 가지

| API | 특징 |
|---|---|
| Converse | 공급자와 상관없이 같은 요청 형식. tool use 지원 |
| InvokeModel | 공급자마다 다른 원래 요청 형식 그대로 |
| Anthropic Messages API 호환 | Anthropic SDK를 Bedrock 주소로 돌려서 사용 |
| OpenAI 호환 Responses / Chat Completions | OpenAI SDK 형태로 호출 |

처음 만든다면 **Converse**가 편합니다. 모델을 바꿀 때 요청 코드를 거의 고치지 않아도 되기 때문입니다. 두뇌를 갈아 끼우기 쉬워야 한다는 위의 원칙과 맞습니다.

모델 ID 앞에 `global.`이나 `apac.` 같은 접두사가 붙은 것은 **Cross-Region inference profile**입니다. 요청을 여러 리전에 나눠 보내 처리량을 높이는 방식이고, 저는 `global.anthropic.claude-haiku-5-5`, `apac.amazon.nova-lite-v1:0`을 이 형태로 썼습니다.

### Converse 최소 예시: 도구 호출을 강제해서 JSON 받기

모델 답을 정해진 JSON 모양으로 받고 싶을 때 쓸 수 있는 방법이 있습니다. 도구를 하나 정의하고 `toolChoice`로 **그 도구를 반드시 부르게** 하면, 모델은 자유 문장 대신 도구 입력(JSON)으로 답합니다. 문의 분류기를 시험 삼아 만들 때 이 방식을 썼습니다.

```python
import boto3

client = boto3.client("bedrock-runtime", region_name="ap-northeast-2")

classify_tool = {
    "toolSpec": {
        "name": "classify",
        "description": "고객 문의를 분류한 결과를 기록한다",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {
                "category": {"type": "string", "enum": ["shipping", "billing", "returns"]},
                "reason": {"type": "string"},
            },
            "required": ["category", "reason"],
        }},
    }
}

resp = client.converse(
    modelId="global.anthropic.claude-haiku-5-5",
    messages=[{"role": "user", "content": [{"text": "주문한 책이 일주일째 안 와요"}]}],
    inferenceConfig={"maxTokens": 300},  # temperature는 넣지 않는다 (아래 "직접 확인한 것" 참고)
    toolConfig={
        "tools": [classify_tool],
        "toolChoice": {"tool": {"name": "classify"}},  # 이 도구를 반드시 부르게 강제
    },
)

for block in resp["output"]["message"]["content"]:
    if "toolUse" in block:
        print(block["toolUse"]["input"])  # 예: {"category": "shipping", "reason": "..."}
```

### 두뇌에 붙는 곁가지 기능

에이전트를 만들다 보면 모델 호출 옆에 붙이고 싶은 것이 생깁니다. Bedrock 안에 이미 있는 기능들입니다.

**Knowledge Bases (RAG)**: 내 문서를 검색해서 답의 근거로 넣고, 답에 출처 인용도 붙입니다. 두 종류가 있습니다.

- **Managed Knowledge Base**: 수집, 색인, 저장, 검색을 Bedrock이 맡습니다. S3, SharePoint, Confluence, Google Drive, OneDrive, Web Crawler 커넥터가 있고, **AgentCore Gateway와 기본 연동**돼서 MCP 도구로 바로 붙일 수 있습니다.
- **Customer-managed Knowledge Base**: 벡터 저장소(OpenSearch Serverless, Aurora, Neptune 등)를 직접 두고 파이프라인을 직접 다룹니다. 서드파티 커넥터, 문서 단위 권한, Gateway 기본 연동은 Managed 쪽에만 있습니다.

**Guardrails**: 입력과 출력에 거는 필터입니다. 유해 콘텐츠(프롬프트 공격 포함), 금지 주제, 금지 단어, 개인정보(PII) 차단·마스킹, 답이 근거 문서에서 벗어났는지 보는 contextual grounding 검사, 논리 규칙으로 답을 검증하는 Automated Reasoning 검사가 있습니다. 모델 호출에 guardrail ID를 붙여 쓰거나, 모델 없이 `ApplyGuardrail` API로 따로 쓸 수 있습니다.

**Intelligent Prompt Routing**: 같은 계열의 작은 모델과 큰 모델 중 질문마다 하나를 골라 보냅니다. 쉬운 질문은 싼 모델로, 어려운 질문은 큰 모델로 보내 비용을 줄이는 기능입니다. 실제로 호출해 본 결과는 아래 "직접 확인한 것"에 있습니다.

**Bedrock 내장 Web Search**: 2026년 8월에 Bedrock 안에 웹 검색 서버 도구가 생겼습니다. 다만 **OpenAI GPT 모델을 Responses API로 쓸 때만** 쓸 수 있고, 리전도 미국 세 곳(버지니아 북부, 오하이오, 오레곤)뿐입니다. Claude 기반 구성에는 이 길이 없어서, 저는 AgentCore 쪽 Web Search를 골랐습니다.

## 2. 손발과 운영: Amazon Bedrock AgentCore

AgentCore는 문서 정의로 "어떤 프레임워크, 어떤 모델로든 에이전트를 만들고 배포하고 운영하는 플랫폼"입니다. 안에 서비스가 여러 개 있는데, **모듈식이라 하나만 써도 되고 같이 써도 됩니다.** Bedrock 모델만 써야 하는 것도 아닙니다.

서비스가 많아 보이지만, 처음 에이전트 서비스를 만들 때 알아야 할 것은 다섯 개입니다.

### Gateway: 도구를 꽂는 멀티탭

Gateway는 API, Lambda 함수, 기존 서비스를 **MCP(Model Context Protocol) 도구**로 바꿔 주거나, 이미 있는 MCP 서버들을 묶어서 **엔드포인트 하나**로 제공합니다. 에이전트는 이 주소 하나에 `tools/list`를 부르면 쓸 수 있는 도구 목록을 받습니다.

비유하면 **Gateway는 멀티탭이고, 커넥터는 AWS가 파는 완제품 플러그**입니다. 같은 멀티탭에 내가 만든 Lambda 도구, Knowledge Base, AWS가 만든 Web Search 커넥터를 같이 꽂을 수 있고, 모델은 이것을 전부 한 목록의 도구로 봅니다.

Gateway를 누가 부를 수 있는지(인바운드 인증)는 만들 때 정합니다.

| 방식 | 설명 |
|---|---|
| IAM (SigV4) | 호출하는 쪽의 AWS 자격 증명으로 서명을 확인하고, IAM 권한(`bedrock-agentcore:InvokeGateway`)으로 허용 여부를 판단 |
| JWT | Cognito, Okta 같은 ID 제공자가 발급한 토큰으로 판단 |
| `AUTHENTICATE_ONLY` | SigV4 서명으로 누구인지만 확인하고, 허용 판단은 뒤쪽(정책 엔진, interceptor Lambda, 대상 서비스)에 맡김 |
| `NONE` | 인증 없음. 판단을 전부 다른 곳에 맡김 |

뒤의 두 방식은 Gateway가 스스로 막지 않으므로, 다른 곳에서 권한을 꼭 검사해야 합니다. 서버가 자기 IAM 역할로 Gateway를 부르는 구조라면 IAM 방식이 가장 단순합니다. 권한 정책은 이런 모양입니다 (예시 계정 ID).

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "bedrock-agentcore:InvokeGateway",
    "Resource": "arn:aws:bedrock-agentcore:ap-northeast-1:123456789012:gateway/my-gateway-id"
  }]
}
```

### Web Search 커넥터

제가 처음 찾던 것이 이것입니다. Gateway에 `connectorId: "web-search"`로 대상을 하나 추가하면, 에이전트는 `WebSearch`라는 MCP 도구를 얻습니다. 검색어(200자 이하)를 보내면 결과마다 본문 발췌, URL, 제목, 게시일이 돌아옵니다.

직접 검색 API 업체와 계약하고, 키를 관리하고, 호출 코드를 서버에 올리는 일을 AWS가 대신 맡는 셈입니다. 알아 둘 점은 세 가지입니다.

- **리전**: 2026-11-01 문서 기준으로 us-east-1, us-east-2, us-west-2, eu-west-1, ap-southeast-2, ap-northeast-1(도쿄), us-gov-west-1입니다. **서울(ap-northeast-2)에는 없습니다.** 저는 가장 가까운 도쿄를 골랐습니다.
- **가격**: AgentCore 가격 페이지 기준 검색 1,000건에 $7입니다 (2026-11-01 확인).
- **이용 조건**: 사용자에게 보여 주는 답에 검색 결과를 쓰면 **출처 인용과 링크를 같이 보여 줘야** 합니다. 결과를 대량으로 저장하거나 경쟁 색인을 만드는 데 쓰는 것은 금지입니다.

검색 API(Tavily 같은 곳)를 직접 붙이는 방법도 있습니다. 두 방식의 품질과 속도는 아직 비교하지 못했습니다.

### Runtime: 루프 코드를 올리는 곳

Runtime은 에이전트 코드를 올려서 돌리는 **서버리스 실행 환경**입니다. 세션마다 격리되고, 오래 걸리는 비동기 작업도 지원하며, MCP와 A2A 프로토콜도 지원합니다. Strands Agents뿐 아니라 LangGraph, CrewAI, LlamaIndex, Google ADK, OpenAI Agents SDK 같은 다른 프레임워크로 짠 코드도 올릴 수 있습니다.

Runtime이 꼭 필요한 것은 아닙니다. 같은 코드를 ECS나 Lambda에 직접 올려도 됩니다. Runtime은 세션 격리와 확장을 대신 맡아 주는 선택지입니다.

### Identity, Memory, Observability

- **Identity**: 에이전트가 **사용자 대신** 외부 서비스(구글 캘린더, 슬랙 등)에 접근할 때 필요한 자격 증명과 인증을 관리합니다. Cognito, Okta, Microsoft Entra ID, Auth0 같은 기존 ID 제공자와 연동됩니다. "사람이 내 서비스에 로그인하는 것"(Cognito의 일)과는 다른 문제입니다.
- **Memory**: 대화 안에서의 단기 기억과, 세션을 넘어 남는 장기 기억을 제공합니다.
- **Observability**: 에이전트가 어떤 단계를 거쳐 답을 만들었는지 추적합니다. OpenTelemetry 형식이고 CloudWatch에서 봅니다. 모델을 바꿨을 때 무엇이 달라졌는지 볼 수 있어야 하므로, 서비스로 가면 사실상 필수입니다.

### 필요해지면 보는 것

나머지는 처음부터 알 필요는 없습니다. 이름만 기억해 두면 필요할 때 찾을 수 있습니다.

| 서비스 | 한 줄 설명 |
|---|---|
| Code Interpreter | 에이전트가 코드를 실행하는 격리된 환경 (Python, JavaScript, TypeScript) |
| Browser | 에이전트가 웹 페이지를 조작하는 클라우드 브라우저 |
| Policy | 도구 호출 직전에 규칙을 검사. Cedar와 호환되는 정책 언어로 작성 |
| Evaluations | 에이전트 답의 품질을 자동으로 평가 |
| Harness | 모델, 시스템 프롬프트, 도구만 넘기면 루프를 대신 돌려 주는 관리형 루프 |
| Registry | 조직 안의 에이전트, MCP 서버, 도구를 모아 두는 목록 |
| Optimization | 추적 기록을 바탕으로 프롬프트·도구 설명 개선안을 만들고 A/B 테스트 |
| Payments | 에이전트가 유료 API나 콘텐츠에 소액 결제 |

## 3. 루프: Strands Agents

Strands Agents는 AWS가 만든 오픈소스(Apache 라이선스) 에이전트 SDK입니다. Python과 TypeScript를 지원합니다. 모델과 도구, 지시문을 넘기면 SDK가 "모델에게 묻기 → 도구 실행 → 결과를 다시 모델에게" 루프를 돌려 줍니다. 모델 공급자는 Bedrock 말고도 Anthropic, OpenAI, Google, Ollama 등을 고를 수 있고, MCP 서버도 도구로 연결할 수 있습니다.

함수에 `@tool`을 붙이면 도구가 됩니다.

```python
# pip install strands-agents
from strands import Agent, tool
from strands.models import BedrockModel

@tool
def get_order_status(order_id: str) -> str:
    """주문 번호로 배송 상태를 조회한다."""
    return "배송 중"  # 실제로는 사내 API나 DB를 조회

model = BedrockModel(model_id="global.anthropic.claude-haiku-5-5", region_name="ap-northeast-2")
agent = Agent(
    model=model,
    tools=[get_order_status],
    system_prompt="너는 쇼핑몰 고객 지원 에이전트다.",
)

agent("주문 A-1024 어디쯤 왔나요?")
```

`@tool`은 함수의 이름, 타입 힌트, docstring으로 도구 설명을 만듭니다. strands-agents 1.63.0에서 위 함수의 `tool_spec`을 찍어 보면 `name`, `description`, `inputSchema.json`으로 된, 앞의 Converse 예시에서 손으로 썼던 `toolSpec`과 같은 모양이 나옵니다. Strands가 대신 해 주는 일이 바로 이 부분과, 모델이 도구를 고르면 그 함수를 실행해 결과를 다시 넘기는 반복입니다. (도구 설명이 만들어지는 것까지는 로컬에서 확인했고, 위 코드로 모델을 실제 호출해 보지는 않았습니다.)

### Strands, Runtime, Gateway는 서로 다른 층

이 셋이 가장 헷갈렸습니다. 셋 다 "에이전트"라는 말과 같이 나오기 때문입니다.

<figure class="diagram">
{% include figures/aws-ai-agent-services-map/layers.svg %}
<figcaption>Strands는 루프 코드, Runtime은 그 코드가 도는 곳, Gateway는 그 코드가 부르는 도구 입구입니다. 층이 달라서 하나만 바꿔 끼울 수 있습니다.</figcaption>
</figure>

- **Strands Agents**는 **코드 라이브러리**입니다. 내 노트북에서도, 컨테이너에서도 돕니다.
- **AgentCore Runtime**은 그 코드를 **올려서 돌리는 곳**입니다.
- **AgentCore Gateway**는 그 코드가 부르는 **도구의 입구**입니다.

그래서 조합이 자유롭습니다. Strands 대신 LangGraph나 Claude Agent SDK로 짜도 Runtime과 Gateway는 그대로 쓸 수 있고, Strands 코드를 Runtime이 아닌 곳에 올려도 같은 Gateway를 부를 수 있습니다.

## 4. 로그인과 사용자: Cognito (+ IAM)

서비스로 만들면 "누가 쓰는가"가 생깁니다. 여기서는 인증이 두 갈래로 나뉩니다.

- **사람 → 내 서버**: 사용자는 Cognito user pool로 로그인해서 JWT를 받고, 질문할 때 그 토큰을 붙입니다. 서버는 토큰을 검증해서 누구인지, 오늘 얼마나 썼는지를 확인합니다.
- **내 서버 → AWS**: 에이전트 서버는 자기 **IAM 역할**로 Bedrock과 Gateway를 호출합니다. 사용자가 Gateway를 직접 부르지 않습니다.

JWT, IAM(SigV4), Cognito가 각각 무엇이고 어떻게 다른지는 따로 정리한 인증 글에서 자세히 다룹니다. 개발 중에 IAM 사용자에 인라인 정책을 계속 붙이다가 **사용자당 인라인 정책 합계 2048자 한도**에 걸린 적이 있는데, 관리형 정책으로 옮겨서 해결했습니다.

## 전체 구조 (설계안, 아직 구현 전)

지금까지의 조각을 로그인해서 쓰는 웹/앱 서비스로 합치면 이렇게 됩니다. **아직 만들지 않은 설계안**입니다.

<figure class="diagram">
{% include figures/aws-ai-agent-services-map/service-map.svg %}
<figcaption>사용자는 Cognito로 로그인하고, 에이전트 서버(Runtime 위의 Strands 코드)가 두뇌(Bedrock)와 손발(Gateway)을 오가며 답을 만듭니다. 아직 구현 전인 설계안입니다.</figcaption>
</figure>

요청 하나는 이렇게 흐릅니다.

1. 사용자가 웹이나 앱에서 Cognito로 로그인하고 JWT를 받습니다.
2. 질문에 JWT를 붙여 에이전트 서버로 보냅니다. 서버는 토큰을 검증하고, 이 사용자의 사용량 한도를 확인합니다.
3. 서버의 루프(Strands)가 Bedrock 모델을 부릅니다. Guardrails가 입력과 출력을 검사합니다.
4. 모델이 도구를 고르면 서버가 Gateway를 부릅니다. Gateway 뒤에는 Web Search 커넥터, 내 Lambda 도구, Knowledge Base가 있습니다.
5. 사용자별 대화 기억은 Memory에, 사용자 대신 외부 서비스에 접근하는 권한은 Identity에 맡깁니다.
6. 이 모든 단계는 Observability로 추적합니다.

### 만드는 순서 (계획)

한 번에 다 만들지 않고, 앞 단계에서 만든 것을 뒤 단계에서 그대로 쓰는 순서로 잡았습니다. 이것도 계획이고 아직 진행 전입니다.

1. **도구 먼저**: Gateway + Web Search를 만들고 개발 도구(Claude Code)에 MCP로 붙여서, 도구가 제대로 도는지 직접 써 보며 확인합니다.
2. **작은 에이전트**: 같은 Gateway를 부르는 작은 에이전트를 Runtime에 올립니다. 로그인 없이 나 혼자 씁니다.
3. **사용자 붙이기**: Cognito 로그인, 웹 화면, 사용자별 사용량 한도를 붙입니다.
4. **확장**: Memory, Identity, 도구를 더합니다.

1단계에서 IAM 인증으로 만든 Gateway는 2단계 이후에도 그대로 씁니다. 개발 도구가 부르든 서버가 자기 IAM 역할로 부르든, Gateway 입장에서는 똑같이 SigV4로 서명된 IAM 호출이기 때문입니다.

### 서비스로 갈 때 꼭 둘 것: 사용자별 사용량 한도

모델 호출에도, 검색에도 **호출마다 돈이 듭니다.** 검색만 해도 1,000건에 $7입니다. 사용자가 생기면 한 사람이 요금을 크게 만들 수 있으므로, 서버에서 "이 사용자가 오늘 몇 번 썼나"를 세고 한도를 둬야 합니다. 이 판단은 토큰을 검증하는 백엔드에 둡니다.

## 직접 확인한 것

문서를 읽는 것과 실제로 불러 보는 것은 달랐습니다. 아래는 직접 호출해서 본 결과입니다.

### 기본 프롬프트 라우터는 질문에 따라 모델을 바꿨다 (2문항 시험)

서울 리전에서 `list-prompt-routers`로 기본 라우터를 조회하니 Nova 라우터와 Anthropic 라우터 두 개가 보였습니다. 각각에 쉬운 질문("2+2는?")과 어려운 질문(소수에 관한 증명)을 하나씩 보냈습니다. 응답에는 실제로 답한 모델이 찍혀 나옵니다.

| 라우터 | 쉬운 질문 | 어려운 질문 |
|---|---|---|
| Anthropic | Claude 3 Haiku, 411ms | Claude 3.5 Sonnet, 3773ms |
| Nova | Nova Lite, 547ms | Nova Lite, 932ms |

Anthropic 라우터는 난이도에 따라 모델을 바꿨고, Nova 라우터는 두 질문 모두 Lite로 보냈습니다. **질문 두 개로 본 결과라 라우터 성능을 일반화할 수는 없습니다.** 라우팅은 영어 프롬프트에 최적화돼 있다고 문서에 적혀 있다는 점도 감안해야 합니다.

더 걸리는 점은 라우터에 넣을 수 있는 모델입니다. 기본 Anthropic 라우터 뒤에 있는 것은 2024년의 Claude 3 계열입니다. 2026-11-01 기준 문서의 지원 모델 표에는 Nova Lite·Pro와 Llama 3.1·3.3 일부만 있습니다(같은 문서의 명령 예시에는 Claude 모델 ID가 들어 있어 표와 어긋납니다). **최신 Claude를 직접 만든 라우터에 넣을 수 있는지는 확인하지 못했습니다.** 최신 모델 사이에서 고르고 싶다면, 작은 모델에게 먼저 난이도를 판정시키고 그 결과로 모델을 고르는 방법도 있습니다. 이쪽은 어떤 모델이든 넣을 수 있습니다.

### 최신 모델은 예전 파라미터를 받지 않을 수 있다

Converse 호출에 늘 넣던 `temperature`를 Claude Haiku 5.5에 넣었더니 이런 오류가 났습니다.

```text
ValidationException: An error occurred (ValidationException) when calling the Converse operation:
The model returned the following errors: `temperature` is deprecated for this model.
```

`temperature`를 빼고 기본 설정으로 다시 돌려서 해결했습니다. "두뇌만 갈아 끼우면 된다"고 했지만, 실제로는 **모델을 바꾸면 받는 파라미터도 바뀔 수 있습니다.** 모델 교체 전에 같은 질문 묶음으로 미리 돌려 보는 평가 세트가 있어야 하는 이유입니다.

### 강제 tool use로 받은 JSON 분류는 호출당 1.1~1.6초

앞의 Converse 예시처럼 `toolChoice`로 도구 하나를 강제해서 Claude Haiku 5.5에게 문의 분류를 시켰습니다. 매번 정해진 JSON 모양으로 답이 왔고, 시험한 세 문장에서 호출 하나에 약 1.1~1.6초가 걸렸습니다.

### Web Search 커넥터는 서울에 없다

앞에서 적은 대로 Web Search 커넥터 지원 리전에 서울이 없어서 도쿄(ap-northeast-1)를 골랐고, Gateway도 도쿄에 만들기로 했습니다. 모델 호출은 서울에 둘 수 있으므로, 도쿄로 가는 것은 검색 요청뿐입니다. 이 Gateway 구축은 아직 진행 전입니다.

## 주의할 점

- **설계안과 확인한 것을 구분하세요.** 이 글의 전체 구조와 만드는 순서는 계획입니다. 직접 확인한 것은 바로 위 절의 내용입니다.
- **리전부터 확인하세요.** Web Search 커넥터처럼 서울에 없는 기능이 있고, Bedrock 내장 Web Search처럼 미국에만 있는 기능도 있습니다.
- **Gateway 인증을 `NONE`이나 `AUTHENTICATE_ONLY`로 두면** Gateway가 스스로 막지 않습니다. 정책 엔진이나 interceptor Lambda, 대상 서비스에서 권한을 검사해야 합니다.
- **검색 결과를 보여 줄 때는 출처를 같이 보여 주세요.** Web Search 커넥터의 이용 조건입니다.
- **모델을 바꾸기 전에 평가 세트로 먼저 돌려 보세요.** 파라미터 하나로도 코드가 깨질 수 있습니다.

## 정리

- 에이전트는 **두뇌(Bedrock) + 손발(AgentCore Gateway와 그 뒤의 도구) + 루프(Strands Agents 등)**입니다. 루프 코드를 올리는 곳이 AgentCore Runtime이고, 사람의 로그인은 Cognito가 맡습니다.
- Bedrock은 모델을 빌리는 곳입니다. Knowledge Bases(RAG), Guardrails(입출력 필터), Prompt Routing이 그 옆에 붙습니다.
- AgentCore는 모듈식입니다. 처음에는 Gateway, Runtime, Identity, Memory, Observability 다섯 개만 알면 됩니다.
- Strands, Runtime, Gateway는 층이 달라서 하나씩 바꿔 끼울 수 있습니다.
- 모델은 바뀌어도 도구와 데이터는 남습니다. 그래서 **도구(Gateway)부터** 만들고, 그 위에 에이전트와 로그인을 쌓는 순서가 좋다고 판단했습니다.
