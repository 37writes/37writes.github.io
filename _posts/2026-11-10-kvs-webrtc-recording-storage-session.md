---
title: "KVS WebRTC 녹화: 저장 세션을 켜면 연결 구조가 바뀐다"
date: 2026-11-10 10:25:00 +0900
categories: [AWS, 영상 스트리밍]
tags: [aws-concepts, aws, kvs, webrtc, kinesis-video-streams, recording, storage-session]
description: "KVS WebRTC 수집으로 녹화를 켜면 저장 세션이 WebRTC 상대로 들어와 offer 방향, 시청자 한도(10명→3명), 장비 업링크, ClientId 전략이 바뀝니다. 공식 문서 기준 원리와 30초마다 끊기던 녹화를 25초 규칙으로 고친 사례를 정리합니다."
---

> **시리즈: AWS KVS로 실시간 영상 보내기**
> 1. KVS 큰 그림: 영상은 '땡겨오는' 게 아니라 만나서 흐른다
> 2. 시그널링: SDP offer/answer와 KVS 신호 채널
> 3. NAT와 STUN: 왜 두 기기는 바로 못 붙나
> 4. TURN과 ICE: 끝내 못 붙으면 중계한다
> 5. 암호화와 브라우저 보안: DTLS-SRTP, 그리고 CSP
> 6. **녹화: KVS WebRTC 수집과 저장 세션** ← 지금 글
> 7. 다시 보기: HLS 원리와 KVS 재생

현장 장비(카메라가 달린 원격 장비)의 영상을 관제 웹 대시보드에서 실시간으로 보는 기능을 AI 에이전트와 같이 만들었습니다. 실시간 영상은 Amazon Kinesis Video Streams(KVS)의 WebRTC 기능으로 보냈고, 장비와 브라우저가 신호 채널에서 만나 영상을 직접 주고받는 구조였습니다. 그다음 요구가 녹화였습니다. "지난주 시험을 다시 볼 수 있게 해 달라"는 것이었습니다.

녹화는 KVS의 **WebRTC 수집(ingestion)** 기능으로 붙였습니다. 신호 채널을 영상 스트림에 이어 두기만 하면 KVS가 알아서 녹화해 준다고 해서 간단해 보였습니다. 그런데 켜고 나니 예상하지 못한 일이 두 가지 생겼습니다.

첫째, 녹화를 켠 뒤에 이런 질문을 하게 됐습니다.

> 녹화를 끄면 몇 명까지 볼 수 있어?

녹화를 켜고 끄는 일이 **동시에 볼 수 있는 사람 수**를 바꾼다는 것이 낯설었습니다. 녹화는 저장의 문제이고, 시청은 실시간 연결의 문제라고 생각했기 때문입니다.

둘째, 다시 보기 목록에 **30초 남짓한 짧은 녹화만 줄줄이** 생겼습니다. 카메라는 계속 켜져 있었는데 녹화는 거의 남지 않았습니다.

두 일의 뿌리는 같았습니다. 녹화를 켜면 **KVS 쪽 서버(저장 세션)가 WebRTC 참가자로 들어오면서 연결 구조 자체가 바뀝니다.** 이 글은 그 구조를 공식 문서 기준으로 기초부터 정리합니다. 녹화 방법 세 가지를 비교하고, 저장 세션이 무엇이고 무엇이 뒤집히는지(offer 방향, 시청자 한도, 업링크, ClientId)를 짚은 뒤, 30초마다 끊기던 녹화를 고친 과정과 상대가 AWS 서버일 때 요구되는 조건, 보관 기간과 저장량까지 다룹니다.

## 앞 편 요약: 녹화를 켜기 전의 연결

이 글만 읽어도 이해되도록, 앞 편에서 다룬 직접 연결(peer-to-peer)을 짧게 다시 정리합니다.

- **신호 채널(signaling channel)**: 장비와 브라우저가 서로를 찾고 연결 조건을 주고받는 KVS의 WebSocket 중개소입니다. 영상은 여기로 흐르지 않습니다. 장비는 **마스터(master)**로, 브라우저는 **뷰어(viewer)**로 접속합니다.
- **SDP offer/answer**: 연결을 원하는 쪽이 "나는 이런 코덱과 이런 암호화 지문으로 받을 수 있다"는 제안(offer)을 보내고, 상대가 받아들일 조건(answer)으로 답합니다. 직접 연결에서는 **뷰어가 offer**를 보내고 마스터가 answer를 보냅니다.
- **NAT**: 공유기나 이동통신망 장비가 안쪽 기기의 주소·포트를 바깥 주소·포트로 바꿔 내보내는 장치입니다. 그래서 기기는 자기가 바깥에서 어떤 주소로 보이는지 모릅니다. **STUN** 서버는 그 바깥 주소를 알려 주고, **TURN** 서버는 직접 통하지 않을 때 패킷을 대신 날라 줍니다. 자세한 내용은 3편(NAT와 STUN)과 4편(TURN과 ICE)에서 다룹니다.
- **ICE 후보(candidate)**: "나에게 닿을 수 있는 주소" 목록입니다. 내 기기 주소(host), NAT 바깥에서 보이는 주소(srflx, STUN으로 알아냄), 중계 서버 주소(relay, TURN 서버가 내줌)가 있습니다. 양쪽이 후보를 주고받아 실제로 통하는 쌍을 고릅니다.
- **DTLS-SRTP**: 연결이 붙으면 DTLS 핸드셰이크로 키를 만들고, 그 키로 영상 패킷(SRTP)을 암호화합니다. 키는 **연결마다 따로** 만들어집니다.

마지막 점이 이 글의 출발점입니다. 직접 연결에서 장비는 뷰어마다 `RTCPeerConnection`을 하나씩 만듭니다. 연결마다 키가 다르니, 같은 장면이라도 **뷰어마다 따로 암호화해서 따로 보냅니다.** TURN 중계를 거쳐도 마찬가지로 연결마다 중계 자리를 따로 씁니다. 그래서 시청자가 셋이면 장비의 업로드도 세 줄이 됩니다.

## 녹화하는 방법 세 가지

KVS에는 성격이 다른 두 리소스가 있습니다. 하나는 위의 **신호 채널**(실시간 WebRTC용)이고, 다른 하나는 **영상 스트림(Kinesis video stream)**입니다. 영상 스트림은 영상을 조각(fragment) 단위로 받아 정해진 기간 동안 보관하고, HLS·DASH 재생이나 이미지 추출 같은 API로 다시 꺼내 보게 해 주는 저장소입니다. HLS는 재생 목록(playlist) 파일과 몇 초짜리 영상 조각들을 HTTP로 차례로 받아 이어 붙여 재생하는 방식이고, 7편에서 자세히 다룹니다. 녹화란 결국 "영상이 스트림에 들어가게 만드는 것"이고, 넣는 길이 여러 가지입니다.

| 안 | 어떻게 | 장점 | 버린 이유 / 고른 이유 |
|---|---|---|---|
| ① **WebRTC 수집** (고름) | 신호 채널을 스트림에 연결해 두면, KVS의 저장 세션이 장비의 WebRTC 영상을 받아 스트림에 저장하고 뷰어에게도 실시간으로 나눠 줌 | 기존 WebRTC 송출 경로를 활용함. 다만 저장 세션용 join·시그널링 처리(`senderClientId` 없는 메시지, trickle ICE, DTLS 암호 묶음)와 코덱·소리 트랙 조건을 더해야 함. 업링크 한 줄. 아무도 안 봐도 녹화됨 | 장비 하드웨어와 상관없이 같은 방식이라 고름 |
| ② 장비가 스트림에 따로 올림 (`PutMedia`, Producer SDK나 GStreamer `kvssink`) | 실시간용 WebRTC 연결과 별개로, 녹화용 업로드를 하나 더 둠 | 스트림 쪽 기능을 그대로 씀 | 녹화용 업로드가 하나 더 붙음(직접 연결 시청자가 N명이면 업로드 N개 → N+1개). 당시 검토한 구현에서는 별도 인코딩 경로와 C/C++ SDK 빌드·통합 부담이 있었고, 장비 하드웨어에 따라 방법이 달라짐 |
| ③ 브라우저가 받은 영상을 녹화 (`MediaRecorder` → S3) | 보고 있는 브라우저가 녹화해서 올림 | 서버 쪽 추가 구성이 적어 보임 | **아무도 안 보면 녹화가 안 됨.** 보는 사람마다 중복되고, 새 저장 권한도 필요 |

②의 `PutMedia`는 스트림에 미디어를 직접 올리는 API이고, `kvssink`는 그 API를 쓰는 GStreamer 요소입니다. 이름 때문에 헷갈리기 쉬운데, `kvssink`는 **스트림용**이지 WebRTC용이 아닙니다. 그래서 실시간과 녹화를 둘 다 하려면 장비가 WebRTC 연결과 스트림 업로드로 **같은 영상을 따로 한 번 더 내보내야** 합니다.

여기서 "한 번 더 보낸다"와 "한 번 더 인코딩한다"는 다른 이야기입니다. AWS의 `kvssink` 공식 예제에는 카메라가 이미 H.264로 압축해 내보내는 영상을 다시 인코딩하지 않고(`h264parse`만 거쳐) 그대로 스트림에 넣는 예가 있고, GStreamer의 `tee` 요소로 인코딩 결과 하나를 두 출력으로 나눌 수도 있습니다. 그러니 인코딩이 꼭 두 배가 되는 것은 아닙니다. 다만 업로드는 확실히 하나 더 붙습니다. 직접 연결 시청자가 2명이면 업로드는 2개에서 3개가 되고, 아무도 안 볼 때도 녹화용 1개는 늘 나갑니다.

현장 장비는 이동통신망이나 현장 Wi-Fi로 붙는 경우가 많아 업링크가 가장 귀한 자원이었고, 당시 검토한 구성에서는 C/C++ SDK를 장비마다 빌드해 붙이는 부담도 컸기 때문에 ②는 맞지 않았습니다. ③은 "녹화"의 목적 자체와 어긋났습니다. 그래서 ①을 골랐습니다.

## 저장 세션이란

### 비유: 방송국의 녹화실 겸 중계차

녹화를 켜기 전의 신호 채널은 소개팅 주선자와 비슷합니다. 연락처만 이어 주고, 대화(영상)는 두 사람이 직접 합니다. 녹화를 켜면 그 사이에 **방송국의 녹화실 겸 중계차**가 들어옵니다. 장비는 중계차 한 대에만 영상을 보내고, 중계차는 그 영상을 테이프(스트림)에 녹화하면서 보러 온 사람들에게 나눠 줍니다.

### 실제 동작

비유를 걷어 내고 실제로 일어나는 일을 보면 이렇습니다.

1. **신호 채널과 스트림을 잇습니다.** `UpdateMediaStorageConfiguration` API에 채널 ARN과 스트림 ARN, `Status: ENABLED`를 넘깁니다. 공식 API 문서는 이 상태가 되면 "**직접(master-viewer) peer-to-peer 연결은 더 이상 일어나지 않고**, 참가자는 저장 세션에 직접 연결한다"고 적고 있습니다. 녹화를 켜는 일이 연결 구조를 바꾸는 이유가 바로 이 문장입니다.
2. **저장 세션(storage session)**은 AWS 망 안에 있는 WebRTC 참가자입니다. 마스터(장비)와도, 뷰어(브라우저)와도 각각 WebRTC 연결을 맺습니다. 브라우저 입장에서는 상대가 장비가 아니라 AWS의 서버로 바뀝니다.
3. 저장 세션은 마스터에게서 **H.264 영상과 Opus 소리**를 받아 스트림에 **H.264 영상과 AAC 소리**로 저장합니다(`JoinStorageSession` API 문서).
4. 같은 영상을 연결된 뷰어들에게 실시간으로 복제해서 보냅니다. 공식 문서 표현으로는 "저장 세션이 미디어를 섞고, 복제하고, 알맞은 목적지로 보낸다"입니다.
5. 뷰어도 소리 트랙을 보낼 수 있습니다(선택). 저장 세션은 뷰어들의 소리를 섞어 마스터와 다른 뷰어에게 보내고, 마스터가 연결돼 있는 동안에는 그 소리도 스트림에 함께 저장합니다. 뷰어는 영상 트랙을 보낼 수 없습니다.

정리하면 저장 세션은 "녹화기"와 "중계 서버(SFU처럼 받아서 나눠 주는 서버)"를 겸하는 WebRTC 참가자입니다. 녹화를 켜는 순간 장비와 브라우저는 서로가 아니라 이 참가자와 연결합니다.

### 준비: 채널, 스트림, 권한, 연결

공식 안내서의 순서는 신호 채널 만들기 → 스트림 만들기 → 권한 주기 → 연결(목적지 설정)입니다. 몇 가지 조건이 있습니다.

- 스트림의 **보관 기간(data retention)이 0보다 커야** 합니다. 최소 1시간입니다. 보관 기간 0인 스트림은 데이터를 저장하지 않기 때문입니다.
- 마스터 역할에는 채널 쪽 `ConnectAsMaster`, `GetSignalingChannelEndpoint`, `GetIceServerConfig`, `DescribeMediaStorageConfiguration`, `JoinStorageSession` 외에 **스트림 쪽 `DescribeStream`, `GetDataEndpoint`, `PutMedia`**도 필요합니다. 장비가 `PutMedia`를 직접 부르지는 않지만 권한은 있어야 합니다(공식 권한 안내). 뷰어 역할도 스트림 쪽 같은 세 권한이 필요하다고 적혀 있습니다.
- 연결 설정은 지금 콘솔에서 할 수 없고 CLI나 SDK로 합니다.
- 계정당 저장 설정을 켠 신호 채널은 **최대 100개**입니다(미디어 수집 안내).
- 채널이나 스트림을 지우려면 **먼저 연결을 끊어야** 합니다. 연결을 끊으면(`Status: DISABLED`) 직접 연결이 다시 됩니다.

CLI로 하면 이런 모양입니다. 신호 채널은 이미 있고(직접 연결 때 쓰던 채널) 그 ARN을 환경 변수 `CHANNEL_ARN`에 넣어 두었다고 가정합니다. 한 줄씩 손으로 치기보다 스크립트 파일로 저장해 실행하는 형태입니다(실행 미확인, 공식 문서의 명령 형식을 따라 새로 쓴 예시).

```sh
#!/bin/sh
set -eu
REGION=ap-northeast-2                     # 예시 리전
STREAM_NAME=device-a-recording            # 예시 이름
: "${CHANNEL_ARN:?CHANNEL_ARN을 먼저 넣어 주세요}"   # 비어 있으면 여기서 멈춤

# 1) 보관 기간 7일(168시간) 스트림을 만들고 ARN을 받아 둔다
STREAM_ARN=$(aws kinesisvideo create-stream \
  --stream-name "$STREAM_NAME" \
  --data-retention-in-hours 168 \
  --query StreamARN --output text \
  --region "$REGION")
: "${STREAM_ARN:?스트림 ARN을 받지 못함}"

# 2) 스트림이 ACTIVE가 될 때까지 확인 (만드는 중이면 연결이 거절된다)
#    조회 자체가 실패하면 바로 끝내고, CREATING은 최대 30회 × 2초만 기다린다
tries=0
while :; do
  stream_status=$(aws kinesisvideo describe-stream \
    --stream-arn "$STREAM_ARN" \
    --query StreamInfo.Status --output text \
    --region "$REGION") || { echo "스트림 조회 실패" >&2; exit 1; }
  case "$stream_status" in
    ACTIVE) break ;;
    CREATING)
      tries=$((tries + 1))
      [ "$tries" -lt 30 ] || { echo "60초 안에 ACTIVE가 되지 않음" >&2; exit 1; }
      sleep 2 ;;
    *) echo "예상하지 못한 상태: $stream_status" >&2; exit 1 ;;
  esac
done

# 3) 신호 채널을 스트림에 연결 (녹화 켜기)
aws kinesisvideo update-media-storage-configuration \
  --channel-arn "$CHANNEL_ARN" \
  --media-storage-configuration StreamARN="$STREAM_ARN",Status=ENABLED \
  --region "$REGION"

# 4) 지금 상태 확인 (장비와 웹이 모드를 고를 때도 이 API를 부른다)
aws kinesisvideo describe-media-storage-configuration \
  --channel-arn "$CHANNEL_ARN" --region "$REGION"
```

2번의 확인을 넣은 이유는 `UpdateMediaStorageConfiguration`이 채널이나 스트림이 활성(Active) 상태가 아니면 `ResourceInUseException`으로 거절하기 때문입니다. 스트림을 막 만든 직후에는 아직 만드는 중일 수 있습니다. 조회 명령을 반복 조건(`until [ "$(aws …)" = ACTIVE ]`) 안에 넣으면, 권한 오류나 자격 증명 만료로 조회가 실패해도 `set -e`가 스크립트를 끝내지 않고 빈 결과로 계속 돕니다. 그래서 조회 실패, 만드는 중(`CREATING`), 그 밖의 상태를 따로 나눠 처리했습니다.

장비와 웹 쪽 코드는 연결 여부를 하드코딩하지 않고, 접속할 때마다 `DescribeMediaStorageConfiguration`을 불러 "녹화 모드인지 직접 모드인지"를 골랐습니다. 그래서 백엔드에서 연결을 끊고 배포하면 양쪽이 저절로 직접 연결로 돌아갑니다.

## offer를 보내는 쪽이 뒤집힌다

녹화를 켜고 가장 먼저 코드가 바뀌어야 했던 곳이 offer 방향입니다.

| | 직접 연결 | 저장 세션 경유 |
|---|---|---|
| offer를 보내는 쪽 | **뷰어** | **저장 세션(KVS)** |
| 마스터가 하는 일 | 뷰어의 offer에 answer | `JoinStorageSession`을 부르고, 저장 세션의 offer에 answer |
| 뷰어가 하는 일 | offer를 만들어 보냄 | `JoinStorageSessionAsViewer`를 부르고, 저장 세션의 offer에 answer |
| ICE에서의 역할 | 뷰어가 controlling | 저장 세션이 controlling, 마스터·뷰어 모두 controlled |

ICE(RFC 8445)에서 두 참가자 중 한쪽은 **controlling**, 다른 쪽은 **controlled** 역할을 맡습니다. controlling 쪽이 통하는 후보 쌍 가운데 실제로 쓸 쌍을 최종 지명(nominate)합니다. KVS 문제 해결 안내는 "직접 연결에서는 뷰어가 offer를 보내는 controlling 쪽이고, 저장 세션에 연결할 때는 **저장 세션이 controlling 쪽**이 된다. 마스터는 그대로 controlled이고, **뷰어는 controlling에서 controlled로 바뀐다**"고 설명합니다.

흐름을 단계로 나누면 이렇습니다.

**장비(마스터)**
1. `GetSignalingChannelEndpoint`로 엔드포인트를 받습니다. 이때 프로토콜 목록에 `WSS`, `HTTPS`와 함께 **`WEBRTC`**를 넣어야 합니다. `JoinStorageSession`은 이 `WEBRTC` 엔드포인트로 보내야 합니다.
2. 서명한 WSS 주소로 신호 채널에 마스터로 접속합니다(`ConnectAsMaster`).
3. `JoinStorageSession`을 부릅니다. 요청 본문은 채널 ARN 하나뿐이고, 성공하면 빈 200 응답이 옵니다.
4. 저장 세션이 **신호 채널을 통해** SDP offer와 ICE 후보를 보냅니다.
5. 장비가 answer와 ICE 후보로 답하고, 연결이 붙으면 영상과 소리를 보냅니다. 이때부터 스트림에 녹화가 쌓입니다.

**브라우저(뷰어)**
1. 같은 방식으로 `WEBRTC` 엔드포인트를 받고 뷰어로 접속합니다(`ConnectAsViewer`).
2. `JoinStorageSessionAsViewer`를 부릅니다. 본문은 채널 ARN과 **`clientId`**입니다.
3. 저장 세션이 이 뷰어에게 offer를 보냅니다. 브라우저는 answer를 만들어 돌려보냅니다.
4. 연결이 붙으면 저장 세션이 실시간 영상을 보냅니다.

직접 연결 코드를 고쳐 쓰는 입장에서 핵심은 "**뷰어가 offer를 만들지 않는다**"입니다. offer를 만드는 대신 join을 부르고 offer를 기다렸다가 답해야 합니다. 아래는 그 순서를 보여 주는 최소 예시입니다. `signaling`은 신호 채널 WebSocket을 감싼 객체, `api`는 서명한 KVS API 호출을 감싼 객체라고 가정했습니다(실행 미확인).

```js
// 저장 세션 모드의 뷰어: offer를 만들지 않고, join 뒤에 오는 offer에 답한다
async function watchViaStorageSession({ signaling, api, channelArn, clientId, iceServers, onTrack }) {
  const pc = new RTCPeerConnection({ iceServers });
  pc.ontrack = (e) => onTrack(e.streams[0]);

  // 저장 세션이 보낸 ICE 후보가 offer보다 먼저 도착할 수 있다 → offer 전까지 모아 둔다
  const pending = [];
  let gotOffer = false;
  signaling.on('ICE_CANDIDATE', async (cand) => {
    if (gotOffer) await pc.addIceCandidate(cand);
    else pending.push(cand);
  });

  // 내 후보는 찾는 대로 보낸다 (저장 세션은 trickle ICE를 요구한다)
  pc.onicecandidate = (e) => { if (e.candidate) signaling.send('ICE_CANDIDATE', e.candidate); };

  signaling.on('SDP_OFFER', async (offer) => {
    gotOffer = true;
    await pc.setRemoteDescription(offer);          // 영상(H.264)과 소리 줄이 이미 들어 있다
    for (const c of pending.splice(0)) await pc.addIceCandidate(c);
    await pc.setLocalDescription(await pc.createAnswer());
    signaling.send('SDP_ANSWER', pc.localDescription);
  });

  await signaling.open();                          // 뷰어로 신호 채널 접속
  await api.joinStorageSessionAsViewer({ channelArn, clientId }); // 이 호출이 offer를 부른다
  return pc;
}
```

직접 연결 때는 뷰어가 `addTransceiver('video', { direction: 'recvonly' })`로 받을 줄을 만들고 offer를 보냈습니다. 저장 세션 모드에서는 offer에 영상과 소리 줄이 이미 들어 있으므로 그 줄에 답하기만 하면 됩니다.

후보를 모아 두는 부분은 공식 문제 해결 안내가 직접 권하는 내용입니다. 저장 세션은 offer를 먼저 보내고 후보를 나중에 보내지만, 신호 메시지 전달이 비동기라서 **후보가 offer보다 먼저 도착할 수 있다**고 적혀 있습니다. 같은 안내는 KVS 예제 앱이 연결이 아직 없으면 후보를 대기 목록에 넣었다가, offer를 받아 연결을 만든 뒤 한꺼번에 넣는다고 설명합니다.

## 시청자 수와 업링크: "녹화를 끄면 몇 명까지 볼 수 있어?"

이제 처음 질문으로 돌아갑니다. 답은 "**녹화를 끄면 10명, 켜면 3명**"이고, 그 대신 장비 업링크의 모양이 정반대로 바뀝니다.

<figure class="diagram">
{% include figures/kvs-webrtc-recording-storage-session/direct-vs-storage-session.svg %}
<figcaption>녹화를 끄면 장비가 뷰어마다 따로 보내 업링크가 시청자 수만큼 늘고(채널당 10명, 늘리기 가능), 켜면 저장 세션 한 곳에만 보내 업링크는 한 줄이지만 시청자는 3명까지(늘릴 수 없음)</figcaption>
</figure>

KVS WebRTC [서비스 할당량](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-limits.html) 페이지에서 지금 값을 확인했습니다. 할당량 옆의 (s)는 늘리기를 요청할 수 있는 soft, (h)는 늘릴 수 없는 hard입니다.

| 항목 | 직접 연결 (`ConnectAsViewer`) | 저장 세션 (`JoinStorageSessionAsViewer`) |
|---|---|---|
| 동시 시청자 | 채널당 연결 **10 (s)** | 세션당 동시 클라이언트 **3 (h)** |
| 장비 업링크 | 비트레이트 × 시청자 수 | 비트레이트 × 1 (저장 세션 한 곳) |
| 아무도 안 볼 때 | 장비가 보내지 않음 | 카메라가 켜진 동안 계속 보냄(녹화) |

같은 페이지의 WebRTC 수집 할당량에는 이런 값도 있습니다.

- `JoinStorageSession`: 채널당 **2 TPS (h)**, 스트리밍 세션의 비트레이트 **1 Mbps (s)**, 세션 시간 **1시간 (h)**, 유휴 제한 3분 (h)
- `JoinStorageSessionAsViewer`: 채널당 2 TPS (h), 세션 시간 1시간 (h), 유휴 제한 1분 (h)

세션 비트레이트가 기본 1 Mbps라는 점은 화질을 정할 때 같이 봐야 합니다. 직접 연결의 TURN 중계 상한(5 Mbps, hard)과는 별개의 값입니다.

### 왜 이런 차이가 생기나

두 모드에서 누가 무엇을 하는지와 지금의 할당량을 나란히 놓으면 이렇습니다. 할당량 값이 이렇게 정해진 이유는 공식 문서에 적혀 있지 않으므로, 아래는 사실만 늘어놓은 것입니다.

- **직접 연결**: 신호 채널은 연결 조건만 이어 주고 영상은 나르지 않습니다. 장비가 뷰어마다 따로 암호화해 따로 보냅니다(업링크, 인코딩·암호화 부하를 장비가 짐). 앞에서 본 대로 연결마다 SRTP 키가 따로이니, 1 Mbit/s 영상을 세 명이 보면 장비는 약 3 Mbit/s를 올립니다. 현재 할당량은 채널당 뷰어 **10명(soft, 늘려 달라고 요청 가능)**입니다.
- **저장 세션 경유**: 장비는 저장 세션 한 곳에만 보내고, 뷰어에게 나눠 주는 일은 AWS 쪽 저장 세션이 합니다. 장비 업링크는 한 줄입니다. 현재 할당량은 세션당 뷰어 **3명(hard, 늘릴 수 없음)**입니다.

직접 연결에서 TURN을 거쳐도 AWS가 영상을 나눠 주는 것은 아닙니다. TURN 서버는 암호화된 패킷을 풀지 않고 그대로 넘겨 줄 뿐이고, 연결마다 중계 자리를 따로 씁니다. 저장 세션처럼 영상을 받아서 풀고 여러 곳으로 다시 보내는 것과는 다른 일입니다.

즉 녹화 여부를 정하는 순간 **영상을 여러 뷰어에게 나눠 보내는 일을 누가 하는지**가 바뀌고, 시청자 한도도 그 모드의 할당량을 따르게 됩니다. 질문이 낯설었던 이유가 여기에 있었습니다.

### 그때 한 결정: 한도 대응을 고르지 않고 남김

이 결정을 할 때는 동시 시청자 수를 알 수 없었습니다. 요구 사항을 물었을 때 돌아온 답이 "녹화는 필요하고, 동시 시청자 수는 지금은 모르겠다"였습니다. 그래서 한도를 넘을 때의 대응을 하나로 정하지 않고, 사람의 결정이 필요한 선택지로 남겨 두었습니다.

- (가) 그대로 둔다(녹화 채널은 3명).
- (나) 시청이 많은 장비만 녹화를 끄고 직접 연결로 보낸다(업링크가 시청자 수만큼 는다).
- (다) 녹화된 스트림을 HLS 실시간(LIVE) 재생으로 보여 준다(몇 초 늦고, 이때의 인원 한도는 확인하지 않았다).

코드에서는 자리가 다 차서 합류하지 못한 시청자에게 "지금 영상을 보는 사람이 많아 연결할 수 없다"는 안내를 보여 주게 했습니다. 다만 **4명을 실제로 동시에 붙여 보는 시험은 하지 않았습니다.** 3명 한도는 공식 문서가 근거이고, 4번째에게 보이는 화면은 코드로 추론한 것입니다.

## ClientId: 직접 연결과 정반대로 정한 이유

`ClientId`는 뷰어가 신호 채널에 접속할 때 쓰는 자기 이름입니다. 이 값을 어떻게 정할지가 직접 연결과 저장 세션에서 정반대가 됐습니다.

**직접 연결에서는 시도마다 새 ClientId**를 썼습니다. 앞 편에서 다룬 버그 때문입니다. 신호 채널은 아직 접속하지 않은 상대에게 갈 메시지를 채널의 메시지 TTL 동안 보관합니다. 같은 ID로 다시 접속한 뷰어가 이전 시도에 대한 오래된 answer를 받아 적용하는 바람에 연결이 실패했습니다. 시도마다 ID를 바꾸고, 내 offer보다 먼저 온 answer는 버리는 것으로 고쳤습니다.

**저장 세션에서는 한 번 보기 시작한 동안(start() 한 번) 같은 ClientId**를 씁니다. 근거는 `JoinStorageSessionAsViewer` API 문서의 이 내용입니다.

> 뷰어가 저장 세션에서 끊기면(피어 연결을 닫으면) 그 뷰어의 할당량(시청자 자리)은 **1분 동안 계속 쓰이는 것으로 남습니다.** 이 1분 동안에는 **같은 Client ID**로 이 API를 다시 불러, 시청자 자리를 더 쓰지 않고 다시 합류할 수 있습니다. 1분이 지나면 자리가 풀립니다.

자리가 3개뿐인데 끊긴 자리가 1분씩 남는다면, 재연결할 때마다 새 ID를 쓰는 뷰어는 짧은 끊김 몇 번만으로 **혼자서 3자리를 다 먹을 수 있습니다.** 같은 ID로 다시 붙으면 자기 자리를 그대로 이어 씁니다.

직접 연결에서 문제였던 오래된 answer는 여기서는 생기지 않습니다. 저장 세션 모드의 뷰어는 offer를 보내지 않고, join을 부른 뒤에 오는 offer를 기다렸다가 답하기 때문입니다. "내 offer보다 먼저 온 answer"라는 상황 자체가 없습니다.

```js
// 한 번의 '보기' 동안 쓸 clientId를 정한다 (예시)
function pickClientId(mode, session) {
  if (mode === 'storage') {
    // 끊긴 자리는 1분 동안 남는다 → 같은 ID로 다시 붙어야 자리를 둘 먹지 않는다
    return (session.storageClientId ||= `viewer-${crypto.randomUUID()}`);
  }
  // 직접 연결: 이전 시도의 남은 answer를 받지 않도록 시도마다 새 ID
  return `viewer-${crypto.randomUUID()}`;
}
```

하나 남는 한계도 있습니다. 같은 ID로 재연결하는 뷰어는 자리를 둘씩 먹지 않지만, **창을 아예 닫은 사람의 자리는 1분쯤 남습니다.** 세 사람이 보다가 한 명이 나간 직후 새 사람이 들어오면 잠깐 거절될 수 있습니다.

## 사례: 녹화가 30초씩 끊겨 있던 이유

이제 두 번째 낯선 일, 다시 보기 목록에 짧은 녹화만 줄줄이 생긴 문제입니다.

### 원리부터: join은 부를 때마다 offer를 새로 부른다

`JoinStorageSession` API 문서의 "추가 정보"에는 이렇게 적혀 있습니다.

- **멱등(idempotent)하지 않습니다.** 같은 요청을 다시 보내면 새 호출로 처리됩니다.
- 동시에 불러도 되지만 **호출마다 offer가 한 번씩** 갑니다.
- 한 채널의 세션에는 영상을 보내는 장비가 하나만 붙을 수 있고, 여럿이 붙으면 **가장 최근 요청이 우선**합니다.

"마스터가 접속하면 join을 부른다"고만 생각하면 놓치기 쉬운 성질입니다. join은 "세션에 들어가겠다"는 상태 선언이 아니라 "**지금 offer를 하나 보내 달라**"는 요청에 가깝습니다. 부를 때마다 협상이 처음부터 새로 시작됩니다.

### 무슨 일이 있었나

처음 마스터 코드는 "저장 세션과 연결된 상대가 없으면 join을 부른다"는 단순한 규칙으로 돌았습니다. 실제 환경에서 디버그 로그(offer의 모양과 연결 상태 변화만 남기고 SDP·주소는 남기지 않는 로그)를 켜고 보니 이렇게 돌고 있었습니다.

1. 마스터가 join을 부르고, 저장 세션이 offer를 보냅니다.
2. 마스터가 offer에 답하는 동안(상대는 생겼지만 아직 연결 전, 약 0.7초) 규칙 검사가 돌았습니다. "연결된 상대"가 아직 없으니 **join을 또 불렀습니다.**
3. 저장 세션은 새 세션을 열고, 방금 답하던 세션은 버려졌습니다. 스스로 자기 세션을 죽인 셈입니다.
4. 버려진 연결은 약 30초 뒤 **ICE consent 확인**이 만료됐고, 우리 마스터 구현은 그 시점에 연결을 닫았습니다.
5. 그 사이 새 offer가 와서 같은 일이 되풀이됐습니다. 결과적으로 **약 33초마다 새 세션**이 열렸고, 녹화는 거의 남지 않았습니다.

ICE consent 확인(RFC 7675)은 연결이 붙은 뒤에도 상대가 "계속 받겠다"고 동의하는지 STUN 요청으로 주기적으로 확인하는 장치입니다. RFC는 동의가 **30초** 동안 확인되지 않으면 그 경로로 보내기를 멈추라고 정합니다. RFC가 요구하는 것은 거기까지이고, 연결 객체를 닫는 것은 표준이 아니라 **우리 구현의 반응**이었습니다. 상대(버려진 세션)가 더 이상 응답하지 않으니 30초쯤 뒤 동의가 만료됐고, 그때 우리 코드가 연결을 닫았습니다. 30초 남짓한 간격이 여기서 나왔습니다.

<figure class="diagram">
{% include figures/kvs-webrtc-recording-storage-session/rejoin-rule-timeline.svg %}
<figcaption>위는 이번 관찰: offer에 답하는 중에 join을 또 부르면 답하던 세션이 버려지고, 약 30초 뒤 consent가 만료되자 우리 구현이 연결을 닫는 일이 되풀이됐다. 아래는 고친 뒤: 상대가 있는 동안에는 join하지 않아 녹화가 약 36분 이어졌다. 상대 객체가 아예 없을 때만 마지막 join과 마지막 offer 중 늦은 쪽에서 25초를 세어 다시 join한다</figcaption>
</figure>

### 해결: 25초 규칙

규칙을 이렇게 바꿨습니다.

- 저장 세션 상대가 **아예 없을 때만** 다시 부릅니다. 연결됨이나 연결 중뿐 아니라, 막 만들어진(new) 상대나 잠깐 끊긴(disconnected) 상대도 "있다"로 봅니다. 상대 객체가 남아 있는 동안은 부르지 않습니다.
- 그리고 **마지막 join과 마지막 offer 중 늦은 쪽에서 25초**가 지났을 때만 부릅니다.
- join이 `ClientLimitExceededException`(메시지 "Session in creation, please retry")으로 돌아오면 조금 기다렸다가 다시 부릅니다. 채널당 join 한도(2 TPS)도 있으니 재시도는 간격을 둡니다.

25초는 offer가 오고 연결이 자리 잡을 시간을 주면서, 세션이 정말로 사라졌을 때는 너무 오래 기다리지 않으려고 실험으로 정한 값입니다. 공식 권장값은 아닙니다. 핵심은 숫자보다 "**상대가 있으면(협상 중이어도) join하지 않는다**"는 조건입니다. 로직만 떼어 쓰면 이렇습니다(예시, 실행 미확인).

```js
const REJOIN_AFTER_MS = 25_000;

// 저장 세션에 다시 join해야 하는가?
// hasStoragePeer: 저장 세션용 RTCPeerConnection 객체가 지금 있는가
function storageJoinDue({ hasStoragePeer, lastJoinAt, lastOfferAt, now = Date.now() }) {
  // 상대 객체가 있으면 상태(new·connecting·connected·disconnected)와 상관없이 부르지 않는다
  // (부르면 그 세션이 버려진다)
  if (hasStoragePeer) return false;
  const since = Math.max(lastJoinAt ?? 0, lastOfferAt ?? 0);
  return now - since >= REJOIN_AFTER_MS;
}

let storagePeer = null;   // 저장 세션용 RTCPeerConnection (없으면 null)
let lastJoinAt = 0;
let lastOfferAt = 0;

// 정리는 이 함수 하나로: 참조를 먼저 비우고 닫는다
// (close()는 connectionstatechange 이벤트를 일으키지 않으므로 이벤트에 기대지 않는다)
function disposeStoragePeer(pc) {
  if (storagePeer === pc) storagePeer = null;
  pc.close();
}

function watchStoragePeer(pc) {
  pc.addEventListener('connectionstatechange', () => {
    if (pc.connectionState === 'failed') disposeStoragePeer(pc);
  });
}

// 저장 세션의 offer가 왔을 때 (answer를 만들어 보내는 부분은 생략)
function onStorageOffer(iceServers) {
  const pc = new RTCPeerConnection({ iceServers });
  storagePeer = pc;
  watchStoragePeer(pc);
  lastOfferAt = Date.now();
  return pc;
}

// 앱이 직접 끝낼 때(카메라 끄기 등)도 같은 정리 함수를 부른다
function stopStoragePeer() {
  if (storagePeer) disposeStoragePeer(storagePeer);
}

// 주기 검사 (예: 1초마다)
function checkStorageJoin(joinStorageSession) {
  if (storageJoinDue({ hasStoragePeer: storagePeer !== null, lastJoinAt, lastOfferAt })) {
    lastJoinAt = Date.now();
    joinStorageSession();   // JoinStorageSession 호출 (생략)
  }
}
```

`storageJoinDue`는 "상대 객체가 아예 없고 25초가 지났는가"만 판단합니다. 끝난 상대를 치우는 일은 부르는 쪽 몫이고, 위 예시는 그 정리를 `disposeStoragePeer` 하나로 모았습니다. 참조를 먼저 비우고 나서 닫습니다. W3C WebRTC 명세의 `close()` 절차는 상태를 `closed`로 바꾸지만 `connectionstatechange` 이벤트는 일으키지 않습니다. 그래서 이벤트 처리기에서 `closed`를 기다렸다가 참조를 비우게 짜면, 앱이 직접 `close()`를 부른 경우에는 참조가 그대로 남습니다. 이벤트로는 `failed`만 받고, 앱이 직접 끝내는 경로(`stopStoragePeer`)도 같은 정리 함수를 부르게 한 이유입니다. 정리를 빠뜨리면 끝난 상대가 계속 "있다"로 남아 다시 join하지 못합니다.

고친 뒤에는 뷰어 없이 마스터만 켜 둔 상태에서 **약 36분 동안 녹화가 하나로 이어졌습니다.** 36분은 시험용 마스터를 끈 시점에서 끝난 길이입니다. 여기서 "녹화 하나"는 끊기지 않고 이어진 한 구간을 말합니다. 스트림 안에서는 그 구간도 몇 초짜리 조각(fragment) 여러 개가 줄지어 이루어져 있습니다.

### 1시간 경계

할당량 표의 "세션 시간 1시간 (h)"과 미디어 수집 안내의 "세션 시간 최대 1시간"에 따르면, 저장 세션은 길어야 1시간 뒤에 끝납니다. 그때 마스터가 위 규칙대로 다시 join하면 녹화에 몇 초의 틈이 생길 것으로 예상하고, 다시 보기 목록은 짧은 틈을 한 녹화로 이어 붙여 보여 주게 했습니다. **이 1시간 경계는 아직 실제로 지켜보지 않았습니다.** 36분 시험은 경계에 닿기 전에 끝났습니다.

## 상대가 AWS 서버일 때 달라지는 것들

저장 세션은 WebRTC 참가자이지만 브라우저는 아닙니다. 직접 연결에서 문제없던 마스터가 저장 세션과는 붙지 않는 일이 여러 번 있었습니다. 공식 문서의 요구 사항과 직접 겪은 것을 나눠 정리합니다.

### 공식 문서에 적힌 요구 사항

- **영상은 H.264만** 받습니다. 지원 프로필은 constrained-baseline, baseline, main, high, constrained-high, progressive-high이고, 최대 해상도는 1920×1920입니다. 직접 연결에서 VP8을 대비책으로 두었더라도 녹화 채널에서는 쓸 수 없습니다.
- **소리 트랙이 꼭 있어야** 합니다(Opus). `JoinStorageSession` 문서는 "WebRTC 수집에는 지금 소리와 영상 트랙이 둘 다 필요하다"고 적습니다. 마이크가 없는 장비라면 **무음 Opus 트랙**을 만들어 보내야 합니다.
- **트랙 방향**이 정해져 있습니다. 마스터의 answer는 H.264 영상 `sendonly`, Opus 소리 `sendonly`나 `sendrecv`여야 합니다. 뷰어의 answer는 영상 `recvonly`, 소리 `recvonly`나 `sendrecv`여야 합니다.
- **trickle ICE가 필요**합니다. trickle ICE(RFC 8838)는 후보를 다 모은 뒤 SDP에 한꺼번에 담지 않고, 찾는 대로 하나씩 신호 메시지로 보내는 방식입니다. 또 연결 시간을 줄이려면 host 후보는 저장 세션에 보내지 말라고 권합니다.
- 저장 세션이 보내는 신호 메시지에는 **`senderClientId`가 없습니다.** 직접 연결의 마스터는 offer와 후보를 받을 때 늘 이 필드로 "어느 뷰어인지"를 구분하므로, 이 필드에 기대는 코드는 그대로 두면 깨집니다. 저장 세션이 보낸 ICE 후보에는 `sdpMid`도 없습니다.
- answer와 후보 메시지에 **`correlationId`**를 넣으면 저장 세션이 `statusResponse`로 결과를 돌려줍니다. answer가 왜 거절됐는지(예: 코덱 불일치, 트랙 방향 오류) 바로 알 수 있어 디버깅에 도움이 됩니다.
- 공식 안내의 브라우저 예제 절은 "지금 지원 브라우저는 Chrome뿐"이라고 적고 있습니다. 대시보드는 Chromium 계열 브라우저로 시험했고, Safari의 저장 세션 연결은 시험하지 않았습니다.

### 저장 세션은 relay 후보만 보낸다

공식 안내서는 "저장 세션은 AWS 망 안에 있으므로 **relay(TURN) 후보만** 보낸다"고 적습니다. 참가자 쪽 망이 허락하면 내 쪽 후보는 srflx일 수도 있지만, **상대(원격) 후보는 언제나 relay**입니다.

별도의 시험에서도 이와 맞는 결과가 나왔습니다. 16번 접속 중 15번은 저장 세션이 보낸 원격 후보가 relay 하나뿐이었고, 우리 쪽에서 host나 srflx를 허용해도 선택된 후보 쌍은 모두 relay/relay였습니다. 이것은 이 시험 환경(우리 쪽 망과 설정)에서의 관찰이고, 어느 환경에서나 relay/relay가 된다는 공식 설명은 아닙니다. 직접 연결에서는 같은 망 안이면 host 경로로 붙어 빠르던 것이, 녹화를 켜면 적어도 상대 쪽은 TURN을 거치는 경로가 된다는 뜻입니다. 지연을 잴 때 이 차이를 같이 봐야 합니다.

### 직접 겪은 것: DTLS 암호 묶음

마스터를 파이썬 WebRTC 라이브러리로 만들었는데, 저장 세션과의 DTLS 핸드셰이크가 **빈 오류 목록**과 함께 실패했습니다. 원인은 암호 묶음(cipher suite)이었습니다. DTLS 핸드셰이크에서 양쪽은 서로 지원하는 암호 묶음 목록을 맞춰 보는데, 라이브러리는 ECDSA 인증서용 묶음(ECDHE-ECDSA 계열)만 제시했고, 저장 세션이 내민 DTLS 인증서는 **RSA**였습니다. 겹치는 묶음이 없으니 핸드셰이크가 완료되지 못하고 실패했습니다. RSA 계열 묶음도 허용하자 붙었습니다. 저장 세션의 인증서 종류는 공식 문서에서 찾지 못했고 우리가 관찰한 값이므로, 비슷한 실패가 나면 먼저 양쪽이 제시하는 암호 묶음을 비교해 보는 것이 좋습니다(DTLS-SRTP 자체는 시리즈 5편에서 다룹니다).

같은 라이브러리는 trickle ICE를 지원하지 않았습니다. 그래서 answer SDP 안에 담긴 후보를 꺼내 **trickle 메시지로도 따로 한 번 더** 보냈습니다. 쓰는 라이브러리를 고를 때는 공식 요구 사항(trickle ICE, 소리 트랙)을 지원하는지 먼저 확인하고, 그와 별개로 우리가 겪은 DTLS 암호 묶음 문제(RSA 인증서용 묶음을 제시하는지)도 살펴볼 만합니다. 앞의 둘은 문서에 적힌 조건이고, 뒤의 하나는 우리 관찰입니다.

## 녹화 중에는 대체 화면(스냅샷)이 멈춘다

이 시스템에는 실시간 영상이 안 될 때를 위한 대체 경로가 하나 있었습니다. 장비가 1초에 한 장씩 JPEG 스냅샷을 메시지로 보내고, 대시보드가 15초 동안 실시간 영상을 못 받으면 스냅샷을 보여 주는 방식입니다. 장비는 대역폭을 아끼려고 **실시간 영상이 흐르는 동안에는 스냅샷을 보내지 않게** 되어 있었습니다.

녹화를 켜면 이 설계가 맞물려 버립니다. 저장 세션은 시청자가 있든 없든 카메라가 켜진 동안 늘 영상을 받으므로, 장비는 늘 "영상이 흐르는 중"입니다. 그래서 스냅샷이 오지 않습니다. 시청자 자리가 다 찬 4번째 사람은 안내 문구와, 있다면 예전 스냅샷만 보게 됩니다. 이것도 4명을 동시에 붙여 확인한 것은 아니고 코드와 문서로 추론한 결과입니다. 녹화를 켜면 "아무도 안 보면 안 보낸다"는 가정에 기댄 다른 기능이 없는지 한 번 살펴볼 필요가 있습니다.

## 보관 기간과 저장량

### 보관 기간 7일과 바꾸는 법

녹화 보관 기간은 신호 채널이 아니라 **스트림의 `DataRetentionInHours`**가 정합니다. 기간이 지난 조각은 KVS가 스스로 지웁니다.

- 범위: API 기준 최소 0(저장 안 함), 최대 87,600시간(10년)입니다. WebRTC 수집에는 0보다 커야 하고 최소 1시간입니다.
- 이 시스템은 **7일(168시간)**로 정했습니다. 개발 단계에서 "지난주 시험을 다시 볼 수 있는" 최소 기간이고, 저장 요금이 보관 기간에 비례하기 때문입니다. 설정 값은 일 단위(1~3,650일)로 두고 범위를 벗어나면 배포 전에 오류가 나게 했습니다.
- 바꿀 때 **스트림을 새로 만들 필요가 없습니다.** CloudFormation의 `AWS::KinesisVideo::Stream`에서 `DataRetentionInHours`는 "Update requires: No interruption"(교체 없는 갱신)이고, API로는 `UpdateDataRetention`을 씁니다. 이때 `DataRetentionChangeInHours`는 목표 값이 아니라 **지금 값에서 늘리거나 줄일 양**이고, `Operation`(`INCREASE_DATA_RETENTION`/`DECREASE_DATA_RETENTION`)으로 방향을 정합니다. 예를 들어 168시간을 192시간으로 늘리려면 `INCREASE_DATA_RETENTION`과 `24`를 넘깁니다. 스트림의 현재 버전(`CurrentVersion`, `DescribeStream`이나 `ListStreams`로 얻음)도 꼭 넣어야 합니다.
- 늘리면 이미 저장된 데이터도 새 기간 동안 남습니다. **줄이면 새 기간보다 오래된 데이터는 바로 지워집니다**(`UpdateDataRetention` 문서). 줄이기 전에는 지워질 녹화가 없는지 확인해야 합니다.
- 스트림을 지우면 그 안의 녹화가 모두 사라집니다. 채널과 연결된 동안에는 지울 수 없으니 연결부터 끊어야 합니다.

### 실제로 쌓인 양

640×480, 15 fps 합성 시험 화면(대부분 정지한 화면에 시계만 움직임)으로 시험한 날 하루 동안 쌓인 녹화를 조각 목록(`ListFragments`)으로 셌습니다.

| 항목 | 값 |
|---|---|
| 조각 수 | 291개 |
| 녹화 길이 | 2,897초(약 48분) |
| 크기 | 13.14 MB |
| 평균 비트레이트 | 약 36 kbit/s |

291개는 그날 쌓인 녹화 전체를 조각 단위로 센 값입니다. 녹화 하나가 291조각이라는 뜻이 아니라, 이어진 녹화 구간 여러 개가 모두 합쳐 291조각이라는 뜻입니다(2,897초 ÷ 291 ≈ 조각당 평균 10초).

같은 날 앞서 센 값(188조각, 10.16 MB)은 평균 약 43 kbit/s였습니다. 이 평균으로 하루 내내 켜 둔다고 어림하면 다음과 같습니다.

- 약 36 kbit/s × 86,400초 ≈ 하루 약 0.39 GB, 7일 보관이면 약 2.7 GB
- 약 43 kbit/s로 잡으면 하루 약 0.46 GB, 7일 약 3.3 GB

장비 하나에 7일 동안 3 GB 안팎입니다. 다만 이 값은 거의 움직이지 않는 합성 화면 기준입니다. 실제 카메라 장면은 움직임이 많아 훨씬 클 수 있습니다. 장면이 바뀌는 만큼 압축이 덜 되기 때문입니다. 실제 장비에서는 비트레이트를 다시 재서 계산해야 합니다.

### 요금은 공식 페이지에서

단가는 리전과 시기에 따라 달라서 이 글에는 숫자를 옮기지 않습니다. [Amazon Kinesis Video Streams 요금](https://aws.amazon.com/kinesis/video-streams/pricing/) 페이지에서 리전을 골라 확인합니다. 녹화를 켜면 관련되는 항목은 이렇습니다.

- **Media Ingested via WebRTC**: WebRTC로 스트림에 녹화한 미디어 **분 단위** 요금입니다. 요금 페이지는 WebRTC로 수집한 미디어에는 스트림의 GB당 수집 요금이 붙지 않는다고 적고 있습니다.
- **Session Viewing with Multi-Viewer**: 저장 세션에 붙은 뷰어의 시청 분 단위 요금입니다.
- 스트림 **저장(GB-월)**: 보관 중인 양에 비례합니다. 위의 "하루 녹화량 × 보관 일수"가 여기에 들어갑니다.
- 다시 보기(HLS 등으로 읽은 양)와 인터넷으로 나가는 데이터 전송.
- 신호 채널 활성 수, 신호 메시지 수, TURN 중계 분은 녹화와 상관없이 원래 있는 항목입니다.

## 주의할 점 정리

- **녹화를 켜면 직접 연결이 사라집니다.** 채널을 스트림에 연결하는 순간 장비와 브라우저는 서로가 아니라 저장 세션과 연결합니다. 장비와 웹 코드 둘 다 `DescribeMediaStorageConfiguration`으로 모드를 확인하고 분기해야 합니다.
- **offer 방향이 뒤집힙니다.** 뷰어는 offer를 만들지 않고 `JoinStorageSessionAsViewer`를 부른 뒤 저장 세션의 offer에 답합니다. 마스터도 `JoinStorageSession`을 불러야 offer가 옵니다. 두 API는 `WEBRTC` 엔드포인트로 보냅니다.
- **시청자 한도는 10명(soft)에서 3명(hard)으로** 바뀌고, 장비 업링크는 시청자 수와 상관없이 한 줄이 됩니다. 동시 시청자 수를 모르면 한도를 넘을 때의 대응을 미리 정해 두어야 합니다.
- **저장 세션 모드에서는 같은 ClientId로 재연결합니다.** 끊긴 자리는 1분 동안 남습니다. 직접 연결의 "시도마다 새 ID" 규칙을 그대로 가져오면 자리를 혼자 다 먹습니다.
- **join은 멱등하지 않습니다.** 부를 때마다 offer가 새로 오고 앞 세션은 버려질 수 있습니다. 상대가 있으면(협상 중이어도) 다시 부르지 않고, 끝난 상대는 닫고 참조를 비웁니다.
- **상대가 AWS 서버라는 점을 기억합니다.** H.264만, 소리 트랙 필수, trickle 필요, `senderClientId` 없음, 후보가 offer보다 먼저 올 수 있음, 원격 후보는 relay입니다(여기까지 공식 문서). DTLS 핸드셰이크가 이유 없이 실패하면 암호 묶음을 봅니다(우리 관찰).
- **"아무도 안 보면 안 보낸다"는 가정이 깨집니다.** 그 가정에 기댄 대체 화면, 대역폭 계산, 요금 계산을 다시 봅니다.
- **보관 기간은 스트림이 정하고 교체 없이 바꿀 수 있지만,** 줄이면 오래된 녹화가 바로 지워집니다.
- **확인하지 못한 것**: 4명 동시 시청 시험, 저장 세션 1시간 경계, 실제 카메라의 비트레이트, Safari에서의 저장 세션 연결은 아직 확인하지 않았습니다.

## 정리

KVS WebRTC 수집으로 녹화를 켜면, 신호 채널이 이어 주던 장비와 브라우저 사이에 **저장 세션**이라는 WebRTC 참가자가 들어옵니다. 저장 세션은 장비의 영상을 받아 스트림에 녹화하고, 같은 영상을 뷰어에게 나눠 줍니다. 그 결과 offer를 보내는 쪽(뷰어 → 저장 세션), 시청자 한도(10명 → 3명), 장비 업링크(시청자 수만큼 → 한 줄), ClientId 전략(시도마다 새 ID → 같은 ID)이 모두 바뀝니다. "녹화를 끄면 몇 명까지 볼 수 있어?"라는 질문은 사실 "뷰어마다 영상을 나눠 보내는 일을 장비가 할까, AWS의 저장 세션이 할까"라는 질문이었고, 시청자 한도는 각 모드의 할당량을 따릅니다.

30초마다 끊기던 녹화는 `JoinStorageSession`이 부를 때마다 새 협상을 시작한다는 성질을 몰라서 생긴 일이었습니다. 협상 중인 상대가 있으면 다시 부르지 않는 규칙(25초 규칙)으로 바꾸자 녹화가 하나로 이어졌습니다.

다음 편에서는 이렇게 스트림에 쌓인 녹화를 HLS로 다시 보는 원리와 KVS 재생 API를 다룹니다.

## 참고 자료

- [Use Amazon Kinesis Video Streams with WebRTC to ingest and store media](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/webrtc-ingestion.html)
- [What is Amazon Kinesis Video Streams with WebRTC ingestion and storage?](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/getting-started-ingestion.html)
- [Configure destination](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/configure-ingestion.html) · [Grant permission](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/ingestion-grant-permission.html) · [Ingest media](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/ingest-media.html)
- [Troubleshoot issues connecting with the storage session](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/troubleshoot-establish-storage.html)
- [Kinesis Video Streams with WebRTC service quotas](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-limits.html)
- API: [JoinStorageSession](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_webrtc_JoinStorageSession.html) · [JoinStorageSessionAsViewer](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_webrtc_JoinStorageSessionAsViewer.html) · [UpdateMediaStorageConfiguration](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_UpdateMediaStorageConfiguration.html) · [UpdateDataRetention](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_UpdateDataRetention.html)
- [AWS::KinesisVideo::Stream (CloudFormation)](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-kinesisvideo-stream.html)
- [Amazon Kinesis Video Streams 요금](https://aws.amazon.com/kinesis/video-streams/pricing/)
- [W3C WebRTC: RTCPeerConnection close()](https://www.w3.org/TR/webrtc/#dom-rtcpeerconnection-close)
- [RFC 8445: Interactive Connectivity Establishment (ICE)](https://www.rfc-editor.org/rfc/rfc8445) · [RFC 7675: STUN Usage for Consent Freshness](https://www.rfc-editor.org/rfc/rfc7675) · [RFC 8838: Trickle ICE](https://www.rfc-editor.org/rfc/rfc8838)
