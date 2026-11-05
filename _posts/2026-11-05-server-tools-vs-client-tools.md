---
title: "서버 도구 vs 클라이언트 도구: Bedrock으로 Claude Code를 쓰니 웹 검색이 사라진 이유"
date: 2026-11-05 14:00:00 +0900
categories: [AWS, AI 에이전트]
tags: [aws-concepts, claude-code, tool-use, mcp, bedrock, agentcore, web-search]
description: "Claude Code를 Bedrock에 연결하면 왜 웹 검색만 빠질까요? 모델·하네스·도구의 경계, tool use 왕복, 서버 도구와 클라이언트 도구의 차이를 공식 문서로 짚고, MCP와 AgentCore로 검색을 다시 달 때 주의할 점을 정리합니다."
---

## 검색이 사라진 순간

회사 AWS 계정의 Amazon Bedrock에 Claude Code를 연결해서 쓰고 있었습니다. 어느 날 어떤 제품 이름을 찾아 달라고 했더니, 에이전트가 "이 환경에서는 웹 검색이 막혀 있다"고 답했습니다.

에이전트는 우회로도 시도했습니다. 검색 엔진의 결과 페이지 주소를 만들어 `WebFetch`로 직접 가져오는 방법이었습니다. 결과는 좋지 않았습니다. 엉뚱한 페이지가 오거나, `429`로 거절당하거나, captcha가 떴습니다. 봇 차단에 걸린 것입니다. 주소를 아는 페이지를 읽는 일은 잘 됐지만, **어디 있는지 모르는 것을 찾는 일**은 할 수 없었습니다.

여기서 질문이 줄줄이 나왔습니다.

- 웹 검색은 왜 막혀 있지? 모델이 모르는 건 알아서 검색해 오는 것 아니었나?
- Bedrock이 준 기능은 어디까지고, 내 컴퓨터에서 돌아간 기능은 무엇이지?
- "클라이언트 도구"라는 말이 나오는데, 그게 뭐지? 내가 설치한 건가, 원래 있던 건가?
- 무엇보다, Claude Code가 곧 모델이라고 생각했는데 막상 검색이 안 되니 무엇이 어디서 돌아가는지 모르겠더군요.

그때는 답을 듣고 작업을 이어 갔지만, 개념은 제대로 정리하지 못하고 지나갔습니다. 이 글은 그 복습입니다. 다음 순서로 기초부터 다시 짚습니다.

1. 모델, 하네스, 도구의 세 층
2. 도구 사용(tool use)이 한 번 오가는 모습
3. 서버 도구와 클라이언트 도구의 차이
4. Bedrock에서 서버 도구가 빠지는 이유
5. MCP로 검색을 클라이언트 쪽에 다시 다는 방법

마지막에는 그때 실제로 한 결정과 주의할 점으로 돌아옵니다. 공식 문서 내용은 2026-11-05에 다시 확인했습니다. AWS 쪽 서비스 전체 그림은 앞의 글 [AWS로 AI 에이전트 만들기 전에 알아야 할 서비스 지도]({% post_url 2026-11-01-aws-ai-agent-services-map %})에 정리해 두었습니다.

## 세 층으로 나눕니다: 머리, 몸통과 신경, 손발

가장 먼저 바로잡을 오해는 "Claude Code = 모델"이라는 생각입니다. 둘은 한 화면에서 붙어 움직이니 그렇게 느끼기 쉽습니다. 하지만 실제로는 세 층이 따로 있습니다.

| 층 | 무엇 | 하는 일 | 비유 |
|---|---|---|---|
| 모델 | Claude (Anthropic API나 Bedrock에서 빌려 씀) | 대화를 읽고 다음 행동을 **글자로** 정합니다. "Bash로 이 명령을 실행하자" | 머리 |
| 하네스 | Claude Code (내 컴퓨터에서 실행) | 모델이 고른 도구를 실제로 실행하고 결과를 다시 모델에 보냅니다. 위험한 동작은 확인을 받고, 대화 기록과 설정을 관리합니다 | 몸통과 신경 |
| 도구 | `Bash`, `Read`, `WebFetch`, MCP 도구 … | 실제 동작 하나하나입니다 | 손발 |

**하네스(harness)**는 모델을 감싸서 실제로 일하게 만드는 프로그램을 가리키는 말입니다. 모델은 파일을 열 수도, 명령을 실행할 수도 없습니다. 입력을 받아 글자를 내놓을 뿐입니다. "이 파일을 읽겠다"는 결정도 결국 글자이고, 그 글자를 보고 진짜로 파일을 여는 쪽은 하네스입니다.

이렇게 나눠 보면 Claude Code를 Anthropic API에도, Bedrock에도 연결할 수 있는 이유가 보입니다. 하네스와 도구는 내 컴퓨터에 그대로 있고, 바뀌는 것은 **머리를 어디서 빌려 오느냐**뿐입니다. Claude Code에서는 `CLAUDE_CODE_USE_BEDROCK=1` 같은 설정으로 이 연결을 바꿉니다 ([Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock)).

그런데 머리를 바꿨더니 웹 검색이 사라졌습니다. 그렇다면 웹 검색은 손발 중 하나가 아니라 **머리 쪽에 붙어 있던 무언가**였다는 뜻입니다. 이것을 이해하려면 도구가 쓰이는 과정을 먼저 봐야 합니다.

## 도구 사용(tool use)은 한 번 오가는 대화입니다

Anthropic 문서는 도구 사용(tool use, function calling이라고도 합니다)을 이렇게 설명합니다. Claude는 요청과 도구 설명을 보고 도구를 부를지 정합니다. 그다음 구조화된 호출을 돌려주면, **내 애플리케이션이 실행하거나(클라이언트 도구) Anthropic이 실행합니다(서버 도구)** ([Tool use with Claude](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview)).

내가 정의한 도구라면 한 번의 왕복은 이렇습니다.

1. 요청에 도구 목록(이름, 설명, 입력 스키마)을 같이 보냅니다.
2. 모델이 도구가 필요하다고 판단하면 `stop_reason: "tool_use"`와 함께 `tool_use` 블록을 돌려줍니다. 블록에는 어느 도구를, 어떤 입력으로 부를지가 적혀 있습니다. **아직 아무것도 실행되지 않았습니다.**
3. 내 코드가 그 도구를 실행합니다.
4. 실행 결과를 `tool_result` 블록에 담아 다음 요청으로 보냅니다.
5. 모델이 결과를 읽고 답을 쓰거나, 다시 2번으로 돌아가 다른 도구를 부릅니다.

하네스가 하는 일은 사실상 이 반복문입니다. 개념만 남긴 의사코드로 쓰면 이렇습니다.

```python
messages = [{"role": "user", "content": "README.md 첫 줄을 알려 줘"}]

while True:
    # 모델 호출. Anthropic API든 Bedrock이든 이 줄만 다르다
    response = call_model(messages, tools=TOOLS)
    messages.append({"role": "assistant", "content": response.content})

    if response.stop_reason != "tool_use":
        break  # 도구가 더 필요 없으면 답이 나온 것

    results = []
    for block in response.content:
        if block.type == "tool_use":
            check_permission(block)                       # 하네스가 실행 전에 확인
            output = run_locally(block.name, block.input)  # 실제 실행은 내 쪽에서
            results.append({"type": "tool_result",
                            "tool_use_id": block.id,
                            "content": output})
    messages.append({"role": "user", "content": results})
```

여기서 모델이 한 일은 `tool_use` 블록이라는 **글**을 쓴 것뿐입니다. 실행도, 권한 확인도, 결과 전달도 반복문 쪽이 맡습니다. 그래서 "모델은 부족한 정보를 알아서 검색해 오지 않나?"라는 질문의 답은 이렇습니다. **검색 도구가 목록에 있을 때만 검색을 요청할 수 있습니다.** 도구가 없으면 모델은 학습한 지식으로 답하거나 모른다고 말할 수밖에 없습니다.

## 서버 도구와 클라이언트 도구: "어디서 실행되느냐"로 나눈 이름

Anthropic 문서의 정의는 한 문장으로 시작합니다. "Tools differ primarily by where the code runs." 도구는 무엇을 하느냐보다 **코드가 어디서 실행되느냐**로 먼저 나뉩니다.

| | 클라이언트 도구 | 서버 도구 |
|---|---|---|
| 실행 위치 | 내 애플리케이션 (Claude Code라면 내 컴퓨터) | Anthropic 인프라 |
| 예 | 내가 정의한 도구, 그리고 `bash`, `text_editor`, memory, computer use처럼 Anthropic이 스키마를 정한 도구 | `web_search`, `web_fetch`, `code_execution`, `tool_search`, advisor, MCP connector |
| 응답에 오는 것 | `tool_use` 블록. 내가 실행하고 `tool_result`를 보냄 | `server_tool_use`와 결과 블록(예: `web_search_tool_result`)이 같은 응답 안에 함께 옴 |
| 결과를 모델에 넣는 쪽 | 나 (하네스) | Anthropic 서버 |
| 요금 | 일반 토큰 요금 | 토큰 요금 + 사용량 요금 (웹 검색은 1,000건당 $10) |

헷갈리기 쉬운 점이 하나 있습니다. `bash`나 `text_editor`는 Anthropic이 이름과 스키마를 정하고 모델도 그 형식으로 학습시켰습니다. 그래도 **실행은 내 애플리케이션이 하므로 클라이언트 도구**입니다. 누가 만들었느냐가 아니라 누가 실행하느냐가 기준입니다.

서버 도구는 요청에 한 줄만 넣으면 됩니다. 공식 문서의 기본 웹 검색 예시를 줄이면 이렇습니다 ([Web search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)).

```json
{
  "model": "<모델 ID>",
  "max_tokens": 1024,
  "tools": [{"type": "web_search_20250305", "name": "web_search", "max_uses": 3}],
  "messages": [{"role": "user", "content": "<최신 정보가 필요한 질문>"}]
}
```

`web_search_20250305`는 기본 검색이고, 결과를 코드로 걸러 주는 동적 필터링이 붙은 `web_search_20260209`, `web_search_20260318` 버전도 있습니다. 어느 버전이든 처리 방식은 같습니다. 문서의 표현대로 "The API runs the searches", 즉 검색은 API가 실행합니다. 응답 하나에 검색 결정, 검색어, 결과, 인용이 붙은 답이 모두 들어 있습니다.

```text
content:
  text                     "검색해 보겠습니다."
  server_tool_use          name=web_search, input={"query": "..."}
  web_search_tool_result   [url, title, page_age, encrypted_content ...]
  text (+ citations)       인용이 붙은 답
stop_reason: end_turn
```

내 코드는 검색을 실행하지도, `tool_result`를 만들지도 않았습니다. 앞의 비유로 말하면 서버 도구는 **머리 쪽에 따로 달린 손**입니다. 머리를 다른 곳에서 빌려 오면, 그 머리에 붙어 있던 손도 같이 바뀌거나 빠집니다.

Claude Code의 `WebSearch`는 이 점에서 조금 미묘합니다. 화면에서는 `Read`나 `Bash`와 나란히 Claude Code 도구 목록에 있습니다. 그런데 [Tools reference](https://code.claude.com/docs/en/tools-reference)에 따르면 이 도구는 **Anthropic의 웹 검색 백엔드**에 질의합니다. 그러니까 Claude Code의 WebSearch는 Anthropic 서버 도구에 기대는 도구라고 보는 것이 정확합니다. 반대로 `WebFetch`는 페이지를 내 컴퓨터에서 받아 Markdown으로 바꾸고, 별도 모델 호출로 필요한 내용을 추려 Claude에게 넘깁니다. 문서는 이 방식을 "lossy by design"이라고 적어 둡니다. 원문을 그대로 넘기는 것이 아니라 추린 결과만 넘긴다는 뜻입니다.

## Bedrock에서는 왜 빠지나: 공식 문서로 확인

그림 한 장으로 먼저 보겠습니다. 왼쪽이 Anthropic API에 연결했을 때, 오른쪽이 Bedrock에 연결하고 검색을 다시 달았을 때입니다.

<figure class="diagram">
{% include figures/server-tools-vs-client-tools/where-tools-run.svg %}
<figcaption>서버 도구는 모델 제공자 쪽에 붙어 있어 Bedrock에선 빠지고, 클라이언트 도구는 내 PC에 있어 그대로 남는다</figcaption>
</figure>

이것은 추측이 아니라 문서에 적혀 있는 내용입니다.

- **Anthropic의 [Claude in Amazon Bedrock](https://platform.claude.com/docs/en/build-with-claude/claude-in-amazon-bedrock) 문서**의 "Features not supported" 목록에 "Server-side tools (code execution, web search, web fetch, advisor)"와 "Agent infrastructure (Agent Skills, MCP connector, programmatic tool calling)"가 들어 있습니다. 반대로 지원 목록에는 tool use가 있습니다. Bash, browser use, computer use, memory, text editor 도구도 포함됩니다. 모두 **클라이언트 쪽에서 실행되는 도구**입니다.
- **Claude Code의 Bedrock 설정 문서**: "The WebSearch tool is not available on Amazon Bedrock."
- **Claude Code의 Tools reference**: "Amazon Bedrock doesn't expose the server-side web search tool." 같은 절에 대안도 적혀 있습니다. 검색 백엔드는 설정으로 바꿀 수 없고, 다른 제공자로 검색하려면 검색 도구를 노출하는 MCP 서버를 추가하라고 합니다.

정리하면 Bedrock이 주는 것은 **모델 추론**입니다. Anthropic 인프라에서 돌던 서버 도구는 그 범위 밖입니다. 그때 세션에서 쓰던 `Bash`, `Read`, `WebFetch`, MCP 도구는 모두 클라이언트 도구였기 때문에, 머리를 Bedrock으로 바꿔도 그대로 동작했습니다.

"AWS에서 쓰면 안 된다"로 기억하면 틀립니다. 웹 검색 문서의 지원 플랫폼 목록에는 **Claude Platform on AWS**가 들어 있고 Amazon Bedrock은 없습니다. Claude Platform on AWS는 결제만 AWS Marketplace로 하고 운영은 Anthropic이 하는 경로입니다. 기준은 결제 창구가 아니라 **누가 모델 옆의 인프라를 운영하느냐**입니다.

## MCP: 클라이언트 쪽에 손을 새로 다는 표준

빠진 손을 다시 달려면, 그 손을 머리 쪽이 아니라 몸 쪽(클라이언트)에 붙이면 됩니다. Claude Code 문서도 그 방법으로 MCP를 안내합니다.

**MCP(Model Context Protocol)**는 도구를 제공하는 프로그램(MCP 서버)과 그 도구를 쓰는 애플리케이션(MCP 클라이언트) 사이의 표준 규약입니다. 클라이언트는 `tools/list`로 도구 목록을 받고 `tools/call`로 도구를 부릅니다. Claude Code는 MCP 클라이언트이기도 해서, 서버를 등록하면 그 서버의 도구가 모델에게 보이는 도구 목록에 들어갑니다. 모델이 그 도구를 고르면 Claude Code가 서버에 호출을 전달하고, 받은 결과를 `tool_result`로 모델에게 넣습니다. **MCP 도구는 클라이언트 도구**입니다.

Claude Code가 MCP 서버에 붙는 방식은 크게 둘입니다 ([Claude Code MCP 문서](https://code.claude.com/docs/en/mcp)).

| 방식 | 서버가 있는 곳 | 특징 |
|---|---|---|
| stdio | 내 컴퓨터의 로컬 프로세스 | Claude Code가 프로세스를 띄우고 표준 입출력으로 주고받습니다. 내 자격 증명과 파일에 바로 접근할 수 있습니다 |
| HTTP | 원격 서버 | URL로 붙습니다. 원격 서비스용으로 문서가 권장하는 방식입니다 |

등록할 때는 범위(scope)도 고릅니다. `local`(기본, 이 프로젝트에서 나만), `project`(`.mcp.json`으로 팀과 공유), `user`(내 모든 프로젝트)입니다. 검색처럼 어디서나 쓰는 도구는 `user`가 맞습니다. stdio 서버는 이런 형태로 등록합니다. `--` 뒤에는 서버를 실행하는 명령이 그대로 들어갑니다.

```sh
claude mcp add --scope user --env AWS_PROFILE=<프로필 이름> web-search -- <python 실행 파일> <서버 스크립트 경로>
```

"클라이언트 도구는 자동으로 설치된 건가, 내가 깐 건가?"라는 질문도 여기서 풀립니다. 그때 세션의 도구는 세 갈래였습니다.

- **기본 도구**(`Bash`, `Read`, `Edit`, `WebFetch` 등): Claude Code에 들어 있어서 설치할 때 같이 옵니다.
- **MCP 서버의 도구**: 누군가 등록한 것입니다. 직접 `claude mcp add`를 했을 수도 있고, 다른 프로그램이 설치되면서 등록했을 수도 있습니다. 기억에 없는 도구가 보이면 `claude mcp list`나 Claude Code 안의 `/mcp`로 어떤 서버가 붙어 있는지 확인하면 됩니다.
- **스킬**: 새 도구가 아니라 일하는 방법을 적은 문서입니다. 문서에도 스킬은 새 도구 항목을 추가하지 않고 기존 `Skill` 도구를 거쳐 실행된다고 적혀 있습니다. 실제 일은 기본 도구가 합니다.

## 다시 만든 웹 검색의 구조

그때 고른 구조는 그림의 오른쪽과 같습니다.

1. 내 Mac에서 작은 Python MCP 서버가 stdio로 돕니다. 이 서버가 `web_search` 도구를 노출합니다.
2. 모델이 `web_search`를 고르면 Claude Code가 이 서버를 부릅니다. 모델이 보기에는 `Read`나 `Bash`와 다를 것 없는 클라이언트 도구입니다. 그래서 머리를 Bedrock에서 빌려도 동작합니다.
3. 서버는 AWS 도쿄 리전의 **AgentCore Gateway**를 HTTPS로 부릅니다. 요청에는 **SigV4** 서명을 붙입니다.
4. Gateway는 AWS가 운영하는 **Web Search 커넥터**로 검색을 넘깁니다.

처음 나온 말 몇 개를 정리합니다.

- **AgentCore Gateway**: Lambda, API, 기존 MCP 서버 같은 여러 도구를 MCP 엔드포인트 하나로 묶어 열어 주는 Amazon Bedrock AgentCore 서비스입니다. AgentCore의 다른 구성 요소와의 관계는 [서비스 지도 글]({% post_url 2026-11-01-aws-ai-agent-services-map %})에 정리했습니다.
- **커넥터**: Gateway에 대상(target)으로 붙이는, AWS가 미리 만들어 둔 도구입니다. Web Search는 `connectorId: "web-search"`로 붙입니다.
- **SigV4**: AWS 자격 증명으로 요청마다 서명을 만들어 보내는 인증 방식입니다. 비밀키 자체는 보내지 않습니다. 자세한 비교는 [인증 기초: JWT, IAM, Cognito]({% post_url 2026-11-01-auth-basics-jwt-iam-cognito %})에 썼습니다.

이 구조에서 검색 자체는 AWS 서버에서 일어납니다. 그래도 이 `web_search`는 서버 도구가 아니라 클라이언트 도구입니다. **누가 호출하고 결과를 모델에 넣어 주느냐**가 기준이기 때문입니다. 원격 서비스를 부르느냐는 기준이 아닙니다. 호출은 Claude Code가 하고, 결과도 Claude Code가 `tool_result`로 넣습니다.

[AWS 문서](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-connector-web-search-tool.html)로 확인한 커넥터의 성질은 이렇습니다.

| 항목 | 내용 |
|---|---|
| 정체 | MCP 호환 관리형 커넥터. Amazon이 직접 만들고 운영하는 웹 인덱스를 씁니다 |
| 검색어가 가는 곳 | AWS 안에서만 처리되고, 외부 검색 엔진으로 가지 않는다고 적혀 있습니다 |
| 입력 | `query` 200자 이하, `maxResults` 1~25 (기본 10), 도메인·게시일 필터 |
| 리전 | 미국, 아일랜드, 시드니, 도쿄, GovCloud. **서울은 없습니다** |
| 이용 조건 | 결과를 쓴 출력에는 출처 인용과 링크를 남겨야 하고, 결과를 대량으로 추출·저장할 수 없습니다 |
| 요금 ([AgentCore 요금](https://aws.amazon.com/bedrock/agentcore/pricing/)) | 검색 1,000건당 $7, Gateway 호출 1,000건당 $0.005 |

두 가지를 이렇게 정했습니다.

- **리전은 도쿄**: 서울에 커넥터가 없고, 아시아에서는 도쿄가 가장 가까운 지원 리전이었습니다. 도쿄로 가는 것은 검색어뿐이고, 모델 호출은 원래 쓰던 리전에 그대로 둡니다.
- **인증은 IAM(SigV4)**: 에이전트가 이미 쓰던 AWS 자격 증명을 그대로 쓸 수 있어서 토큰 발급과 갱신이 필요 없습니다. claude.ai에 커스텀 커넥터로 붙일 때는 JWT 인증이 필요하다고 AWS 문서에 적혀 있습니다. 그래서 JWT는 로그인 기반 서비스로 넓힐 때를 위해 미뤘습니다.

이 구조의 로컬 MCP 서버를 아주 짧게 줄이면 다음과 같습니다. 공식 Python SDK의 `FastMCP`를 쓴 예시이고, 원격 검색 부분은 `search_backend`로 비워 두었습니다.

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("web-search")

@mcp.tool()
def web_search(query: str, max_results: int = 5) -> str:
    """웹을 검색합니다. 답의 근거로 쓴 결과는 반드시 URL을 함께 인용하세요."""
    hits = search_backend(query[:200], max_results)  # Gateway 호출 (SigV4 서명은 여기서)
    return "\n".join(
        f"[{i}] {h['title']}\n{h['url']}\n{h['text'][:300]}"
        for i, h in enumerate(hits, 1)
    )

if __name__ == "__main__":
    mcp.run()  # 기본 전송 방식은 stdio
```

함수의 docstring은 모델이 보는 **도구 설명**이 됩니다. 인용을 강제하는 문장을 여기에 넣은 것은 커넥터 이용 조건 때문이기도 합니다. 실제로 만든 도구에는 이 밖에 다음 장치를 더했습니다.

- **출력 압축**: 결과 5건의 원본 JSON은 6천~1만2천 자였습니다. 이것을 번호 붙인 짧은 형식으로 바꿔 평균 약 3천 자로 줄였습니다. 검색 요금보다 모델 입력 토큰 비용이 더 커질 수 있어서 기본 결과 수도 5로 정했습니다.
- **메모리 캐시만**: 10분 동안만 메모리에 두고 디스크에는 저장하지 않습니다. 대량 저장 금지 조건 때문입니다. `fresh=true`를 주면 캐시를 건너뜁니다.
- **시간 상한**: 호출 전체 12초, 원격 시도 한 번 6초입니다.
- **오류 분류**: 401, 403, 404, 429, 5xx, MCP 오류를 나누고, 인증 오류는 재시도하지 않습니다.
- **분당 30건 상한**과, 검색어는 해시로만 남기는 **측정 로그**(지연 시간, 시도 수, 재시도 수, 결과 수, 추정 비용)를 두었습니다.

그때 잰 값은 이랬습니다. **작은 표본으로 그 시점에 한 번 잰 값**이라 일반적인 성능으로 읽으면 안 됩니다.

- 웜 상태 지연 p50 0.48초, p95 0.60초. 40건에서 오류와 재시도는 0건이었습니다.
- 검색 1건 비용은 공개 요금 기준 약 $0.007입니다. Gateway 호출료는 무시할 만한 수준입니다.
- 영어 질문 20개는 자동 판정으로 20/20이었습니다. 자동 판정의 한계는 뒤에서 다룹니다.
- 한국어 질문 10개를 한국어로 검색하니 사람이 읽고 판정했을 때 7/10, 같은 질문을 영어 질의로 바꾸니 10/10이었습니다. 표본이 10문항이고 실행할 때마다 결과가 바뀝니다. 그래서 "영어가 더 정확하다"는 법칙으로 쓰지 않았습니다. 도구 설명에만 이렇게 적었습니다. "한국어 질문도 뜻을 옮겨 먼저 영어로 검색하고, 국내 전용 정보이거나 결과가 부족하면 한국어로도 검색한다."
- 국내에서만 나오는 공지(예: 지하철 운행 공지)는 찾지 못했습니다. 이때 모델은 지어내지 않고 찾지 못했다고 답했습니다.

## 그때 한 일과 주의할 점

서버 도구를 쓸 때는 Anthropic이 맡아 주던 일이 있습니다. 클라이언트 도구로 다시 만들면 그 일이 전부 내 몫이 됩니다. 만든 뒤 독립 검증을 돌렸을 때 걸린 결함들이 바로 그 자리에 있었습니다.

### 1. 상한은 도구 호출이 아니라 원격 요청 단위로 셉니다

가장 무거운 결함이었습니다. 분당 30건 상한을 **도구 호출마다 한 번** 확인했더니, 재시도까지 합쳐 실제 원격 요청은 분당 60건까지 나갈 수 있었습니다. 비용을 막으려고 둔 상한이 비용을 막지 못한 것입니다. 개념만 남겨 다시 쓰면 차이는 확인하는 위치 하나입니다.

```python
import time
from collections import deque

class AttemptBudget:
    """최근 60초 동안 실제로 보낸 원격 요청 수를 센다."""
    def __init__(self, per_minute: int):
        self.per_minute = per_minute
        self.sent = deque()

    def take(self) -> bool:
        now = time.monotonic()
        while self.sent and now - self.sent[0] >= 60:
            self.sent.popleft()
        if len(self.sent) >= self.per_minute:
            return False
        self.sent.append(now)
        return True

budget = AttemptBudget(per_minute=30)
MAX_ATTEMPTS = 2  # 첫 시도 + 재시도 1회
```

```python
# 틀린 예: 도구 호출 한 번에 한 번만 센다
def search_wrong(query):
    if not budget.take():
        raise RateLimited()
    last_error = None
    for _ in range(MAX_ATTEMPTS):      # 그런데 원격 요청은 최대 2번 나간다
        try:
            return send_request(query)
        except RetryableError as e:
            last_error = e
    raise last_error
```

```python
# 맞는 예: 원격 요청을 보내기 직전마다 센다
def search_right(query):
    last_error = None
    for _ in range(MAX_ATTEMPTS):
        if not budget.take():          # 예산이 없으면 재시도하지 않고 멈춘다
            raise RateLimited("분당 상한에 걸려 재시도하지 않습니다")
        try:
            return send_request(query)
        except RetryableError as e:
            last_error = e
    raise last_error
```

### 2. 재시도는 비용을 두 배로 만들 수 있습니다

같은 뿌리의 결함이 벤치마크 스크립트에도 있었습니다. "질의 1건만"으로 제한했는데, 그 제한이 재시도를 세지 않아서 실제로는 2건이 나갔습니다. 도구와 같은 예산 장치를 쓰도록 바꿔 재시도까지 세게 했습니다. 돈이 드는 호출이라면 **"몇 번 호출했나"가 아니라 "몇 번 보냈나"**를 세야 합니다.

### 3. 마감 시간은 호출이 시작될 때부터 잽니다

12초 상한의 시계가 자격 증명을 읽은 **뒤에** 시작되고 있었습니다. 그래서 로딩이 느리면 전체가 13초를 넘겼습니다. 로딩이 동기 방식이라 그동안 이벤트 루프도 멈췄습니다. 고친 뒤 다시 검증하니, 재시도 전에 세션을 정리하는 시간과 backoff 대기도 마감 밖에 있었습니다. 최종적으로는 자격 증명 로딩, 시도, 세션 정리, 대기, lock 대기를 모두 **마감 하나**로 묶었습니다.

### 4. 캐시는 늦게 도착한 옛 결과에 덮어써질 수 있습니다

`fresh`로 다시 검색하는 동안 먼저 보낸 요청이 늦게 끝나면, 그 옛 결과가 새 결과를 캐시에서 덮어썼습니다. 요청마다 순번을 붙여, 더 늦게 시작한 요청의 결과만 캐시에 남도록 고쳤습니다.

### 5. 자동 채점은 틀립니다

정답 문자열이 결과에 있는지로 채점하는 스크립트를 썼는데, 사람이 다시 읽어 보니 오판이 있었습니다. 맞다고 본 수치는 다른 해의 다른 수치였습니다. 선거 전 기사에 후보로만 나온 이름도 정답으로 셌습니다. 검색 품질을 잴 때 표본은 **사람이 직접 읽어야** 합니다. 앞의 영어 질문 20/20도 자동 판정이라 이런 한계를 안고 있습니다.

### 6. 이미 열린 세션은 옛 도구 설명을 볼 수 있습니다

도구 설명을 고친 뒤 확인해 보니, 이미 열려 있던 세션은 여전히 **바뀌기 전 설명**으로 도구를 쓰고 있었습니다. 세션이 시작될 때 띄운 stdio 서버 프로세스가 옛 코드 그대로 돌고 있었기 때문입니다. `/mcp`에서 다시 연결하거나 새 세션을 열어야 반영됐습니다.

공식 문서에는 서버가 `list_changed` 알림을 보내면 대화형 세션에서 도구 목록을 자동으로 다시 받는다고 적혀 있습니다. 그러니 정확히 말하면 이렇습니다. **알림을 보내지 않는 서버라면** 도구를 고친 뒤 재연결이 필요합니다. 그때 만든 서버가 그런 경우였습니다.

### 7. 대체하면 잃는 것과 얻는 것

| 서버 도구를 쓸 때 Anthropic이 맡던 것 | 클라이언트 도구로 다시 만들면 |
|---|---|
| 검색 실행, 결과 형식, 인용 | 직접 정하고, 도구 설명으로 인용을 강제해야 합니다 |
| 사용량 제한, 재시도, 오류 표현 | 상한, 재시도, 마감, 오류 분류를 직접 만들어야 합니다 |
| 결과 처리 | 캐시와 그 이용 조건을 직접 지켜야 합니다 |

얻는 것도 있습니다. 검색어가 AWS 밖으로 나가지 않습니다. 비용이 같은 AWS 청구서에 나옵니다. 백엔드를 고를 수 있습니다. 그래서 도구 안쪽은 백엔드를 갈아 끼울 수 있게 나눠 두었습니다. 그리고 같은 질문 묶음으로 다른 검색 서비스와 비교할 벤치마크를 남겼습니다.

### 버린 안

| 안 | 버린(미룬) 이유 |
|---|---|
| 검색 결과 페이지를 WebFetch로 직접 읽기 | 봇 차단(엉뚱한 결과, 429, captcha). 주소를 아는 페이지 읽기에만 씁니다 |
| 실제 브라우저로 사람처럼 검색 | 느리고 captcha 위험이 있습니다. 비용이 들지 않아 비상용으로만 남겼습니다 |
| 범용 SigV4 MCP 프록시로 Gateway에 바로 연결 | 코드 없이 붙지만 원본 JSON이 그대로 모델에 들어가 토큰이 많이 들고, 캐시와 측정이 없습니다. 연결 확인용으로만 썼습니다 |
| 외부 검색 API(Tavily, Brave, Exa 등) | API 키와 별도 계약이 필요하고 검색어가 AWS 밖으로 나갑니다. 같은 벤치로 비교할 후보로 남겼습니다 |
| JWT 인증 Gateway | claude.ai 커넥터나 로그인 서비스에 필요합니다. 지금은 한 사람이 로컬에서만 써서 IAM이 더 간단했습니다 |
| 같은 계정에 있던 다른 팀의 Gateway 재사용 | 다른 서비스의 인프라라 건드리지 않았습니다. Gateway는 고정비가 없어 새로 만들었습니다 |

### 남은 일

세션 만료, 권한 오류, 요청 한도 초과 같은 실제 AWS 오류는 가짜 서버로만 시험했습니다. 국내에서만 나오는 정보는 한국어에 강한 다른 백엔드가 필요할 수 있습니다.

## 정리

| 질문 | 답 |
|---|---|
| Claude Code는 모델인가? | 아닙니다. 모델(머리)은 빌려 오고, Claude Code는 도구를 실행하고 결과를 돌려주는 하네스(몸통과 신경)입니다 |
| 서버 도구와 클라이언트 도구는 무엇으로 나뉘나? | 도구 종류가 아니라 **실행 위치**입니다. 결과를 누가 모델에 넣어 주느냐를 보면 됩니다 |
| `bash`, `text_editor`는? | Anthropic이 스키마를 정했지만 내 쪽에서 실행하므로 클라이언트 도구입니다 |
| Bedrock에서 웹 검색이 빠지는 이유는? | 웹 검색은 Anthropic 인프라에서 도는 서버 도구이고, Bedrock은 서버 도구를 지원하지 않기 때문입니다 (공식 문서 명시) |
| 다시 다는 방법은? | 검색 도구를 노출하는 MCP 서버를 클라이언트 쪽에 붙입니다. 실제 검색이 원격이어도 클라이언트 도구입니다 |

다른 클라우드나 다른 하네스에서 "이 기능만 안 된다"를 만나면 이 순서로 확인하면 됩니다.

| 단계 | 확인할 것 |
|---|---|
| 1 | 이 기능은 서버 도구인가? (제공자 인프라에서 실행되는가) |
| 2 | 그렇다면 클라우드 경유로 모델을 빌릴 때 빠질 수 있다 |
| 3 | 그 플랫폼의 공식 기능 표("Features not supported" 같은 목록)를 확인한다 |
| 4 | 필요하면 MCP로 클라이언트 쪽에 다시 단다 |
| 5 | 상한·재시도·마감·캐시·인용을 이제 내가 책임진다 |
