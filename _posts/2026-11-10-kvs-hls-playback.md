---
title: "HLS 다시 보기: 재생 목록과 조각, 그리고 Chrome의 'maybe' 함정"
date: 2026-11-10 10:30:00 +0900
categories: [AWS, 영상 스트리밍]
tags: [aws-concepts, aws, kvs, webrtc, hls, mse, hls-js, video]
description: "KVS에 녹화한 영상을 브라우저에서 다시 보며 만난 문제에서 출발해, HLS 재생 목록과 조각의 원리, ListFragments·GetHLSStreamingSessionURL 흐름, MSE와 hls.js, canPlayType의 'maybe', CSP media-src, 재생 주소를 권한처럼 다루는 법을 정리합니다."
---

> **시리즈: AWS KVS로 실시간 영상 보내기**
> 1. KVS 큰 그림: 영상은 '땡겨오는' 게 아니라 만나서 흐른다
> 2. 시그널링: SDP offer/answer와 KVS 신호 채널
> 3. NAT와 STUN: 왜 두 기기는 바로 못 붙나
> 4. TURN과 ICE: 끝내 못 붙으면 중계한다
> 5. 암호화와 브라우저 보안: DTLS-SRTP, 그리고 CSP
> 6. 녹화: KVS WebRTC 수집과 저장 세션
> 7. **다시 보기: HLS 원리와 KVS 재생** ← 지금 글

현장 장비의 카메라 영상을 관제 웹 대시보드에서 실시간으로 보는 기능을 AI 에이전트와 같이 만들었습니다. 실시간 영상은 WebRTC로 흐르고, 6편에서 다룬 것처럼 같은 영상을 Amazon Kinesis Video Streams(KVS)의 스트림에 녹화도 해 둡니다. 마지막으로 남은 일은 녹화한 영상을 대시보드에서 **다시 보는** 기능이었습니다.

KVS는 녹화된 스트림을 HLS 주소로 내어 줍니다. 그래서 처음 짠 순서는 흔히 보는 그대로였습니다. 브라우저에게 "HLS를 직접 재생할 수 있어?"라고 묻고, 된다고 하면 `<video>`에 주소를 그대로 넣고, 안 된다고 하면 JavaScript 라이브러리로 재생합니다. 그런데 Chrome에서 이상한 일이 생겼습니다.

```js
video.canPlayType('application/vnd.apple.mpegurl'); // Chrome: "maybe"
```

Chrome은 "maybe"라고 답했고, 코드는 그것을 "된다"로 받아들여 주소를 `<video>`에 넣었습니다. 그리고 `<video>`는 KVS 재생 목록을 열자마자 재생 오류를 냈습니다. 할 수 있을지도 모른다고 해 놓고 실제로는 못 한 것입니다.

고치고 나니 두 번째 문제가 있었습니다. 내 컴퓨터에서 띄운 대시보드에서는 다시 보기가 잘 되는데, 배포한 사이트에서만 "스트림 없음"이 떴습니다. 코드는 똑같은데 말입니다.

> HLS 재생 목록에는 무엇이 들어 있고, 브라우저는 그것을 어떻게 영상으로 만드나? 그리고 "maybe"는 대체 무슨 뜻인가?

이 글은 그 질문에 대한 정리입니다. 먼저 HLS가 영상을 조각과 재생 목록으로 나르는 원리를 RFC 8216 기준으로 기초부터 짚고, KVS가 녹화를 HLS로 꺼내 주는 API를 공식 문서 기준으로 살펴봅니다. 이어서 브라우저가 HLS를 재생하는 두 길(자체 재생과 MSE 위의 hls.js)과 `canPlayType`의 세 가지 답을 보고, 그때 정한 것들과 배포본에서만 실패한 사례로 돌아갑니다.

## 앞 편 짧은 복습

이 글만 읽어도 되도록 앞 편 내용을 조금만 다시 적습니다.

- KVS에는 두 가지가 있습니다. **신호 채널**은 WebRTC 연결을 맺도록 두 쪽의 연결 정보를 이어 주는 중개자이고, 영상 자체는 장비와 브라우저 사이를 WebRTC로 직접(또는 TURN 중계로) 흐릅니다. **스트림**은 영상을 시간순 조각으로 저장해 두는 저장소입니다.
- 6편에서 신호 채널에 스트림을 연결해 두면, 장비가 보내는 WebRTC 영상을 KVS가 받아 스트림에 저장한다는 것을 보았습니다. 다시 보기는 이 스트림에서 영상을 꺼내 오는 일입니다.
- 브라우저는 로그인 뒤 Cognito 자격 증명 풀에서 받은 **임시 AWS 자격 증명**으로 KVS API에 SigV4 서명을 해서 직접 부릅니다. 이 부분은 [Cognito 사용자 풀과 자격 증명 풀: 로그인한 브라우저가 AWS를 직접 부르려면]({% post_url 2026-11-06-cognito-user-pool-identity-pool %})과 [인증 한 번에 정리: JWT, IAM(SigV4), Cognito는 각각 무엇을 증명하나]({% post_url 2026-11-01-auth-basics-jwt-iam-cognito %})에 정리했습니다.

## 왜 다시 보기는 HLS인가

실시간 영상에 이미 WebRTC를 쓰고 있는데 다시 보기에 왜 다른 방식을 쓸까요? 두 방식이 풀려는 문제가 다르기 때문입니다.

WebRTC는 **지금 이 순간**을 보내는 데 맞춰져 있습니다. 영상은 프레임이 나오는 대로 작은 패킷으로 잘려 보통 UDP 위의 SRTP로 흐릅니다. 받는 쪽은 아주 짧게만 버퍼링해서 도착 간격의 흔들림(jitter)을 흡수하고, 잃어버린 패킷은 재전송 요청(NACK)으로 다시 받기도 하지만 재생할 시점을 넘긴 데이터는 버릴 수 있습니다. UDP가 막힌 곳에서는 TURN 서버까지 TCP나 TLS로 붙기도 합니다([RFC 8835 §3.4~3.5](https://www.rfc-editor.org/rfc/rfc8835.html#section-3.4), [RFC 8834 §6.1](https://www.rfc-editor.org/rfc/rfc8834.html#section-6.1)). 이렇게 버퍼를 짧게 두는 설계 덕분에 지연을 수백 ms 수준까지 줄일 수 있지만, 그 값은 네트워크 상태에 따라 달라지고 프로토콜이 보장하는 수치는 아닙니다. 그리고 WebRTC 전송 자체에는 녹화를 찾아 지난 장면으로 되돌아가거나 원하는 위치로 건너뛰는 기능이 없습니다. 연결도 시청자마다 하나씩 맺어야 합니다.

HLS(HTTP Live Streaming)는 반대입니다. 영상을 몇 초짜리 **파일 조각**으로 잘라 두고, 플레이어가 평범한 HTTP GET으로 차례로 받아 이어 붙입니다. 이 글의 KVS 경로에서는 fragment가 만들어져 KVS에 들어가는 시간, 재생 목록과 조각을 받아 오는 시간, 플레이어가 재생 전에 데이터를 쌓아 두는 버퍼링 시간이 더해져 지연이 길어집니다(hls.js처럼 조각을 받는 도중부터 처리하는 실험적 옵션을 둔 플레이어도 있어서, 조각 하나를 다 받아야만 재생한다는 것이 HLS의 규칙은 아닙니다). KVS 문서는 HLS로 실시간을 볼 때 지연이 보통 3~5초, 상황에 따라 1~10초라고 적고, 1초보다 짧은 지연이 필요하면 HLS 대신 `GetMedia` API를 고려하라고 합니다. 대신 조각은 파일이라서 이미 저장된 과거 영상에도 그대로 쓸 수 있고, 몇 번째 조각부터 받을지만 정하면 원하는 위치로 건너뛸 수 있습니다. HTTP라서 캐시·CDN·방화벽과도 잘 맞습니다.

| | WebRTC | HLS |
|---|---|---|
| 나르는 단위 | 프레임을 자른 RTP 패킷 | 몇 초짜리 파일 조각 |
| 전송 | 보통 UDP 위 SRTP(TURN을 거치면 TCP·TLS도) | HTTP GET |
| 지연 | 수백 ms까지 줄일 수 있다(보장 값은 아님) | 수 초(KVS 문서 기준 보통 3~5초) |
| 지난 장면, 건너뛰기 | 전송 자체에는 없음 | 조각을 고르면 된다 |
| 잘 맞는 일 | 실시간 관제, 원격 조작 | 녹화 다시 보기, 많은 시청자 |

다시 보기는 지연이 몇 초 늘어도 상관없고, 대신 "10분 전부터 보기"와 재생 막대 끌기가 꼭 필요합니다. 그래서 다시 보기는 HLS가 맞습니다.

## HLS 원리: 조각과 재생 목록

HLS는 Apple이 만들었고 [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216)으로 공개되어 있습니다. 구성 요소는 둘뿐입니다. 영상을 자른 **조각(media segment)**과, 그 조각들의 주소를 순서대로 적은 텍스트 파일인 **재생 목록(playlist)**입니다. 재생 목록 파일의 확장자가 `.m3u8`이라서 HLS 주소는 대개 `.m3u8`로 끝납니다.

플레이어가 하는 일은 단순합니다.

1. 재생 목록을 HTTP로 받아 읽습니다.
2. 목록에 적힌 조각 주소를 순서대로 HTTP로 받습니다.
3. 받은 조각을 디코더에 이어 붙여 재생합니다.
4. 목록이 아직 자라는 중(라이브)이면 잠시 뒤 목록을 다시 받아 새 조각이 붙었는지 봅니다.

서버 쪽에 특별한 스트리밍 서버가 필요 없다는 점이 핵심입니다. 파일을 HTTP로 내어 줄 수 있으면 됩니다.

### 조각(segment)

조각은 영상의 몇 초를 담은 파일입니다. 영상은 대부분의 프레임이 앞 프레임과의 차이만 담고, 가끔 그 자체로 완전한 그림인 **키프레임**이 들어갑니다. 그중 디코더가 그 지점부터 앞 내용 없이 새로 디코딩을 시작할 수 있는 키프레임을 **랜덤 액세스 지점**이라고 하고, H.264에서는 **IDR** 프레임이 그 역할을 합니다(뒤 프레임이 IDR 앞을 참조하지 못하게 끊어 준다는 점에서 단순한 I-frame보다 강한 약속입니다). 아무 조각에서나 재생을 시작하거나 건너뛰기 좋도록, 보통 조각을 이런 랜덤 액세스 지점에 맞춰 자릅니다. RFC 8216도 H.264 조각에는 IDR을 넣기를 권하고(SHOULD), 조각이 IDR로 시작하지 않으면 그 앞 프레임은 받아 놓고도 버려질 수 있다고 적습니다. "모든 조각이 다른 조각 없이 디코딩된다"는 보장은 따로 `#EXT-X-INDEPENDENT-SEGMENTS` 태그로 선언합니다. 그래서 인코더가 키프레임을 얼마나 자주 넣느냐가 조각을 얼마나 잘게 자를 수 있는지를 정합니다. 이 이야기는 KVS 쪽에서 다시 나옵니다.

### 재생 목록 두 층: 마스터와 미디어

재생 목록은 두 종류입니다.

- **마스터 재생 목록(master playlist)**: 같은 영상의 여러 버전(해상도·비트레이트별)을 나열합니다. 플레이어는 네트워크 상태를 보고 하나를 고릅니다.
- **미디어 재생 목록(media playlist)**: 한 버전의 조각 주소를 시간순으로 나열합니다.

마스터 재생 목록은 이렇게 생겼습니다. 아래 예시는 설명을 위해 새로 쓴 가짜이고, 주소와 값은 의미가 없습니다.

```text
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="avc1.64001f",RESOLUTION=1280x720
media.m3u8
```

- `#EXTM3U`: 이 파일이 확장 M3U 재생 목록이라는 표시입니다. RFC는 이것이 **반드시 첫 줄**이어야 한다고 정합니다.
- `#EXT-X-STREAM-INF`: 바로 다음 줄의 주소가 어떤 버전인지 설명합니다. `BANDWIDTH`(초당 최대 비트 수)는 필수이고, `CODECS`는 넣어야 하며(SHOULD), `RESOLUTION`은 영상이 있으면 넣기를 권합니다. `avc1.64001f`는 H.264 High 프로파일이라는 뜻의 코덱 문자열입니다.
- `media.m3u8`: 그 버전의 미디어 재생 목록 주소입니다. 상대 주소면 이 파일의 주소를 기준으로 풉니다.

버전이 하나뿐이어도 마스터 재생 목록을 두는 경우가 많습니다. KVS도 플레이어에게 마스터 재생 목록 주소를 주고, 플레이어는 거기서 미디어 재생 목록으로 넘어갑니다.

### 미디어 재생 목록 한 줄씩 읽기

실제 조각이 적힌 쪽은 미디어 재생 목록입니다. 역시 가짜 예시입니다(실행 미확인, KVS가 실제로 돌려주는 태그 구성과 같다고 보장하지 않습니다).

```text
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:00.000Z
#EXTINF:1.001,
seg-0.m4s
#EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:01.001Z
#EXTINF:0.999,
seg-1.m4s
#EXT-X-DISCONTINUITY
#EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:20.000Z
#EXTINF:1.000,
seg-2.m4s
#EXT-X-ENDLIST
```

위에서부터 읽어 보겠습니다.

- `#EXT-X-VERSION:6`: 이 목록을 해석하는 데 필요한 HLS 프로토콜 호환 버전입니다. 소수점 조각 길이, `EXT-X-MAP` 같은 기능은 일정 버전 이상에서만 쓸 수 있어서, 쓰는 기능에 따라 정합니다.
- `#EXT-X-TARGETDURATION:2`: **조각 길이의 상한(초, 정수)**입니다. 필수 태그이고, 모든 조각의 `EXTINF` 길이를 가장 가까운 정수로 반올림한 값이 이보다 크면 안 됩니다. 플레이어는 이 값으로 목록을 다시 받을 간격을 정하므로 라이브에서 특히 중요합니다.
- `#EXT-X-MEDIA-SEQUENCE:0`: 목록의 첫 조각 번호입니다. 없으면 0입니다. 라이브 목록은 앞쪽 조각이 빠지면서 이 번호가 늘어나고, 플레이어는 이 번호로 "어디까지 받았는지"를 맞춥니다.
- `#EXT-X-PLAYLIST-TYPE:VOD`: 이 목록이 **바뀌지 않는다**는 약속입니다. `EVENT`면 "뒤에 붙기만 하고 앞은 안 지운다"는 약속입니다. 이 태그는 선택 사항이라, 없다고 곧 라이브 목록이라는 뜻은 아닙니다. 없으면 VOD나 EVENT의 추가 변경 제한을 선언하지 않았을 뿐이고, 목록 갱신에 관한 RFC의 기본 규칙은 그대로 적용됩니다. `ENDLIST`로 닫힌 목록에도 이 태그가 없을 수 있습니다.
- `#EXT-X-MAP:URI="init.mp4"`: 뒤따르는 조각들을 해석하는 데 필요한 **초기화 조각(initialization section)**의 주소입니다. 조각이 fMP4이면 이 태그가 필요합니다(아래 "조각 그릇"에서 다시 봅니다).
- `#EXT-X-PROGRAM-DATE-TIME:...`: 바로 다음 조각의 **첫 샘플을 절대 시각에 연결**합니다(ISO 8601 형식). 곧 미디어 시각과 절대 시각 사이의 **매핑**입니다. 플레이어 안의 재생 위치는 "시작부터 몇 초"일 뿐인데, 이 태그가 있으면 그 위치를 날짜·시각으로 바꿔 볼 수 있습니다. 그 시각이 촬영 시각인지, 서버가 받은 시각인지는 목록을 만든 쪽이 어떤 시계를 썼느냐에 달려 있습니다. 녹화 다시 보기에서 화면에 녹화 시각을 띄울 때 바로 이것을 씁니다.
- `#EXTINF:1.001,`: 바로 **다음 한 조각**의 길이(초)입니다. 다음 줄의 주소 하나에만 적용됩니다. 쉼표 뒤에는 사람이 읽을 제목을 넣을 수 있지만 보통 비워 둡니다.
- `seg-0.m4s`: 조각 주소입니다. `#`으로 시작하지 않는 줄은 모두 주소입니다.
- `#EXT-X-DISCONTINUITY`: 이 태그 앞뒤 조각 사이에 **끊김**이 있다는 표시입니다. RFC는 파일 형식, 트랙의 수·종류, 타임스탬프 순서가 바뀌면 반드시(MUST) 넣으라고 하고, 인코딩 매개변수나 인코딩 순서가 바뀌는 경우에는 넣기를 권합니다(SHOULD). 예시에서는 `seg-1`이 2.000초(1.001 + 0.999)에 끝나고 18초 동안 녹화가 비었다가 `seg-2`가 이어집니다. 플레이어는 이 표시를 보면 시간축을 새로 맞추고 다음 조각을 바로 이어서 재생합니다.
- `#EXT-X-ENDLIST`: **조각이 더 붙지 않는다**는 표시입니다. 이것이 있으면 플레이어는 목록을 다시 받지 않고, 전체 길이를 알 수 있으니 재생 막대를 그릴 수 있습니다.

`#EXT`로 시작하는 줄은 태그이고, 플레이어는 모르는 태그를 무시합니다. 그래서 서버가 추가 정보를 넣어도 오래된 플레이어가 깨지지 않습니다.

### 라이브 목록과 다 끝난 목록

같은 형식으로 라이브와 녹화 재생을 다 할 수 있는 이유는 "목록이 바뀌느냐"의 차이뿐이기 때문입니다.

- **라이브**: `ENDLIST`가 없고, 서버는 새 조각이 생길 때마다 목록 끝에 붙이고 오래된 조각은 앞에서 뺍니다. 플레이어는 목록을 계속 다시 받습니다. RFC는 그 간격도 정합니다. 다시 받은 목록이 바뀌었으면 **최소 타깃 길이만큼** 기다렸다가 다시 받고, 바뀌지 않았으면 **타깃 길이의 절반**만 기다렸다가 다시 시도합니다. 또 `ENDLIST`가 없는 목록에서는 끝에서 타깃 길이 세 배 안쪽의 조각부터 재생을 시작하지 않도록 권합니다(SHOULD NOT). 끝에 너무 붙어서 시작하면 다음 조각이 오기 전에 멈추기 쉽기 때문입니다.
- **VOD**: 목록이 처음부터 끝까지 다 적혀 있고 `ENDLIST`로 닫혀 있습니다. 한 번 받으면 끝입니다.
- **EVENT**: 그 중간입니다. 뒤에 붙기만 하고 앞은 지우지 않으니, 진행 중인 행사를 처음부터 되감아 볼 수 있습니다.

### 조각 그릇: TS와 fMP4

용어 셋을 먼저 짚습니다. **코덱**(H.264, AAC 등)은 영상·소리를 압축하는 규칙이고, **컨테이너**(MP4, TS 등)는 그렇게 압축한 데이터를 시각 정보와 함께 담는 파일 형식이며, **트랙**은 컨테이너 안에서 영상, 소리처럼 따로 흐르는 시간축 하나입니다. 조각 파일 안의 영상은 어떤 그릇(컨테이너)에 담길까요? RFC 8216은 MPEG-2 TS, fragmented MPEG-4(fMP4), 오디오 전용 packed audio, 자막용 WebVTT를 정합니다. 영상에는 앞의 둘을 씁니다.

- **MPEG-2 TS**: 방송에서 온 오래된 형식입니다. 조각 하나하나가 자기 설명을 다 담고 있어서 어느 조각부터든 바로 해석할 수 있지만, 188바이트 작은 패킷마다 머리가 붙어 덧붙는 크기가 큽니다.
- **fMP4**: MP4를 잘게 나눈 형식입니다. 코덱 설정 같은 "영상 전체에 대한 설명"은 **초기화 조각**(`ftyp`와 `moov` 상자)에 따로 두고, 각 미디어 조각에는 실제 프레임(`moof`와 `mdat` 상자)만 담습니다. 그래서 플레이어는 초기화 조각을 먼저 받고, 그다음 미디어 조각을 차례로 받습니다. 위 예시의 `EXT-X-MAP`이 그 초기화 조각을 가리킵니다. 예시처럼 트랙 하나에 코덱 설정이 끝까지 같으면 초기화 조각도 하나로 충분하지만, 트랙마다 목록이 따로 있거나 중간에 코덱 설정이 바뀌면 `EXT-X-MAP`이 새로 나와 초기화 조각이 더 필요할 수 있습니다.

KVS는 두 가지를 다 지원하는데, 기본값이자 권장값은 fMP4입니다. 문서는 MPEG-TS를 고르면 fMP4보다 덧붙는 크기가 대략 5~25% 더 든다고 적고, TS는 오래된 플레이어 호환이 필요할 때만 쓰라고 합니다.

## KVS는 녹화를 어떻게 꺼내 주나

이제 KVS 쪽입니다. KVS 스트림은 녹화를 처음부터 HLS 조각으로 저장해 두는 것이 아니라, 받은 영상을 **fragment**라는 자기 단위로 저장해 둡니다. 다시 보기를 요청하면 KVS가 그 fragment들로 재생 목록과 조각을 그때그때 만들어 줍니다.

### fragment와 두 개의 시각

KVS의 fragment는 HLS 조각과 거의 같은 개념입니다. [KVS HLS 문서](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/hls-playback.html)는 fragment 길이를 "인코더가 키프레임을 만드는 빈도로 정해지는, 스트림이 나뉘는 간격"이라고 설명합니다. 키프레임이 올 때 새 fragment가 시작되니, 키프레임 간격이 곧 fragment 길이입니다. 권장값은 1초이고, 1초보다 짧으면 플레이어가 조각을 너무 자주 요청해서 KVS가 플레이어를 제한(throttle)할 수 있다고 적혀 있습니다.

fragment마다 시각이 두 개 붙습니다.

- **ProducerTimestamp**: 영상을 보낸 쪽(producer)이 붙인 시각입니다.
- **ServerTimestamp**: KVS가 그 fragment를 받은 시각입니다.

어느 시각으로 찾고 재생할지를 API마다 고릅니다. 장비 시계를 믿기 어렵다면 KVS가 붙인 서버 시각이 일관된 기준이 됩니다. 다만 서버 시각은 **받은 시각**이라, 촬영 시각과는 전송 지연이나 보내는 쪽 버퍼링만큼 차이가 날 수 있습니다.

AWS 문서가 정한 최소 흐름은 `GetDataEndpoint`로 주소를 받고 `GetHLSStreamingSessionURL`로 재생 주소를 받는 두 단계입니다. 보고 싶은 시간 범위를 이미 알면 그것으로 충분합니다. 이 글의 다시 보기 화면은 "언제 녹화가 있는지" 목록을 보여 줘야 해서 그 사이에 `ListFragments`를 더 부릅니다. 그래서 이 화면은 서명한 API를 세 **종류** 씁니다. 실제 요청 수는 더 많습니다. `GetDataEndpoint`는 API 이름마다 따로 부르고, `ListFragments`는 여러 쪽으로 나뉘어 올 수 있기 때문입니다. 순서대로 보겠습니다.

### ① GetDataEndpoint: 이 스트림의 데이터 주소

KVS는 스트림을 관리하는 API(만들기, 설명 보기)와 영상 데이터를 다루는 API(넣기, 꺼내기)의 주소가 다릅니다. 데이터 API는 스트림마다 정해진 **데이터 엔드포인트**로 불러야 해서, 먼저 [`GetDataEndpoint`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_GetDataEndpoint.html)로 그 주소를 받습니다.

```json
{
  "StreamName": "device-a-recording",
  "APIName": "LIST_FRAGMENTS"
}
```

`APIName`에는 다음에 부를 API를 적습니다(`PUT_MEDIA`, `GET_MEDIA`, `LIST_FRAGMENTS`, `GET_HLS_STREAMING_SESSION_URL`, `GET_CLIP` 등). 응답의 `DataEndpoint`가 그 API를 부를 주소이고, 클라이언트는 그 뒤에 API 경로를 붙여 요청합니다. 다시 보기에는 `ListFragments`와 `GetHLSStreamingSessionURL` 두 API를 쓰니, API 이름마다 따로 물어 둡니다.

이 호출도 SigV4 서명이 필요합니다. 실제로 서명 없이 부르면 403이 돌아왔습니다. 그리고 할당량이 꽤 빡빡합니다. [KVS 할당량 문서](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/limits.html) 기준 스트림 하나당 초당 5회, 계정 전체로 초당 300회이고, 둘 다 늘릴 수 없는(hard) 한도입니다. 같은 스트림·같은 API의 주소는 한 번 받아 두고 다시 쓰는 편이 좋습니다.

### ② ListFragments: 녹화가 어디 있나

다시 보기 화면에는 "언제 녹화된 영상이 있는지" 목록이 필요합니다. [`ListFragments`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_reader_ListFragments.html)는 시간 범위를 주면 그 안의 fragment 정보를 돌려줍니다. ①에서 받은 `LIST_FRAGMENTS`용 데이터 주소로 부릅니다.

```json
{
  "StreamName": "device-a-recording",
  "MaxResults": 1000,
  "FragmentSelector": {
    "FragmentSelectorType": "SERVER_TIMESTAMP",
    "TimestampRange": {
      "StartTimestamp": 1767225600,
      "EndTimestamp": 1767247200
    }
  }
}
```

시각은 Unix 초입니다(예시는 2026-01-01 00:00~06:00 UTC). 응답의 fragment 하나에는 `FragmentNumber`, `FragmentSizeInBytes`, `ProducerTimestamp`, `ServerTimestamp`, `FragmentLengthInMilliseconds`가 들어 있습니다. 시작 시각과 길이가 있으니 이것만으로 "어디서 어디까지 녹화가 있나"를 계산할 수 있습니다.

이 API에는 알아 둘 성질이 셋 있습니다.

- **순서가 없습니다.** 문서는 결과가 "특정한 순서 없이, 쪽(page)을 넘어서도" 온다고 분명히 적습니다. 받은 뒤 반드시 시각으로 정렬해야 합니다.
- **나눠서 옵니다.** `MaxResults`는 기본 100, 최대 1000이고, 더 있으면 `NextToken`이 함께 옵니다. 다음 요청에 그 토큰을 넣어 이어 받습니다.
- **조금 늦습니다.** 결과는 최종 일관성(eventually consistent)을 따릅니다. 방금 들어온 fragment는 보통 1초 안쪽이지만 바로 안 보일 수 있습니다.

할당량도 있습니다. fragment 메타데이터 API는 스트림당 초당 10,000 "점"을 나눠 쓰는데, `ListFragments` 한 번이 `MaxResults` 값만큼 점을 씁니다. `MaxResults`를 1000으로 두면, 같은 한도를 쓰는 다른 호출이 없을 때 초당 10번까지 부를 수 있다는 뜻입니다. 이 점수는 `GetHLSMediaPlaylist`(플레이어가 재생 목록을 받을 때) 같은 다른 메타데이터 호출과 스트림 단위로 함께 씁니다.

### ③ GetHLSStreamingSessionURL: 재생 주소 받기

보고 싶은 구간이 정해지면 [`GetHLSStreamingSessionURL`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_reader_GetHLSStreamingSessionURL.html)로 재생 주소를 받습니다. ①에서 받은 `GET_HLS_STREAMING_SESSION_URL`용 데이터 주소로 부릅니다.

```json
{
  "StreamName": "device-a-recording",
  "PlaybackMode": "ON_DEMAND",
  "HLSFragmentSelector": {
    "FragmentSelectorType": "SERVER_TIMESTAMP",
    "TimestampRange": {
      "StartTimestamp": 1767232800,
      "EndTimestamp": 1767234600
    }
  },
  "ContainerFormat": "FRAGMENTED_MP4",
  "DiscontinuityMode": "ALWAYS",
  "DisplayFragmentTimestamp": "ALWAYS",
  "MaxMediaPlaylistFragmentResults": 2000,
  "Expires": 3600
}
```

구간은 2026-01-01 02:00~02:30 UTC, 30분입니다. `MaxMediaPlaylistFragmentResults`를 빼면 `ON_DEMAND`에서는 기본값 1,000개가 적용되고, 구간 **앞쪽의 오래된 fragment부터** 1,000개만 목록에 들어갑니다. fragment가 1초라면 30분은 1,800개라서, 기본값으로는 앞의 16분 40초만 담깁니다. 그래서 예시에는 30분 창을 다 담도록 2,000을 넣었습니다(최댓값은 5,000). fragment가 1,000개를 넘지 않는 구간이라면 빼도 됩니다.

응답은 `HLSStreamingSessionURL` 하나입니다. 이것이 마스터 재생 목록 주소이고, 그대로 플레이어에 넘깁니다. 매개변수를 하나씩 보겠습니다.

**PlaybackMode**: 위에서 본 HLS의 라이브·VOD 구분이 여기 대응합니다.

| 모드 | 재생 목록 | 쓰임 |
|---|---|---|
| `LIVE` (기본값) | 새 fragment가 들어올 때마다 계속 갱신된다. 플레이어는 1초쯤마다 다시 받는다. 늦게 들어온 fragment로 틈을 메우지 않는다 | 실시간 보기 |
| `LIVE_REPLAY` | 정한 시작 시각부터 출발해, 각 fragment 길이만큼 시간이 지날 때마다 하나씩 붙인다 | 사건 시점부터 이어서 보기, 아주 긴 과거 구간 |
| `ON_DEMAND` | 구간의 fragment를 처음부터 다 담는다. 세션당 한 번만 받으면 된다 | 녹화 다시 보기, 재생 막대 |

**HLSFragmentSelector**: 어느 시각 기준으로(`SERVER_TIMESTAMP` 또는 `PRODUCER_TIMESTAMP`) 어느 구간을 볼지입니다. `ON_DEMAND`와 `LIVE_REPLAY`에서는 필수입니다. 끝 시각은 시작 시각에서 **24시간 안쪽**이어야 하고, 서버 시각 기준이면 **과거**여야 합니다.

**ContainerFormat**: 앞에서 본 fMP4(`FRAGMENTED_MP4`, 기본값·권장)와 TS(`MPEG_TS`) 중 하나입니다.

**DiscontinuityMode**: fragment 사이에 `#EXT-X-DISCONTINUITY`를 언제 넣을지입니다. 문서 설명이 원리를 잘 보여 줍니다. 플레이어는 각 fragment의 타임스탬프로 시간축을 만드는데, 서버 시각은 "받은 시각"이라 fragment 사이에 조금씩 틈이나 겹침이 생기기 쉽습니다. 틈은 재생을 멈추게 하고 겹침은 화면을 떨게 만듭니다. 끊김 표시가 있으면 플레이어는 시간축을 새로 맞추고 다음 조각을 바로 이어 재생합니다.

- `ALWAYS`: 모든 fragment 사이에 넣습니다. 타임스탬프가 정확하지 않을 때 권장됩니다. 서버 시각 기준의 기본값입니다.
- `NEVER`: 넣지 않습니다. 보낸 쪽 시각이 정확해서 시간축을 그대로 따르게 할 때 씁니다. 보낸 쪽 시각 기준의 기본값입니다.
- `ON_DISCONTINUITY`: 50ms보다 큰 틈이나 겹침이 있을 때만 넣습니다.

**DisplayFragmentTimestamp**: `ALWAYS`면 fragment 시작 시각을 미디어 재생 목록에 넣습니다(기본값 `NEVER`). 플레이어는 보통 재생 위치를 "세션 시작부터 몇 초"로만 알려 주는데, 이 시각이 목록에 있으면 일부 플레이어는 재생 위치를 날짜·시각으로 알려 줄 수 있습니다. 앞에서 본 `EXT-X-PROGRAM-DATE-TIME`이 하던 역할입니다. 들어가는 값은 선택한 기준의 시각이라, `SERVER_TIMESTAMP`를 골랐다면 KVS가 fragment를 받은 시각입니다.

**Expires**: 세션이 끝나기까지의 초입니다. 300(5분)부터 43200(12시간)까지이고 **기본값은 300**입니다. 만료되면 그 세션으로 재생 목록이나 조각을 새로 받을 수 없습니다. 이미 받은 조각이 다 떨어지면 재생이 멈춥니다.

**MaxMediaPlaylistFragmentResults**: 미디어 재생 목록에 담을 fragment 최대 개수입니다. `ON_DEMAND`의 기본값은 1,000, 최댓값은 5,000입니다. 상한을 넘으면 구간 앞쪽의 오래된 fragment부터 상한만큼만 담깁니다. 문서에 따르면 5,000개는 1초 fragment로 80분 남짓, 10초 fragment로 13시간 남짓입니다. 이보다 긴 구간은 나눠서 받거나 `LIVE_REPLAY`로 봅니다.

받을 수 있는 영상에도 조건이 있습니다. 영상 트랙은 H.264(AVC) 또는 H.265(HEVC) 형식의 코덱 설정(codec private data)을 담아야 하고, 오디오 트랙이 있으면 AAC여야 합니다([KVS 재생 요구 사항](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/video-playback-requirements.html)). 이것은 "KVS가 HLS로 내어 줄 수 있다"는 조건일 뿐입니다. "브라우저에서 hls.js를 실행할 수 있다", "이 브라우저가 실제 영상 코덱을 디코딩할 수 있다"는 따로 확인해야 하는 별개의 조건입니다. 예를 들어 KVS가 H.265 스트림을 HLS로 내어 줘도, H.265를 디코딩하지 못하는 브라우저에서는 재생되지 않습니다. 구간에 fragment가 하나도 없으면(`LIVE`라면 최근 30초 안에 없으면) `ResourceNotFoundException`(404)이 돌아옵니다.

### 그다음은 플레이어의 일

재생 주소를 받은 뒤부터는 브라우저 코드가 KVS API를 부르지 않습니다. 플레이어가 그 주소에서 출발해 다음을 차례로 HTTP GET으로 받습니다.

- `GetHLSMasterPlaylist`: 마스터 재생 목록
- `GetHLSMediaPlaylist`: 미디어 재생 목록(트랙마다 하나)
- `GetMP4InitFragment`: fMP4 초기화 조각(`ftyp`·`moov`)
- `GetMP4MediaFragment`: fMP4 미디어 조각(`moof`·`mdat`), TS를 골랐다면 `GetTSFragment`

이 요청들에는 SigV4 서명이 없습니다. 대신 재생 주소의 쿼리 문자열에 **암호화된 세션 토큰**이 들어 있고, KVS는 그 토큰으로 세션을 확인합니다. 문서의 예시 주소는 이런 모양입니다.

```text
https://b-1234abcd.kinesisvideo.<region>.amazonaws.com/hls/v1/getHLSMasterPlaylist.m3u8?SessionToken=...
```

<figure class="diagram">
{% include figures/kvs-hls-playback/replay-flow.svg %}
<figcaption>이 화면은 세 종류의 서명 API로 녹화 구간과 세션 URL을 얻고(②는 목록을 보여 주기 위한 단계), 그다음부터는 플레이어가 URL 속 토큰만으로 재생 목록과 조각을 HTTP로 받는다</figcaption>
</figure>

이 그림에서 점선이 이 글의 뒷부분 두 주제를 가릅니다. 점선 위는 "AWS 자격 증명을 가진 사람만 할 수 있는 일"이고, 점선 아래는 "**URL을 가진 사람이면 누구나** 할 수 있는 일"입니다. 그래서 점선 아래에서는 브라우저 보안 정책(CSP)과 URL 관리가 중요해집니다.

## 브라우저가 HLS를 재생하는 두 길

`<video>` 요소에 HLS 주소를 주면 바로 재생될까요? 브라우저마다 다릅니다. 길은 두 가지입니다.

### 첫 번째 길: 브라우저 자체 HLS

Safari는 HLS를 직접 압니다. `video.src`에 `.m3u8` 주소를 넣으면 브라우저가 재생 목록을 받고, 조각을 받고, 이어 붙이는 일을 다 알아서 합니다. 코드로 보면 가장 간단합니다.

```js
video.src = hlsUrl; // 브라우저가 HLS를 직접 처리할 때만 된다
```

이때 재생 목록과 조각을 받는 주체는 **`<video>` 요소 자신**입니다. JavaScript의 `fetch`가 아니라 미디어 요소가 KVS 주소를 직접 엽니다. CSP에서 이 차이가 중요해집니다.

최근에는 Chrome도 자체 HLS 재생을 넣고 있다는 이야기가 [hls.js 저장소 이슈](https://github.com/video-dev/hls.js/issues/7827)에서 오갑니다. 이 글의 "maybe"는 그 과도기와 관련이 있어 보이지만, 우리 경우의 정확한 원인은 따로 파고들지 않았습니다.

### 두 번째 길: MSE 위에서 JavaScript가 재생

HLS를 직접 모르는 브라우저에서도 HLS를 재생할 수 있게 해 주는 것이 **MSE(Media Source Extensions)**입니다. MSE는 "영상 데이터를 JavaScript가 직접 `<video>`에 밀어 넣는" 브라우저 API입니다.

1. JavaScript가 `MediaSource` 객체를 만듭니다.
2. `URL.createObjectURL(mediaSource)`로 그 객체를 가리키는 `blob:` 주소를 만들어 `video.src`에 넣습니다. 이제 `<video>`는 네트워크 대신 그 `MediaSource`에서 데이터를 받습니다.
3. `MediaSource`에 코덱별 `SourceBuffer`를 만들고, JavaScript가 받아 온 fMP4 조각(먼저 초기화 조각, 다음 미디어 조각)을 `appendBuffer()`로 넣습니다.
4. 브라우저는 버퍼에 쌓인 데이터를 디코딩해 재생합니다.

HLS 재생 목록을 읽고, 어떤 조각을 언제 받을지 정하고, 조각을 받아 `SourceBuffer`에 넣는 일을 해 주는 라이브러리가 [hls.js](https://github.com/video-dev/hls.js)입니다. hls.js는 fMP4 조각을 그대로 넣고, TS 조각은 브라우저가 받는 fMP4로 바꿔(transmux) 넣습니다. hls.js 소스도 실제로 `URL.createObjectURL(ms)`로 `<video>`에 붙입니다. 그래서 hls.js로 재생하면 `video.src`는 `blob:…`이 되고, KVS 주소는 JavaScript의 네트워크 요청으로만 열립니다.

iPhone의 Safari는 오랫동안 MSE가 없어서 자체 HLS만 쓸 수 있었습니다. iOS 17.1부터는 MSE의 변형인 **ManagedMediaSource**가 생겼고, hls.js는 1.5부터 그것을 씁니다. ManagedMediaSource는 버퍼를 언제 비울지 브라우저가 더 많이 결정한다는 점이 다르지만, "JavaScript가 조각을 넣는다"는 구조는 같습니다.

### canPlayType의 세 가지 답

어느 길로 갈지 정하려면 브라우저에게 물어봐야 합니다. 흔히 쓰는 질문이 [`canPlayType()`](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/canPlayType)입니다. MDN에 따르면 답은 셋 중 하나입니다.

| 답 | 뜻 |
|---|---|
| `""` (빈 문자열) | 재생할 수 없다 |
| `"maybe"` | 재생할 수 있는지 판단할 정보가 부족하다(**실제로 재생해 보기 전까지는**) |
| `"probably"` | 아마 재생할 수 있다 |

"예"라는 답은 아예 없습니다. 가장 강한 답도 "아마"입니다. 그리고 "maybe"는 MDN 설명 그대로 "해 봐야 안다"는 뜻입니다. 그런데 많은 코드가 이렇게 씁니다.

```js
if (video.canPlayType('application/vnd.apple.mpegurl')) { // "maybe"도 참이다
  video.src = url;
}
```

빈 문자열만 거짓이고 `"maybe"`는 참이니, "해 봐야 안다"가 "된다"로 바뀝니다. 처음 코드가 바로 이 순서였고, Chrome이 "maybe"라고 답한 순간 hls.js가 아니라 자체 재생기로 갔습니다. 그리고 자체 재생기는 KVS 재생 목록을 재생하지 못했습니다.

hls.js README도 이 점을 경고합니다. 자체 재생이 꼭 필요한 경우가 아니면 `Hls.isSupported()`를 먼저 확인하기를 권하고, 어떤 브라우저는 `canPlayType`으로 HLS를 지원한다고 답하면서도 일부 영상을 제대로 재생하지 못할 수 있다고 적습니다. 앞에서 말한 이슈에는 Chrome이 "maybe"라고 답하고 자체 재생에서 실패한 다른 사례가 올라와 있고, 관리자는 이를 Chrome 쪽 버그로 보았으며, 이 경고 문구가 README에 들어갔습니다.

<figure class="diagram">
{% include figures/kvs-hls-playback/play-path.svg %}
<figcaption>먼저 hls.js를 쓸 수 있는지(MSE가 있고 Hls.isSupported()가 참인지) 보고, 안 되면 자체 HLS를, 그것도 안 되면 오류를 낸다. 길마다 KVS 주소를 여는 주체가 달라서 CSP에 필요한 항목도 다르다</figcaption>
</figure>

## 그때 정한 것

이제 원래 문제로 돌아갑니다. 다시 보기를 만들면서 정한 것을 다섯 가지로 정리합니다.

### 1. hls.js를 쓸 수 있으면 먼저, 안 되면 자체 HLS

순서를 뒤집었습니다. 판단은 세 단계입니다.

1. **hls.js를 쓸 수 있나?** 먼저 `MediaSource`나 `ManagedMediaSource`가 있는지 봅니다. 이것은 MSE가 아예 없는 브라우저(MSE가 없는 오래된 iPhone Safari 등)에서 hls.js를 내려받는 낭비를 피하려는 1차 거름입니다. 있으면 hls.js를 불러와 `Hls.isSupported()`로 한 번 더 확인하고, 참이면 hls.js로 재생합니다.
2. **자체 HLS는 되나?** MSE가 없거나 `Hls.isSupported()`가 거짓이면 `canPlayType`으로 자체 HLS를 시도합니다. 여기서는 "maybe"라도 해 보는 수밖에 없습니다.
3. **둘 다 안 되면** 오류를 냅니다.

`canPlayType`은 hls.js를 쓸 수 없을 때의 판단에만 씁니다.

hls.js는 기능을 덜어 낸 light 빌드(1.7.4)를 쓰고, 다시 보기를 **처음 열 때만** 불러오게 했습니다. 실시간 보기만 쓰는 사용자는 이 코드를 받지 않습니다. light 빌드에는 대체 오디오·자막, DRM(EME), 광고 삽입, CMCD 같은 기능이 빠져 있습니다. 이 사례에서는 소리 없이 영상만 보는 다시 보기를 확인했고, 그 범위에서는 light 빌드로 충분했습니다. 카메라가 하나여도 미디어 트랙이 하나라는 뜻은 아니고, KVS는 fMP4일 때 트랙마다 미디어 재생 목록을 따로 줍니다. 소리까지 재생하려면 실제로 받은 마스터 재생 목록의 오디오 구성을 확인하고 full 빌드를 검토하는 편이 안전합니다. 우리는 소리를 들어 보는 시험은 하지 않았습니다.

뼈대는 이렇습니다. 이 글을 위해 새로 쓴 최소 예시이고, 실행 미확인입니다. 재생 주소는 `getReplayUrl()`이 위의 ①~③을 거쳐 받아 온다고 가정합니다.

```js
// 재생 길 고르기: hls.js를 쓸 수 있으면 hls.js, 아니면 브라우저 자체 HLS, 둘 다 안 되면 오류 (실행 미확인)
// video는 호출하는 쪽이 <video controls playsinline>로 준비한다고 가정한다.
// onError는 hls.js의 치명적 오류만 받는다. getReplayUrl()·import 실패와 자체 HLS 오류는 다루지 않는다.
export async function playReplay(video, getReplayUrl, onError) {
  const url = await getReplayUrl(); // 재생마다 새로 받는다. 기록하지 않는다.

  const hasMse = 'MediaSource' in window || 'ManagedMediaSource' in window;
  if (hasMse) { // MSE가 아예 없으면 hls.js를 내려받지 않는다
    const { default: Hls } = await import('hls.js/light'); // 처음 열 때만 불러온다
    if (Hls.isSupported()) {
      const hls = new Hls();
      hls.on(Hls.Events.ERROR, (_event, data) => {
        if (data.fatal) {
          hls.destroy();
          onError(data.type);
        }
      });
      hls.loadSource(url);
      hls.attachMedia(video);
      return {
        stop: () => hls.destroy(),
        recordedAt: () => hls.playingDate, // PROGRAM-DATE-TIME 기준 시각(SERVER_TIMESTAMP면 서버 수신 기준)
      };
    }
  }

  // MSE가 없거나 Hls.isSupported()가 false일 때 여기로 온다. "maybe"라도 해 보는 수밖에 없다.
  if (video.canPlayType('application/vnd.apple.mpegurl')) {
    video.src = url;
    return {
      stop: () => {
        video.removeAttribute('src');
        video.load();
      },
      recordedAt: () => null,
    };
  }

  throw new Error('이 브라우저는 HLS를 재생할 수 없습니다');
}
```

몇 가지 짚어 둡니다.

- `'MediaSource' in window`로 먼저 거르는 이유는, MSE가 없는 브라우저에서 hls.js를 내려받는 낭비를 피하려는 것입니다. hls.js를 쓸지는 [`Hls.isSupported()`](https://github.com/video-dev/hls.js/blob/v1.7.4/src/is-supported.ts)가 정합니다. 1.7.4 소스를 보면 이 함수는 MSE와 `SourceBuffer` API가 있는지 확인한 뒤, 영상(H.264, AV1, VP9)이나 소리(AAC, FLAC) 후보 형식 가운데 **하나라도** 브라우저가 받겠다고 하는지 봅니다. 그래서 참이라는 답은 "hls.js를 실행할 수 있다"는 뜻이지, H.264와 AAC를 둘 다 지원한다거나 이 KVS 영상의 실제 코덱이 디코딩된다는 보장은 아닙니다.
- 이 뼈대는 재생 길을 고르고 주소를 붙이는 데까지만 합니다. 호출하는 쪽이 `<video controls playsinline>`처럼 사용자가 재생을 누를 수 있는 요소를 주거나, 사용자 동작에서 `video.play()`를 부른다고 가정합니다. 또 `getReplayUrl()`이나 hls.js 불러오기(`import`)의 실패, 자체 HLS 길의 `<video>` 오류는 `onError`로 전달되지 않습니다. 실제 코드에서는 `try`/`catch`와 `video`의 `error` 이벤트로 함께 처리합니다.
- 오류 처리는 일부러 단순하게 두었습니다. hls.js 문서는 치명적인 미디어 오류에는 `hls.recoverMediaError()`를 시도하고, 네트워크 오류는 바로 다시 시작하지 말라고 권합니다. 실제 코드에서는 오류 종류에 따라 다시 시도할지 정하면 됩니다.
- `hls.playingDate`는 hls.js API 문서 기준 "재생 중인 화질의 Program Date Time이 있으면 그것을 기준으로 한, `media.currentTime`에 해당하는 날짜·시각"입니다. 재생 목록에 시각이 들어 있어야 값이 나오므로 `DisplayFragmentTimestamp: "ALWAYS"`와 짝을 이룹니다. `SERVER_TIMESTAMP` 기준이면 이 값도 서버가 받은 시각 기준입니다.
- `import('hls.js/light')`가 되는 이유는 hls.js 1.7.4의 `package.json`이 `./light` 경로를 light 빌드로 내보내기 때문입니다. 번들러 없이 쓴다면 light 빌드 파일을 직접 가리키면 됩니다.

### 2. 다시 보기 목록 만들기

fragment 목록을 그대로 보여 줄 수는 없습니다. 1초짜리 fragment라면 한 시간에 3,600개입니다. 그래서 fragment를 "녹화 한 덩어리" 단위로 묶어 목록을 만들었습니다. 정한 규칙은 이렇습니다(시험 운영 전 계획 값).

1. **최근 6시간**의 fragment를 서버 시각 기준으로 `ListFragments`에서 받습니다. `NextToken`으로 여러 쪽을 이어 받되, 받을 쪽 수에 상한을 둡니다.
2. 받은 fragment를 **시작 시각으로 정렬**합니다. 결과에 순서가 없기 때문입니다.
3. 앞 fragment의 끝(시작 시각 + 길이)과 다음 fragment의 시작 사이가 **30초 이하**면 같은 녹화로 이어 붙이고, 그보다 벌어지면 새 녹화로 나눕니다. 장비가 잠깐 끊겼다 다시 붙은 정도의 틈은 하나로 봅니다.
4. 가장 최근 녹화 **12개**만 보여 줍니다.
5. 녹화 하나를 누르면 그 시작부터 끝까지를 `ON_DEMAND`로 재생합니다. 마지막 녹화가 아직 이어지는 중이면 끝을 지금 시각으로 잡습니다. 서버 시각 기준의 끝 시각은 과거여야 하기 때문입니다.
6. 6시간보다 오래된 영상은 **"이 시각부터 보기"**로 봅니다. 사용자가 고른 시각부터 **30분**(지금을 넘지 않게)을 재생합니다.

이 규칙에는 서로 부딪히는 곳이 두 군데 있습니다. 적용하기 전에 알아 둘 점입니다.

- **1번의 쪽 수 상한과 4번의 "가장 최근 12개".** `ListFragments`는 쪽을 넘어서도 순서가 없어서, 가장 최근 fragment가 마지막 쪽에 올 수도 있습니다. 상한 때문에 뒤쪽을 버리면 받은 것만 정렬해도 전체에서 가장 최근 12개라는 보장이 깨지고, 녹화 한 덩어리가 중간에 끊겨 보일 수도 있습니다. 그래서 상한에 닿았다면 목록을 "일부만 받은 결과"로 표시하고 최신 보장을 하지 않거나, 처음부터 짧은 최근 범위(예: 최근 1시간)를 쪽이 끝날 때까지 다 받은 뒤 필요할 때 범위를 넓히는 편이 정확합니다.
- **5번의 "시작부터 끝까지"와 fragment 개수 상한.** `ON_DEMAND` 목록에는 `MaxMediaPlaylistFragmentResults`(기본 1,000, 최대 5,000)만큼의 fragment만 앞에서부터 담깁니다. 1초 fragment라면 5,000개는 80분 남짓이라, 6시간 안의 연속 녹화가 그보다 길면 한 번에 끝까지 담을 수 없습니다. 그런 녹화는 구간을 나눠 재생하거나 `LIVE_REPLAY`를 씁니다.

재생 요청의 매개변수는 위 ③의 예시와 같고, 아래 표가 그때 고른 값입니다. ③ 예시의 `MaxMediaPlaylistFragmentResults`(2,000)는 30분 창이 기본 상한에 잘리지 않도록 이 글에서 덧붙인 값입니다. 직접 적용할 때는 재생할 구간 길이와 fragment 길이에 맞춰 정합니다.

| 매개변수 | 고른 값 | 이유 |
|---|---|---|
| `PlaybackMode` | `ON_DEMAND` | 지난 녹화를 재생 막대와 함께 본다. 목록은 한 번만 받는다 |
| `FragmentSelectorType` | `SERVER_TIMESTAMP` | 장비 시계에 기대지 않는다. 목록도 같은 기준으로 만들었다 |
| `ContainerFormat` | `FRAGMENTED_MP4` | 기본값이자 권장값. hls.js가 바꾸지 않고 바로 넣는다 |
| `DiscontinuityMode` | `ALWAYS` | 서버 시각의 작은 틈·겹침에 플레이어가 멈추거나 떨지 않게 한다. 30초 이하 틈을 이어 붙인 녹화도 끊김 표시 덕에 바로 이어 재생된다 |
| `DisplayFragmentTimestamp` | `ALWAYS` | 재생 위치를 서버 수신 기준 시각으로 보여 준다(`playingDate`) |
| `Expires` | `3600` | 30분 창을 정상 속도로 볼 때를 가정한 값이다. 1시간보다 긴 녹화나 오래 멈춰 두는 경우에는 새로 받거나 구간을 나눠야 한다. 재생할 때마다 새로 받는다 |

### 3. CSP의 media-src에 blob:과 KVS 주소

5편에서 다룬 것처럼 이 대시보드는 CSP(Content Security Policy)로 페이지가 열 수 있는 주소를 제한합니다. 실시간 영상은 WebRTC 스트림을 `video.srcObject`로 붙이므로 주소를 열지 않았고, `media-src`를 신경 쓸 일이 없었습니다. 다시 보기는 다릅니다. 앞의 두 재생 길이 각각 다른 지시어에 걸립니다.

- [`connect-src`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/connect-src)는 `fetch`·XHR처럼 스크립트가 여는 주소를 제한합니다. hls.js가 재생 목록과 조각을 받는 요청이 여기 걸립니다. KVS API 호출 때문에 이미 KVS 주소가 들어 있어서 추가할 것이 없었습니다.
- [`media-src`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/media-src)는 `<audio>`·`<video>`가 불러오는 주소를 제한합니다. 따로 정하지 않으면 `default-src`를 따릅니다. hls.js 길에서는 `<video>`가 `blob:` 주소를 열고, 자체 HLS 길에서는 `<video>`가 KVS 주소를 직접 엽니다.

그래서 이렇게 넣었습니다(리전은 예시 자리표시).

```text
media-src 'self' blob: https://*.kinesisvideo.<region>.amazonaws.com
```

`blob:`이 없으면 hls.js가 만든 `blob:` 주소를 `<video>`에 붙이는 순간 CSP가 막습니다. 우리 경우에는 `blob:`을 따로 넣어야 했고, 넣은 뒤 다시 보기 동안 CSP 위반 보고는 0건이었습니다. KVS 주소는 MSE가 없는 Safari가 자체 HLS로 재생 목록을 열 때를 위한 것입니다. 다만 그 길(MSE 없는 Safari)에서 실제로 재생해 보지는 못했습니다.

### 4. 재생 주소는 권한이다

그림의 점선 아래를 다시 보겠습니다. 재생 주소에는 세션 토큰이 들어 있고, 플레이어는 서명 없이 그 토큰만으로 영상을 받습니다. 바꿔 말하면 **주소를 가진 사람은 누구든 만료 전까지 그 구간을 볼 수 있습니다.** KVS 문서도 이 토큰을 공유하거나 저장하지 말고, AWS 자격 증명과 같은 수준으로 보호하라고 적습니다.

그래서 이렇게 다뤘습니다.

- 재생 주소를 콘솔 로그, 오류 보고, 화면, 저장소(localStorage 등) 어디에도 남기지 않습니다.
- 재생할 때마다 새로 받습니다. 지난 주소를 다시 쓰지 않습니다.
- 서비스 워커가 KVS 응답을 캐시하지 않게 했습니다. 캐시에 남으면 주소와 영상 조각이 브라우저 저장소에 남기 때문입니다.

재생 주소를 받기까지의 단계는 IAM 권한으로 막습니다. 브라우저의 임시 자격 증명 역할에는 읽기 권한만 줍니다. 아래는 이 글을 위해 새로 쓴 예시이고 실행 미확인입니다. `DescribeStream`은 스트림 정보를 읽을 때(예: 녹화 스트림이 있는지 확인) 씁니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReplayReadOnly",
      "Effect": "Allow",
      "Action": [
        "kinesisvideo:DescribeStream",
        "kinesisvideo:GetDataEndpoint",
        "kinesisvideo:ListFragments",
        "kinesisvideo:GetHLSStreamingSessionURL"
      ],
      "Resource": "arn:aws:kinesisvideo:<region>:<account-id>:stream/device-a-recording/*"
    }
  ]
}
```

`PutMedia` 같은 쓰기 권한도, 다른 스트림 권한도 없습니다. 역할을 가진 사람도 이 스트림의 영상을 꺼내 볼 수만 있습니다.

### 5. 다시 보기는 운영자 화면에만

대시보드에는 운영자 화면과 고객 화면이 있습니다. 다시 보기는 운영자 화면에만 넣고, 고객 화면에는 실시간 영상만 둡니다.

다만 정직하게 적으면, 이것은 **화면 구성으로 나눈 것이지 권한으로 막은 것은 아닙니다.** 같은 IAM 역할을 쓰기 때문에, 고객 계정으로 로그인한 사람이 운영자 화면으로 바꾸면 다시 보기도 볼 수 있습니다. 권한으로 막으려면 고객용 역할에서 위 권한을 빼야 합니다. 이 부분은 지금 상태 그대로 남아 있습니다.

## 로컬에서는 되는데 배포본에서만 "스트림 없음"

두 번째 문제로 돌아갑니다. 내 컴퓨터에서 띄운 대시보드에서는 다시 보기가 잘 되는데, 배포한 사이트에서는 다시 보기를 열자마자 "스트림 없음"이 떴습니다.

원인은 코드가 아니라 **설정 파일**이었습니다. 대시보드는 장비 목록, 신호 채널 이름, 녹화 스트림 이름 같은 값을 설정 파일에서 읽는데, 이 설정 파일을 만드는 생성기가 쓰임마다 따로 있었습니다(로컬용, 배포용 등 세 곳). 녹화 스트림 이름은 녹화를 켠 장비에만 있는 **선택 필드**였습니다. 그런데 배포용 생성기는 필수 필드만 골라 옮기고 있었고, 그 과정에서 녹화 스트림 필드가 조용히 빠졌습니다. 다시 보기는 그 필드가 없으면 "이 장비에는 녹화가 없다"고 판단하니 "스트림 없음"이 뜬 것입니다.

고친 것은 둘입니다.

- 배포용 생성기도 선택 필드를 값이 있으면 그대로 옮기게 했습니다.
- 세 생성기에 같은 입력을 주고 결과를 비교하는 시험을 넣었습니다. 한 생성기에 필드를 추가하고 다른 생성기를 잊으면 시험이 깨집니다.

교훈은 이렇습니다. "로컬에서는 되는데 배포에서만 안 된다"면 코드보다 **배포 과정이 만들어 내는 입력**(설정 파일, 환경 변수, 빌드 결과)을 먼저 의심합니다. 특히 필수가 아닌 값은 빠져도 오류가 나지 않아서, 증상이 "없음"처럼 정상 상태와 구별이 안 되는 모양으로 나타납니다.

## 확인한 것

- Chrome에서 hls.js 길로 다시 보기가 재생되었습니다.
- 이 시험에서는 화면에 띄운 시각(`playingDate`, 곧 재생 목록의 Program Date Time)이 영상 속에 찍힌 시계와 일치했습니다. 다만 여기서 표시하는 값은 `SERVER_TIMESTAMP` 기준, 곧 KVS가 받은 시각입니다. 촬영 시각과의 차이는 전송 지연이나 보내는 쪽 버퍼링에 따라 달라질 수 있어서, 이 관찰이 촬영 시각을 언제나 정확히 보여 준다는 뜻은 아닙니다.
- 다시 보기 동안 CSP 위반 보고는 0건이었습니다.
- 서명 없이 `GetDataEndpoint`를 부르면 403이 돌아왔습니다. 점선 위 단계는 자격 증명 없이는 넘을 수 없습니다.
- MSE가 없는 Safari(자체 HLS 길)에서는 시험하지 못했습니다.

## 주의할 점

**`canPlayType`의 "maybe"를 "된다"로 읽지 않습니다.** "maybe"는 해 봐야 안다는 뜻입니다. 재생 길은 MSE(`MediaSource`, `ManagedMediaSource`)와 `Hls.isSupported()`로 hls.js를 쓸 수 있는지 먼저 보고, `canPlayType`은 hls.js를 쓸 수 없을 때의 판단에만 씁니다.

**`ListFragments` 결과는 정렬되어 오지 않습니다.** 쪽을 넘어서도 순서가 없습니다. "가장 최근"이나 "연속 구간"을 말하려면 그 범위의 쪽을 끝까지 다 받은 뒤 정렬해야 합니다. 쪽 수에 상한을 두었다면 상한에 닿은 결과는 일부일 수 있다고 보고 다룹니다. 방금 들어온 fragment는 1초쯤 늦게 보일 수 있습니다.

**재생 구간에는 한도가 있습니다.** `TimestampRange`는 24시간 안쪽이어야 하고, 서버 시각 기준이면 끝이 과거여야 합니다. 구간에 fragment가 없으면 404가 오니, "녹화 없음"으로 바꿔 보여 줄 준비를 합니다.

**`ON_DEMAND` 재생 목록에는 fragment 개수 상한이 있습니다.** `MaxMediaPlaylistFragmentResults` 기본값은 1,000, 최댓값은 5,000입니다. fragment 길이 × 개수보다 긴 구간을 요청하면 앞쪽의 오래된 fragment부터 상한만큼만 담기고 목록이 거기서 끝납니다. 구간 길이(이 글에서는 30분 창)를 정할 때 fragment 길이를 함께 보고, 필요하면 값을 올리거나, 5,000개를 넘는 구간은 나누거나 `LIVE_REPLAY`를 씁니다.

**재생 주소는 플레이어 하나에 하나입니다.** 문서는 세션 주소를 여러 플레이어가 나눠 쓰지 말라고 하고, 나눠 쓰면 KVS가 그 세션을 제한할 수 있다고 합니다. 세션당 요청 한도도 있습니다. 재생 목록은 초당 5회, 초기화 조각은 초당 5회, 미디어 조각은 초당 20회이고 늘릴 수 없습니다. 문서는 동시에 쓰는 세션 수 자체에는 한도가 없다고 하니, 재생할 때마다 새로 받는 편이 맞습니다. 다만 이것이 시청자 수에 한도가 없다는 뜻은 아닙니다. 세션 발급(`GetHLSStreamingSessionURL`)은 스트림당 초당 25회이고, 모든 세션과 다른 API가 스트림 단위 할당량을 함께 씁니다. 조각을 받는 쪽(fragment-media)은 스트림당 초당 500점, 재생 목록·`ListFragments` 같은 메타데이터 쪽은 초당 10,000점입니다. 문서도 이 때문에 재생 앱이 한 스트림에 너무 많은 세션을 동시에 쓰지 않게 하라고 적습니다.

**`Expires` 기본값은 5분입니다.** 값을 정하지 않으면 5분 뒤에 새 조각을 못 받아 재생이 멈춥니다. 보려는 구간보다 넉넉하게 잡되, 주소가 권한이라는 점을 생각해 필요 이상으로 길게 두지 않습니다. 사용자가 중간에 오래 멈춰 두거나 긴 녹화를 이어 보면 만료를 넘길 수 있으니, 그때는 주소를 새로 받아 이어 붙이거나 구간을 나눕니다.

**CSP에 `blob:`을 잊지 않습니다.** hls.js는 `<video>`에 `blob:` 주소를 붙입니다. `media-src`에 `blob:`이 없으면 재생 목록과 조각은 다 받아 놓고 `<video>`에서 막힙니다. 자체 HLS 길을 쓴다면 KVS 주소도 `media-src`에 필요합니다.

**fragment 길이는 인코더의 키프레임 간격이 정합니다.** 너무 짧으면(1초 미만) 플레이어가 제한될 수 있고, 너무 길면 건너뛰기가 거칠어지고 실시간 지연이 늘어납니다. 보내는 쪽의 키프레임 설정을 함께 봅니다.

**세션 중 트랙 구성은 바뀌면 안 됩니다.** 문서에 따르면 HLS 세션은 트랙 변경(예: 오디오가 중간에 생기거나 사라짐)을 지원하지 않습니다. 코덱 설정 변경은 세션당 500번까지 허용됩니다.

**꺼내 보는 데도 요금이 듭니다.** `GetHLSStreamingSessionURL`로 받는 데이터는 과금 대상입니다. 단가는 [KVS 요금 페이지](https://aws.amazon.com/kinesis/video-streams/pricing/)에서 확인합니다.

## 정리

- 다시 보기는 지연보다 **되감기와 건너뛰기**가 중요해서 WebRTC가 아니라 HLS가 맞습니다.
- HLS는 **조각**과, 조각 주소를 적은 텍스트 **재생 목록(.m3u8)**뿐입니다. 플레이어는 목록을 받아 조각을 HTTP로 차례로 받아 이어 붙입니다. `TARGETDURATION`은 조각 길이 상한, `EXTINF`는 다음 조각 길이, `PROGRAM-DATE-TIME`은 미디어 시각과 절대 시각의 연결, `DISCONTINUITY`는 끊김, `ENDLIST`는 끝입니다.
- KVS는 녹화를 fragment로 저장하고, `GetDataEndpoint` → `GetHLSStreamingSessionURL`로 재생 주소를 내어 줍니다. 녹화 목록이 필요한 화면은 그 사이에 `ListFragments`를 씁니다. 그 뒤 플레이어는 서명 없이 **주소 속 토큰**만으로 영상을 받습니다.
- 브라우저는 자체 HLS 또는 **MSE 위의 hls.js**로 재생합니다. `canPlayType`의 "maybe"는 "해 봐야 안다"는 뜻이라 길을 고르는 근거가 될 수 없고, hls.js를 쓸 수 있으면(`Hls.isSupported()`) hls.js를 먼저 씁니다.
- hls.js는 `<video>`에 `blob:` 주소를 붙이므로 CSP `media-src`에 `blob:`이 필요합니다.
- 재생 주소는 만료 전까지 쓸 수 있는 **권한**이라 기록·저장·캐시하지 않고 재생마다 새로 받습니다.

## 시리즈를 마치며

일곱 편에 걸쳐 영상 하나가 현장 장비에서 브라우저까지 가는 길을 따라왔습니다. 1편에서 영상은 서버에서 땡겨 오는 것이 아니라 두 쪽이 만나서 직접 흐른다는 큰 그림을 잡았고, 2편에서 그 만남을 주선하는 시그널링(SDP offer/answer와 KVS 신호 채널)을 보았습니다. 3편과 4편에서는 NAT 때문에 두 기기가 바로 붙지 못하는 이유와, STUN으로 바깥 주소를 알아내고 끝내 안 되면 TURN으로 중계하는 ICE의 원리를 따라갔습니다. 5편에서 그 길 위의 영상을 DTLS-SRTP가 어떻게 암호화하는지와 브라우저 CSP를, 6편에서 같은 WebRTC 영상을 KVS 스트림에 녹화하는 방법을 다뤘고, 이 글에서 그 녹화를 HLS로 다시 꺼내 보았습니다.

RTSP를 쓰는 IP 카메라 영상을 다시 압축하지 않고 그대로 보내는 이야기는 해결되면 따로 쓰겠습니다.

## 참고

- [RFC 8216: HTTP Live Streaming](https://www.rfc-editor.org/rfc/rfc8216)
- [RFC 8835: Transports for WebRTC](https://www.rfc-editor.org/rfc/rfc8835.html)
- [RFC 8834: Media Transport and Use of RTP in WebRTC](https://www.rfc-editor.org/rfc/rfc8834.html)
- [Amazon Kinesis Video Streams: 재생 요구 사항](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/video-playback-requirements.html)
- [hls.js 1.7.4 README](https://github.com/video-dev/hls.js/blob/v1.7.4/README.md), [is-supported.ts](https://github.com/video-dev/hls.js/blob/v1.7.4/src/is-supported.ts)
- [Amazon Kinesis Video Streams: Play back video with HLS](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/hls-playback.html)
- [GetHLSStreamingSessionURL API](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_reader_GetHLSStreamingSessionURL.html)
- [HLSTimestampRange](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_reader_HLSTimestampRange.html)
- [ListFragments API](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_reader_ListFragments.html)
- [GetDataEndpoint API](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_GetDataEndpoint.html)
- [Kinesis Video Streams 할당량](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/limits.html)
- [MDN: HTMLMediaElement.canPlayType()](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/canPlayType)
- [MDN: Media Source Extensions API](https://developer.mozilla.org/en-US/docs/Web/API/Media_Source_Extensions_API)
- [MDN: ManagedMediaSource](https://developer.mozilla.org/en-US/docs/Web/API/ManagedMediaSource)
- [MDN: CSP media-src](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/media-src)
- [hls.js](https://github.com/video-dev/hls.js), [hls.js API 문서](https://github.com/video-dev/hls.js/blob/master/docs/API.md)
- [hls.js 이슈 #7827: Chrome의 canPlayType "maybe"와 자체 HLS 재생 실패](https://github.com/video-dev/hls.js/issues/7827)
