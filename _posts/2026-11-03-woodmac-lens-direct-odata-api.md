---
title: "Wood Mackenzie Lens Direct API 시작하기: OData로 에너지 데이터 가져오기 (키 발급부터 302 함정까지)"
date: 2026-11-03 15:00:00 +0900
categories: [개발 도구, API]
tags: [woodmac, lens-direct, odata, rest-api, curl, python, api-key]
description: "Wood Mackenzie Lens Direct의 OData API로 데이터를 코드로 가져오는 법을 정리합니다. API 키 발급과 보관, Basic 인증, 302 리디렉트 때문에 데이터 JSON을 받지 못하는 문제, 403만으로 권한을 판단하면 안 되는 이유, 키가 대화 기록에 남았던 실수까지 다룹니다."
---

Wood Mackenzie(이하 WoodMac)의 Lens는 에너지·자원 시장 데이터를 웹 화면으로 보여 주는 서비스입니다. 회사 구독 계정으로 화면에서 표를 보고 엑셀로 내려받아 쓰다 보면, 같은 데이터를 스크립트나 LLM 에이전트의 도구로 바로 가져오고 싶어집니다. 그 통로가 **Lens Direct**이고, 그중 행 단위로 질의할 수 있는 것이 **OData API**입니다.

처음 붙여 볼 때 세 번 막혔습니다.

1. 인증은 통과했는데 **데이터 조회에서 기대한 JSON이 오지 않았습니다.** 원인은 302 리디렉트였습니다.
2. 짐작해 넣은 데이터셋 이름에 **403**이 나와서 "구독이 없나 보다"라고 판단했습니다. 그런데 일부러 틀린 이름을 넣어도 403이었습니다.
3. 키를 테스트하다가 **API 키가 AI 코딩 도구의 대화 기록에 그대로 남았습니다.** 결국 키를 다시 발급해야 했습니다.

이 글은 키 발급부터 첫 조회까지의 순서를 정리하고, 위 세 가지를 피하는 방법을 함께 적습니다. 예시의 데이터셋·테이블 이름과 응답 값은 모두 설명용으로 지어낸 값입니다. 키 파일을 두는 폴더 이름 `woodmac-lens-direct`도 예시이니 원하는 이름으로 바꿔 쓰세요.

## Lens Direct로 데이터를 받는 세 가지 방법

WoodMac 지원 문서([How to access data using Lens Direct using OData](https://support.woodmac.com/en/articles/6844483-how-to-access-data-using-lens-direct-using-odata))는 Lens Direct의 방법을 세 가지로 나눕니다.

| 방법 | 지원 문서의 설명 | 언제 쓰나 |
|---|---|---|
| **OData API** | 새로 고칠 수 있는 직접 연결 | 테이블 몇 개, 작은 데이터를 필요할 때마다 다시 받을 때 |
| **Bulk API** | 코드나 ETL로 대량 추출 | 데이터 웨어하우스에 통째로 적재할 때 |
| **Static Download** | 한 번 내려받는 파일 | OData를 지원하지 않는 도구에 넣을 때 |

이 글은 OData API만 다룹니다. Bulk API는 이번에 써 보지 않았습니다. 지원 문서에 따르면 Bulk API는 별도 가이드와 예제 코드가 있으니 대량 추출이 필요하면 그쪽을 보세요.

Lens 화면에서 OData 링크를 받아 Excel이나 Power BI(Power Query)에 붙이는 방법은 지원 문서에 화면과 함께 나와 있습니다. 여기서는 같은 API를 `curl`과 Python으로 직접 부릅니다.

## 1. API 키 발급

키는 담당자를 거치지 않고 계정 화면에서 직접 만듭니다.

1. my.woodmac.com에 로그인합니다.
2. 오른쪽 위 사용자 이름 → **Account and preferences management**로 들어갑니다.
3. 왼쪽 메뉴의 **API keys**를 엽니다.
4. **Generate new API key**를 누르고 키를 복사합니다.

Lens Direct 화면에서 데이터를 내려받을 때 나오는 **Generate API Key** 링크도 같은 페이지로 갑니다.

두 가지를 알고 누르세요.

- **새로 발급하면 기존 키는 무효가 됩니다.** 이미 Excel이나 Power BI 연결에 옛 키를 넣어 두었다면 그 연결이 끊깁니다. 키를 "하나 더" 만드는 것이 아니라 "바꾸는" 버튼입니다.
- **키는 개인 계정에 묶입니다.** 여러 사람이 함께 쓰는 서비스나 에이전트에 개인 키를 넣어도 되는지는 회사의 WoodMac 계약 조건을 먼저 확인하는 편이 안전합니다.

## 2. 키는 복사한 즉시 파일이나 키체인에 둔다

키를 받으면 바로 터미널에 붙여 테스트하고 싶어지는데, 그 전에 둘 곳부터 정합니다. 제가 키를 노출한 것도 이 순서를 건너뛰어서였습니다 (뒤의 "키 노출" 절).

**방법 A: 권한 600 파일.** 폴더는 700, 파일은 600으로 만들고 키는 에디터로 직접 붙여 넣습니다.

```sh
mkdir -p "$HOME/.config/woodmac-lens-direct"
chmod 700 "$HOME/.config/woodmac-lens-direct"
printf '{\n  "apikey": ""\n}\n' > "$HOME/.config/woodmac-lens-direct/key.json"
chmod 600 "$HOME/.config/woodmac-lens-direct/key.json"
# 이제 에디터로 열어 "" 안에 키를 붙여 넣습니다.
```

명령에서는 파일 내용을 출력하지 않고 변수로만 꺼냅니다.

```sh
KEY=$(jq -r .apikey "$HOME/.config/woodmac-lens-direct/key.json")
```

**방법 B: macOS 키체인.** `-w`를 맨 끝에 값 없이 두면 비밀번호 입력 프롬프트가 나오므로, 키가 명령 기록에 남지 않습니다. `-U`는 같은 계정·서비스 이름의 항목이 이미 있으면 새 키로 갱신합니다. 키를 재발급한 뒤 같은 명령으로 다시 저장할 수 있게 넣어 둡니다.

```sh
# 저장 (프롬프트에 키를 붙여 넣음)
security add-generic-password -U -a "$USER" -s woodmac-lens-direct -w
# 꺼내 쓰기
KEY=$(security find-generic-password -a "$USER" -s woodmac-lens-direct -w)
```

## 3. 인증과 첫 호출: 서비스 루트

OData 엔드포인트는 이런 모양입니다.

```text
https://data.woodmac.com/qe/v1/odata/<dataset>/<table>
```

인증은 **HTTP Basic**입니다. 사용자 이름은 문자 그대로 `apikey`이고, 비밀번호 자리에 API 키를 넣습니다. 제 계정 키로 이 조합을 넣었을 때 HTTP 200이 왔습니다.

데이터셋 식별자를 알면 테이블 이름 뒤를 비우고 **서비스 루트**(`.../odata/<dataset>`)를 부릅니다. 그 데이터셋에 어떤 테이블이 있는지 목록이 옵니다. (데이터셋 식별자 자체를 찾는 방법은 6절에 있습니다.)

```sh
curl -s -u "apikey:$KEY" 'https://data.woodmac.com/qe/v1/odata/<dataset>' | jq .
```

OData v4 서비스 문서는 표준상 `value` 배열에 테이블(entity set)이 하나씩 들어 있으므로, 이름만 보려면 이렇게 줄일 수 있습니다. 응답 모양이 다르면 위의 `jq .`로 먼저 확인하세요.

```sh
curl -s -u "apikey:$KEY" 'https://data.woodmac.com/qe/v1/odata/<dataset>' | jq -r '.value[].name'
```

이 예시에서는 `-u "apikey:$KEY"`를 큰따옴표로 감싸 `$KEY`를 변수 값으로 확장하면서 하나의 인자로 넘깁니다. 반대로 URL은 작은따옴표로 감쌉니다 (4절의 `$top` 때문입니다).

## 4. 데이터 조회: 302를 따라가야 데이터가 온다

서비스 루트에서 확인한 테이블 이름을 붙여 데이터를 조회했습니다. 서비스 루트가 잘 됐으니 같은 명령에 테이블 이름만 붙이면 될 줄 알았는데, 기대한 데이터 JSON이 오지 않았습니다.

상태 코드를 찍어 보면 원인이 보입니다.

```sh
curl -s -g -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -u "apikey:$KEY" 'https://data.woodmac.com/qe/v1/odata/<dataset>/<table>?$top=1'
```

```text
302 https://data.woodmac.com/qe/cdn/data/non-cached/<해시>.json
```

제가 확인한 데이터 조회는 결과 대신 **HTTP 302**와 결과 JSON의 위치(같은 호스트의 CDN 경로 `/qe/cdn/data/non-cached/<해시>.json`)를 돌려줬습니다. `curl`은 기본으로 리디렉트를 따라가지 않으므로 302 응답에서 멈추고, 데이터 JSON을 받지 못합니다. **`-L`을 붙이면** 그 위치로 후속 요청을 보내 데이터 JSON을 받습니다.

<figure class="diagram">
{% include figures/woodmac-lens-direct-odata-api/redirect-flow.svg %}
<figcaption>이 조회에서는 302가 결과 JSON의 위치를 알려 주었고, curl&nbsp;-L로 그 위치까지 요청해야 데이터를 받았다</figcaption>
</figure>

이 예시의 리디렉트는 같은 HTTPS 호스트와 포트 안에서 일어나므로 `curl -L`이 Basic 인증을 유지합니다. 다른 호스트로 이동하면 `curl`은 기본으로 원래 인증 정보를 보내지 않습니다.

정리하면 조회 명령은 이렇게 됩니다.

```sh
KEY=$(jq -r .apikey "$HOME/.config/woodmac-lens-direct/key.json")

# 1행만 받고, 전체 행 수도 함께 (빈 결과면 columns는 빈 배열)
curl -s -g -L -u "apikey:$KEY" \
  'https://data.woodmac.com/qe/v1/odata/<dataset>/<table>?$top=1&$count=true' \
  | jq '{count: ."@odata.count", columns: ((.value[0] // {}) | keys)}'
```

```json
{
  "count": 1234,
  "columns": ["column_a", "column_b", "id"]
}
```

(값은 예시입니다.) 이 jq는 `value` 배열이 없는 응답도 `columns`를 빈 배열로 보여 주므로, `count`가 `null`로 나오면 정상적인 빈 결과가 아니라 오류 응답일 수 있습니다. 그때는 `jq .`로 원문을 확인하세요.

옵션을 하나씩 보면 이렇습니다.

| 옵션 | 하는 일 |
|---|---|
| `$top=N` | 앞에서 N행만 받습니다. 처음 볼 때는 1~5행이면 충분합니다 |
| `$count=true` | 전체 행 수를 응답의 `@odata.count`에 담아 줍니다 |
| URL을 작은따옴표로 | `$top`, `$count`를 그대로 보존합니다. 큰따옴표 안에서는 셸 변수로 확장되어 URL이 달라지거나 오류가 날 수 있습니다 |
| `curl -g` | URL 속 `[]`, `{}`를 curl이 범위 표현(globbing)으로 해석하지 않게 합니다 |
| `curl -L` | 리디렉트가 있는 응답에서 후속 URL까지 요청합니다. 제가 확인한 데이터 조회는 이것이 있어야 데이터를 받았습니다 |

`jq`로 **행 수와 열 이름만** 보는 습관을 들이면 좋습니다. Lens 데이터는 유료 콘텐츠라 터미널이나 AI 도구의 대화 기록에 값을 통째로 남길 이유가 없고, 처음 살필 때는 구조만 알면 충분합니다.

## 5. Python으로: requests는 기본으로 따라간다

Python `requests`의 `get()`은 기본으로 리디렉트를 따라갑니다. 그래서 같은 요청을 Python으로 보내면 302를 의식하지 못한 채 잘 됩니다. 반대로 `allow_redirects=False`를 주면 첫 302 응답이 그대로 반환되므로, 데이터 대신 상태 코드와 `Location` 헤더를 직접 확인해 처리해야 합니다. 리디렉트를 따라가지 않는 다른 HTTP 클라이언트도 마찬가지입니다.

```python
import json
from pathlib import Path

import requests

KEY = json.loads(
    Path("~/.config/woodmac-lens-direct/key.json").expanduser().read_text()
)["apikey"]
BASE = "https://data.woodmac.com/qe/v1/odata"


def odata_get(dataset: str, table: str, query: str = "") -> dict:
    url = f"{BASE}/{dataset}/{table}" + (f"?{query}" if query else "")
    r = requests.get(url, auth=("apikey", KEY), timeout=60)  # 리디렉트는 기본으로 따라감
    r.raise_for_status()
    for hop in r.history:  # 거쳐 간 302가 여기 남는다
        print(hop.status_code, "->", hop.headers.get("Location"))
    return r.json()


data = odata_get("<dataset>", "<table>", "$top=1&$count=true")
print(data.get("@odata.count"), sorted(data["value"][0].keys()) if data["value"] else [])
```

몇 가지 덧붙입니다.

- 쿼리를 `params={"$top": 1}`로 넘기면 `requests`가 `$`를 `%24`로 인코딩합니다. OData 규격상으로는 `%24top`도 같은 뜻이지만 Lens Direct에서는 확인하지 않았으므로, 예시에서는 URL 문자열에 그대로 붙였습니다.
- `requests`도 리디렉트가 다른 호스트로 가면 `Authorization` 헤더를 떼어냅니다. 이 예시는 같은 HTTPS 호스트·포트 안의 리디렉트라 문제가 없었습니다.
- 지원 문서 하단에는 pandas로 조회하는 Jupyter 노트북 예제 파일도 있습니다.

## 6. 403만 보고 "구독이 없다"고 단정하지 않기

데이터셋 이름은 URL에 들어가는 영어 식별자라, 화면에 보이는 이름에서 짐작해 넣기 쉽습니다. 저도 그렇게 몇 개를 넣어 보다가 403이 나오자 "이 데이터는 구독에 없나 보다"라고 정리하려 했습니다.

확인 삼아 **존재할 리 없는 이름을 일부러** 넣어 봤더니, 그것도 403이었습니다.

<figure class="diagram">
{% include figures/woodmac-lens-direct-odata-api/forbidden-ambiguity.svg %}
<figcaption>추측한 이름과 일부러 틀린 이름이 모두 403이어서, 이 응답만으로는 구독 범위를 판단할 수 없었다</figcaption>
</figure>

짐작한 이름이 실제로 있는 데이터셋인지, 있다면 구독 범위 밖인지는 이 응답으로 알 수 없습니다. 403은 "이 이름으로는 못 받는다"는 것만 알려 줄 뿐, **"구독이 없다"의 증거가 되지 못합니다.**

그래서 이름은 추측하지 말고 확인된 곳에서 가져옵니다. 데이터셋과 테이블은 확인하는 곳이 다릅니다.

- **데이터셋 식별자: 화면의 OData 링크에서.** Lens Direct 화면에서 테이블을 열고 OData 연결 링크를 복사하면, URL의 `/odata/` 뒤에 그 데이터셋의 식별자가 들어 있습니다. 왼쪽 탐색 창(Navigator Pane)은 어떤 데이터베이스·폴더·테이블이 있는지 둘러보는 데 씁니다. 지원 문서도 구독에 따라 쓸 수 있는 범위가 다르다고 적고 있으니, 화면에서 실제로 열리는 데이터셋을 기준으로 삼습니다.
- **테이블 이름: 그 데이터셋의 서비스 루트에서.** 데이터셋 식별자를 얻었으면 3절의 서비스 루트로 테이블 목록을 받아 정확한 테이블 이름을 확인합니다. 서비스 루트도 URL에 데이터셋 식별자가 필요하므로, 데이터셋 이름이 틀렸을 때의 해결책은 아닙니다.

"구독 범위가 어디까지인가"는 403을 세어서 추정하기보다 화면 목록과 계약 담당자에게 확인하는 것이 맞습니다.

## 7. 키 노출: AI 코딩 도구에 키를 붙여 넣었던 실수

이 글에서 가장 아까운 실수입니다. Claude Code 같은 AI 코딩 도구에는 `!`로 셸 명령을 바로 실행하는 입력이 있습니다. 키 테스트용으로 안내받은 명령은 `read -s`로 키를 숨겨 입력받은 뒤 `$KEY`로 쓰는 형태였는데, 저는 `$KEY`의 `KEY` 자리에 키를 직접 붙여 넣어 실행했습니다.

아래는 실제로 입력한 명령의 구조입니다. 실제 노출은 `<키를 붙여 넣은 자리>`에 진짜 키가 들어간 입력에서 일어났습니다.

```sh
# 이렇게 하지 마세요 (키는 지움)
! read -s KEY && curl -s -u "apikey:$<키를 붙여 넣은 자리>" 'https://data.woodmac.com/qe/v1/odata/<dataset>'
```

결과는 이랬습니다.

- **`read -s`가 실패했고 요청은 나가지 않았습니다.** 당시 실행 환경(`!` 명령)에서는 `read`가 입력을 받지 못해 바로 실패했고, `&&` 뒤의 `curl`은 실행되지 않았습니다.
- **그래도 키는 대화 기록에 남았습니다.** 키를 명령 문자열에 직접 붙여 넣었기 때문에, 실행 여부와 상관없이 그 문자열이 대화 기록과 로컬 로그 파일에 저장됐습니다.
- **실행됐더라도 키는 틀렸을 것입니다.** 큰따옴표 안에서 `$` 뒤에 붙은 글자는 셸 변수나 매개변수로 해석될 수 있어서, 붙여 넣은 키가 원래 문자열과 달라집니다.

조치는 **키 재발급**이었습니다. 1절에서 말했듯 새로 발급하면 노출된 키는 자동으로 무효가 됩니다. 그다음 2절의 방법으로 새 키를 파일에 두고, 명령에서는 `$(jq -r .apikey "$HOME/.config/woodmac-lens-direct/key.json")`로만 참조하게 바꿨습니다.

AI 도구와 함께 쓸 때 지키는 규칙은 이렇습니다.

- 키는 대화창이나 `!` 명령에 붙여 넣지 않습니다. 키 파일·키체인 저장은 **별도 터미널 앱이나 에디터**에서 직접 합니다.
- 키는 인증 요청을 만드는 로컬 프로세스 안에서만 읽게 하고, 키 내용이나 확장된 인증 인자를 도구 출력·대화·디버그 로그로 보내지 않게 AI 도구에 지시합니다. `cat key.json`, `echo $KEY`, `curl -v`처럼 키가 화면에 찍히는 확인 명령도 하지 않게 합니다.
- 결과도 필요한 만큼만 출력하게 합니다 (행 수와 열 이름, 임시 파일은 바로 삭제).
- 노출됐다고 생각되면 망설이지 말고 재발급합니다.

## 8. 에이전트 도구로 감쌀 때

OData는 URL 하나로 "어떤 데이터셋의 어떤 테이블을 몇 행"까지 지정할 수 있어서, 테이블의 지원 쿼리 옵션을 확인하면 LLM 에이전트의 조회 도구로 감싸기 좋습니다. 이 글에서 확인한 범위(`$top`, `$count=true`)라면 "이 테이블의 구조와 행 수를 보여 줘" 같은 도구를 바로 만들 수 있습니다. 조건별 개수처럼 필터가 필요한 조회는 해당 테이블에서 `$filter`와 `$count`가 함께 지원되는지 확인한 뒤에 넣을 일입니다.

감쌀 때 반영할 점은 이 글에서 겪은 것과 같습니다.

- **리디렉트 따라가기**: HTTP 클라이언트가 302를 따라가도록 설정합니다.
- **403 해석**: 403을 "권한 없음"으로 단정해 사용자에게 답하지 않게 합니다. "이름이 틀렸거나 구독 범위 밖일 수 있다"로 돌려주고, 데이터셋 식별자는 화면의 OData 링크, 테이블 이름은 서비스 루트로 확인하게 합니다.
- **키 보관**: 로컬에서는 권한 600 파일이나 키체인, 서버에 올릴 때는 클라우드의 비밀 저장소에 둡니다. 키는 도구 코드 안에서만 읽고 모델에게 보여 주지 않습니다.
- **조회량 제한**: 기본으로 `$top`을 작게 걸어 큰 테이블 전체를 한 번에 가져오지 않게 합니다.

## 확인하지 못한 것

- **요청 속도 제한과 요금 정책**은 확인하지 않았습니다. 자동화로 자주 부를 계획이면 계약 조건과 WoodMac 담당자에게 먼저 확인하세요.
- **Bulk API**는 써 보지 않았습니다. 사용법과 한도는 지원 문서의 별도 가이드를 보세요.
- `$filter`, `$select` 같은 다른 OData 쿼리 옵션은 이번에 쓰지 않았습니다. OData v4 표준 옵션이지만 Lens Direct가 어디까지 지원하는지는 확인하지 않았습니다.
- 302 리디렉트는 제가 확인한 데이터 조회에서 본 동작입니다. 모든 조회가 같은 방식으로 응답하는지는 확인하지 않았으니, 클라이언트는 리디렉트를 따라가도록 두는 편이 안전합니다.

## 정리

- 엔드포인트는 `https://data.woodmac.com/qe/v1/odata/<dataset>/<table>`, 인증은 Basic(사용자 이름 `apikey`, 비밀번호 = API 키)입니다.
- 키는 계정 화면의 **API keys**에서 직접 발급하고, **새로 발급하면 옛 키는 무효**가 됩니다.
- 제가 확인한 데이터 조회는 **302로 결과 JSON의 위치를 돌려줬으므로** `curl`에는 `-L`이 필요했습니다. `requests`는 기본으로 따라갑니다.
- URL은 작은따옴표로 감싸고 `curl -g`를 붙입니다. `$top`, `$count=true`로 작게 보고 `jq`로 구조만 확인합니다.
- **403은 구독 없음의 증거가 아닙니다.** 일부러 틀린 이름도 403이니, 데이터셋 식별자는 화면의 OData 링크에서, 테이블 이름은 서비스 루트에서 확인합니다.
- 키는 받자마자 파일이나 키체인에 두고, AI 도구의 대화창·`!` 명령에는 붙여 넣지 않습니다.
