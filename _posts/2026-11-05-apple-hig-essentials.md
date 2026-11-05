---
title: "개발자가 꼭 알아야 할 Apple HIG: 44pt 터치 영역부터 Dynamic Type, 권한 요청까지"
date: 2026-11-05 14:20:00 +0900
categories: [디자인, UI 가이드라인]
tags: [apple, hig, ios, ui-design, accessibility, dynamic-type, dark-mode, sf-symbols]
description: "Apple HIG에서 개발자가 구현할 때 지켜야 할 것만 추렸습니다. 44pt 터치 영역, 대비 4.5:1, Dynamic Type, safe area, 시맨틱 색, Liquid Glass, 시트, 권한 요청을 원문 표로 확인하고 SwiftUI·CSS 예시로 정리합니다."
---

## HIG가 열리지 않던 순간

웹 채팅 화면을 설계하던 때의 일입니다. 화면 배치를 정하려고 다른 채팅 서비스의 화면과 플랫폼 가이드를 참고 자료로 모으고 있었습니다. Apple Human Interface Guidelines(이하 HIG)의 Messages, Keyboards, Layout 페이지도 목록에 넣었습니다. 그런데 브라우저 없이 문서를 받아 오는 도구로 열자 404가 나거나 시간 초과로 끝났습니다. 결국 이 세 항목은 참고 자료 표에 "지식으로만 기록"이라고 적고 넘어갔습니다.

"대충 아는 내용"으로 넘긴 대가는 나중에 옵니다. 터치 영역이 몇 pt인지, 그 숫자가 최소인지 기본인지, 대비 기준이 글자 크기에 따라 어떻게 갈리는지는 기억으로 쓰면 틀리기 쉬운 숫자입니다. 그래서 이번에 그때 건너뛴 HIG를 원문으로 다시 읽고, **개발자가 코드로 지켜야 하는 것**만 추렸습니다. 디자인 철학이나 역사는 다루지 않습니다.

### 이번에 확인한 것: HTML은 빈 껍데기, 본문은 JSON에

다시 열어 보니 원인이 될 만한 것이 하나 보였습니다. 2026년 11월 5일에 `curl`로 Layout 페이지를 받아 보면 결과가 이렇습니다.

| 주소 | 응답 | 크기 | 본문 |
|---|---|---|---|
| `developer.apple.com/design/human-interface-guidelines/layout` | 200 | 18,161바이트 | "safe area"가 0번 나옴. 보이는 문구는 "This page requires JavaScript." |
| `developer.apple.com/tutorials/data/design/human-interface-guidelines/layout.json` | 200 | 84,939바이트 | 본문 전체가 있음 |

HIG 페이지의 HTML은 JavaScript가 나중에 본문을 채우는 껍데기입니다. 그래서 JavaScript를 실행하지 않는 도구(AI 에이전트의 웹 가져오기 도구나 `curl` 같은 것)로 받으면 본문 없는 페이지만 손에 쥐게 됩니다. 같은 내용은 아래 JSON 주소로 받을 수 있었습니다.

```sh
# <page>에는 layout, accessibility, sheets 같은 페이지 이름을 넣습니다
curl -s https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json
```

이 JSON 주소는 제가 찾은 범위에서 공개 API로 안내된 주소가 아닙니다. 페이지가 내부적으로 쓰는 데이터라서 언제든 바뀔 수 있습니다. 사람에게 링크를 줄 때는 원래 페이지 주소를 씁니다.

404 쪽은 주소 자체가 바뀌었을 수도 있습니다. 같은 날 확인해 보니 `navigation-bars` 페이지는 `toolbars`로 301 리다이렉트되었고, JSON 주소는 404였습니다. 지금 HIG는 내비게이션 바를 Toolbars 페이지에서 다룹니다. `messages`는 HTML과 JSON 모두 404였습니다. `keyboards`는 지금 둘 다 열립니다.

다만 그때 실패한 원인이 정확히 이것이었다고 단정하지는 않습니다. 당시 404와 시간 초과가 왜 났는지는 기록이 남아 있지 않습니다. 확실한 것은 "HTML만 받는 도구로는 HIG 본문을 읽을 수 없다"는 점입니다.

## HIG는 어떻게 생겼나

[HIG](https://developer.apple.com/design/human-interface-guidelines/) 첫 화면은 여섯 묶음으로 나뉩니다. 개발자가 자주 여는 것은 앞의 네 개입니다.

| 묶음 | 들어 있는 것 | 이 글에서 다루는 페이지 |
|---|---|---|
| Getting started | 플랫폼별 개요 | Designing for iOS |
| Foundations | 모든 화면에 걸리는 기초 규칙 | Accessibility, Layout, Typography, Color, Dark Mode, Materials, SF Symbols, Privacy |
| Patterns | 여러 화면에 걸친 흐름 | Launching, Onboarding, Modality |
| Components | 개별 UI 부품 | Tab bars, Toolbars, Sheets, Buttons |
| Inputs, Technologies | 입력 방식, 특정 기술 | (이 글에서는 다루지 않음) |

플랫폼마다 페이지가 따로 있는 게 아니라, 한 페이지 안에서 공통 규칙을 먼저 말하고 끝에 "Platform considerations"로 iOS·macOS·visionOS 같은 플랫폼별 차이를 붙이는 구조입니다. 숫자 기준을 찾을 때는 이 플랫폼별 절과 표를 봐야 합니다.

읽다 보면 같은 말이 반복됩니다. **시스템이 주는 것을 쓰면 대부분 자동으로 지켜진다**는 말입니다. 원문 몇 곳을 모으면 이렇습니다.

- 시스템 글꼴을 text style(`.body`, `.headline` 같은 글자 스타일)과 함께 쓰면 Dynamic Type을 자동으로 지원합니다 ([Typography](https://developer.apple.com/design/human-interface-guidelines/typography))
- 시스템 색은 밝은·어두운 모드와 대비 높이기(Increase Contrast) 설정에 맞는 변형을 이미 갖고 있습니다 ([Color](https://developer.apple.com/design/human-interface-guidelines/color))
- 시스템 프레임워크의 표준 컴포넌트는 Liquid Glass 모양과 동작을 자동으로 받습니다 ([Materials](https://developer.apple.com/design/human-interface-guidelines/materials))
- 표준 시스템 컴포넌트는 오른쪽에서 왼쪽으로 읽는 언어에 맞춰 배치를 바꿔 줍니다 ([Layout](https://developer.apple.com/design/human-interface-guidelines/layout))

그래서 이 글의 "개발자가 할 일"은 대부분 두 가지로 모입니다. 시스템 것을 쓸 것, 그리고 직접 만든 부분에서는 시스템이 해 주던 일을 직접 할 것입니다.

아래 SwiftUI 예시는 이 글을 위해 새로 쓴 최소 예시입니다. iPhone 시뮬레이터 SDK 26.5에서 배포 대상 iOS 18로(`glassEffect` 예시만 iOS 26으로) 타입 검사(`swiftc -typecheck`)만 통과시켰고, 앱에서 실행해 보지는 않았습니다.

## 레이아웃과 안전 영역(safe area)

[Layout](https://developer.apple.com/design/human-interface-guidelines/layout) 페이지가 말하는 안전 영역(safe area)은 창 안에서 **하드웨어 요소나 다른 뷰(툴바, 탭 바, 상태 바)에 가장자리가 가리지 않는 영역**입니다. 이 영역을 지켜야 Dynamic Island 같은 하드웨어 요소나 시스템 UI가 콘텐츠와 컨트롤을 가리지 않습니다.

여기서 헷갈리기 쉬운 점이 있습니다. safe area를 지키라는 말은 "화면 끝을 비워 두라"는 말이 아닙니다. 같은 페이지는 화면 전체를 채우는 배경 콘텐츠라면 사이드바·툴바·탭 바 **아래까지** 깔아서 화면이나 창 전체를 채우라고 합니다. 아래 그림에 나오는 Liquid Glass는 툴바·탭 바 같은 시스템 컨트롤이 쓰는 반투명 재질인데, 규칙은 뒤의 재질 절에서 따로 다룹니다. 정리하면 이렇습니다.

<figure class="diagram">
{% include figures/apple-hig-essentials/layers-safe-area.svg %}
<figcaption>배경은 막대 아래 화면 끝까지 깔고, 글자와 버튼은 safe area 안에 두며, Liquid Glass는 그 위에 뜬 컨트롤·탐색 층에만 쓴다.</figcaption>
</figure>

SwiftUI에서는 뷰가 기본적으로 safe area 안에 배치됩니다. 배경처럼 끝까지 깔아야 하는 것만 골라서 `ignoresSafeArea()`를 붙입니다.

```swift
struct CoverView: View {
    var body: some View {
        ZStack {
            Color.indigo
                .ignoresSafeArea()      // 배경만 화면 끝까지
            VStack {
                Text("오늘의 메모")
                    .font(.largeTitle)
                Spacer()
                Button("새 메모") { }
            }
            .padding()                  // 글자와 버튼은 safe area 안 (기본값)
        }
    }
}
```

safe area 말고도 Layout 페이지에서 개발자가 챙길 것이 몇 가지 더 있습니다.

- **화면 크기·방향·창 크기가 바뀌어도 자연스럽게 적응하게** 만듭니다. 시스템이 정한 safe area, 여백(margin), 레이아웃 가이드를 존중하는 것이 출발점입니다. 가로 전용 게임처럼 방향을 고정한 앱도 여러 기기와 창 크기에서 크기가 잘 바뀌어야 합니다.
- **배치는 기기 종류나 방향이 아니라 크기 클래스(size class)로 정합니다.** 크기 클래스는 가로·세로 각각 compact(좁음·낮음)와 regular(넓음·높음)로 "지금 쓸 수 있는 공간"을 알려 줍니다. iPhone인지 iPad인지, 세로인지 가로인지는 공간이 얼마나 있는지 알려 주지 않습니다.
- **공간이 바뀌어도 기능은 그대로** 둡니다. 보이는 기능의 양은 바꿔도 됩니다. 넓어지면 탭 바를 사이드바로 바꾸는 식입니다.
- **정렬과 들여쓰기로 계층을 보여 줍니다.** 사람은 정렬된 것끼리 관련 있다고 여기고, 들여쓴 것은 앞 항목에 딸린 것으로 읽습니다.
- **가장 큰 레이아웃과 가장 작은 레이아웃부터 미리 봅니다.** 여러 기기, 크기 클래스, 언어, 글자 크기로 확인하라고 하는데, 양 끝부터 보면 잘림을 빨리 찾습니다.

**개발자가 할 일**: 배경은 `ignoresSafeArea()`로 끝까지, 글자·버튼은 safe area 안에. 분기 조건은 `horizontalSizeClass`로 쓰고 기기 종류로 쓰지 않습니다.

## 터치 영역: 버튼은 44×44pt 이상으로

먼저 단위부터 짚고 가겠습니다. HIG의 pt(point)는 기기 픽셀이 아니라 화면 좌표의 추상 단위입니다. [Images](https://developer.apple.com/design/human-interface-guidelines/images) 페이지 설명대로 1pt가 화면 해상도에 따라 여러 픽셀에 대응하므로, 같은 44pt 버튼은 해상도가 다른 기기에서도 비슷한 크기로 보입니다.

"iOS 버튼은 최소 44pt"라고 기억하는 경우가 많습니다. 원문을 보면 이 숫자는 두 페이지에 다른 이름으로 나옵니다. [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) 페이지의 컨트롤 크기 표는 **기본(default) 크기**와 **최소(minimum) 크기**를 나눠서 적습니다.

| 플랫폼 | 기본 컨트롤 크기 | 최소 컨트롤 크기 |
|---|---|---|
| iOS, iPadOS | 44×44pt | 28×28pt |
| macOS | 28×28pt | 20×20pt |
| tvOS | 66×66pt | 56×56pt |
| visionOS | 60×60pt | 28×28pt |
| watchOS | 44×44pt | 28×28pt |

이 표에서 44×44pt는 iOS 컨트롤의 **기본값**이고, 최소값은 28×28pt입니다. 다만 이 최소값을 "버튼을 28pt까지 줄여도 된다"는 허용으로 읽을 근거는 원문에 없습니다. 최소값은 플랫폼마다 다르기도 해서(macOS는 20×20pt) 하나의 숫자를 모든 플랫폼의 하한으로 쓸 수도 없습니다.

버튼에 대해서는 [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) 페이지가 따로 말합니다. 일반 원칙으로 버튼의 터치 영역(hit region)이 적어도 44×44pt(visionOS는 60×60pt)는 되어야 손가락이든 포인터든 쉽게 고를 수 있다고 합니다. 그래서 이 글은 **직접 만든 iOS 버튼의 터치 영역을 44×44pt 이상으로** 잡습니다. 컨트롤 표의 최소값은 표에 적힌 사실로만 알아 두고, 버튼을 그보다 작게 만드는 근거로 쓰지 않습니다.

크기만큼 간격도 중요합니다. Accessibility 페이지는 컨트롤 사이 간격을 크기만큼 중요하게 보라고 하면서, 테두리(bezel)가 있는 요소는 주위에 약 12pt, 테두리가 없는 요소는 보이는 가장자리 주위에 약 24pt 여백을 두면 잘 맞는다고 합니다. 잘못 누를 확률을 줄이기 위해서입니다.

아이콘만 있는 버튼은 그림이 작아서 터치 영역도 같이 작아지기 쉽습니다. 그림 크기는 그대로 두고 누르는 영역만 키웁니다.

```swift
struct CloseButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .frame(minWidth: 44, minHeight: 44)   // 누르는 영역을 44pt로
                .contentShape(Rectangle())            // 투명한 여백도 누를 수 있게
        }
        .accessibilityLabel("닫기")                    // 아이콘만 있으니 VoiceOver용 이름
    }
}
```

제스처에도 같은 생각이 이어집니다. 자주 하는 동작은 가장 단순한 제스처로 하고, 스와이프로 닫는 화면이라면 같은 일을 하는 버튼도 둡니다. 손이 불편한 사람이나 보조 기기를 쓰는 사람을 위해서입니다.

**개발자가 할 일**: 직접 만든 버튼, 특히 아이콘 버튼의 터치 영역을 44×44pt 이상으로. 버튼 사이 간격도 확인합니다.

## 글자: Dynamic Type과 기본·최소 크기

Dynamic Type은 사람이 시스템 설정에서 글자 크기를 바꾸면 앱의 글자도 따라 바뀌게 하는 시스템 기능입니다. iOS, iPadOS, tvOS, visionOS, watchOS에 있고 macOS에는 없습니다 ([Typography](https://developer.apple.com/design/human-interface-guidelines/typography)).

Accessibility 페이지는 글자 크기를 **가능하면 200%까지**(watchOS는 140%) 키울 수 있게 하라고 권합니다. 방법은 직접 만든 UI로 해도 되고 Dynamic Type을 써도 됩니다. 시스템 글자 스타일(`.body`, `.headline` 같은 text style)과 시스템 글꼴을 쓰면 Dynamic Type과 더 큰 접근성 글자 크기를 자동으로 지원합니다. 직접 넣은 글꼴은 이 동작을 직접 구현해야 합니다.

직접 글자 크기를 정할 때는 플랫폼별 기본·최소 크기를 따릅니다.

| 플랫폼 | 기본 크기 | 최소 크기 |
|---|---|---|
| iOS, iPadOS | 17pt | 11pt |
| macOS | 13pt | 10pt |
| tvOS | 29pt | 23pt |
| visionOS | 17pt | 12pt |
| watchOS | 16pt | 12pt |

가는 굵기의 글꼴이라면 이 권장값보다 크게 쓰라는 말도 붙어 있습니다.

### 큰 글자에서 무너지지 않는 레이아웃

글자만 커지고 레이아웃이 그대로면 잘리거나 겹칩니다. Layout 페이지는 Dynamic Type에 맞춰 이런 조정을 하라고 예를 듭니다.

- 가로로 나란히 놓인 뷰는 글자 공간을 위해 **세로로 쌓아야** 할 수 있습니다.
- 표의 행이나 컨테이너는 글자가 잘리거나 겹치지 않게 **높이가 늘어나야** 합니다.
- 기본으로 한 줄인 행도 **여러 줄로** 늘어날 수 있어야 합니다.

Typography 페이지는 한 걸음 더 들어갑니다. 가로 공간이 좁은 곳에서 글자가 커지면 줄 안의 아이콘이나 **타임스탬프** 같은 요소가 글자를 밀어내 잘림과 겹침이 생기니, 글자를 위에 두고 부가 요소를 아래에 두는 쌓인 배치를 고려하라고 합니다. 채팅의 메시지 한 줄이 정확히 이 경우입니다.

```swift
struct MessageRow: View {
    let text: String
    let sentAt: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // 접근성 글자 크기에서는 본문 아래로 시각을 내립니다
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(text)
                .font(.body)
            if !stacked {
                Spacer(minLength: 8)    // 가로 배치일 때만 시각을 오른쪽 끝으로
            }
            Text(sentAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

`AnyLayout`은 iOS 16부터, `isAccessibilitySize`는 iOS 15부터 쓸 수 있습니다. `Spacer`를 가로 배치에만 넣은 것은 [Spacer](https://developer.apple.com/documentation/swiftui/spacer)가 자기가 든 스택의 주축 방향으로 늘어나기 때문입니다. 세로 배치에서도 그대로 두면 본문과 시각 사이가 벌어질 수 있습니다. 본문 `Text`에 `lineLimit`을 따로 걸지 않은 것도 의도입니다. Typography 페이지는 글자가 커질수록 잘림을 최소로 하고, 레이블은 필요한 만큼 여러 줄을 쓰게 하라고 권합니다.

확인은 설정의 손쉬운 사용(Accessibility) → 디스플레이 및 텍스트 크기 → 더 큰 텍스트에서 더 큰 접근성 크기를 켜고 합니다(Typography 페이지가 안내하는 경로입니다).

**개발자가 할 일**: 글자에는 숫자 크기 대신 text style을. 가로 배치는 접근성 크기에서 세로로. 줄 수 제한은 꼭 필요한 곳에만.

## 색과 다크 모드: 대비 기준과 시맨틱 색

### 대비 기준

여기서 대비는 글자·아이콘 같은 전경색과 그 뒤 배경색이 얼마나 다르게 보이는지를 비율로 나타낸 값입니다. 비율이 클수록 읽기 쉽습니다. Accessibility 페이지는 WCAG Level AA 값을 가져와 아래 표를 기준으로 제시합니다. 단위는 Apple의 pt입니다.

| 글자 크기 | 글자 굵기 | 최소 대비 |
|---|---|---|
| 17pt까지 | 전부 | 4.5:1 |
| 18pt | 전부 | 3:1 |
| 전부 | 굵게(Bold) | 3:1 |

표를 그대로 읽으면 17pt까지의 글자는 4.5:1, 18pt 글자와 굵은 글자는 3:1입니다. 그런데 첫 행과 굵게 행은 "작고 굵은 글자"에서 겹치고, 표에는 그때 어느 행을 따를지 적혀 있지 않습니다. 작은 글자를 굵게 했다는 이유만으로 3:1로 낮추지 말고 4.5:1을 맞추는 편이 안전합니다. 기본 화면에서 이 대비를 못 맞춘다면, 적어도 시스템 설정의 대비 높이기(Increase Contrast)가 켜졌을 때 더 높은 대비의 색 구성을 제공하라고 합니다. 다크 모드를 지원한다면 **밝은 모드와 어두운 모드 양쪽에서** 대비를 확인합니다. [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) 페이지는 직접 정한 전경·배경 색이라면 특히 작은 글자에서 7:1을 목표로 하라고 덧붙입니다.

웹 화면이라면 이 표 대신 WCAG 원문 기준을 적용합니다. [WCAG 2.2 Contrast (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)은 일반 글자에 4.5:1, 큰 글자에 3:1을 요구하고, 큰 글자를 **18pt 이상, 또는 굵은 14pt 이상**으로 정의합니다. 이 pt는 Apple의 pt가 아니라 CSS의 pt라서 각각 약 24px, 18.5px입니다. 예를 들어 웹의 12pt(16px) 굵은 글자는 큰 글자에 들지 않으므로 4.5:1이 필요합니다. HIG 표의 "굵은 글자 3:1"을 크기 조건 없이 웹으로 옮기면 이런 글자가 잘못 통과합니다.

정보를 **색만으로 전달하지 않는 것**도 Accessibility 페이지의 규칙입니다. 빨강·초록, 파랑·주황처럼 구분하기 어려운 조합이 있으니 모양이나 아이콘을 함께 씁니다.

### 시맨틱 색을 써야 다크 모드가 따라온다

[Color](https://developer.apple.com/design/human-interface-guidelines/color) 페이지의 동적 시스템 색(dynamic system color)은 겉보기 색이 아니라 **용도**로 정의됩니다. "배경 1단계", "보조 레이블", "구분선" 같은 이름입니다. 이 색들은 밝은·어두운 모드에 맞춰 자동으로 바뀝니다. 그래서 규칙이 이렇게 나옵니다.

- **시스템 색 값을 코드에 박아 넣지 않습니다.** 문서에 적힌 색 값은 디자인할 때 참고용이고, 실제 값은 릴리스마다 바뀔 수 있습니다. API로 시스템 색을 씁니다.
- **시맨틱 색의 뜻을 바꿔 쓰지 않습니다.** 배경용 색을 글자색으로 쓰는 식이면, 플랫폼 모양이 바뀔 때 깨집니다.
- **직접 만든 색은 밝은·어두운 변형을 같이 정의합니다.** Xcode 에셋 카탈로그의 Color Set에 두 변형을 넣으면 됩니다. 대비 높이기 변형도 함께 정의하라고 합니다.
- **앱 전용 밝게/어둡게 설정을 따로 두지 않습니다.** 사람은 시스템 설정 하나로 정하길 기대하고, 앱이 따르지 않으면 고장 났다고 여길 수 있습니다.

```swift
struct SyncBadge: View {
    var body: some View {
        // 색만으로 알리지 않도록 아이콘과 글자를 함께
        Label("동기화 실패", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)                          // 시스템 빨강: 모드별로 값이 다름
            .padding(8)
            .background(Color(.secondarySystemBackground))  // 용도로 고른 배경색
    }
}
```

**개발자가 할 일**: 색은 용도 이름으로 고르고 16진수 값을 코드에 쓰지 않기. 직접 만든 색은 두 모드 변형과 대비를 같이 확인. 상태는 색과 아이콘·글자로 함께.

## 재질과 Liquid Glass: 컨트롤 층과 콘텐츠 층

[Materials](https://developer.apple.com/design/human-interface-guidelines/materials) 페이지는 재질을 두 종류로 나눕니다. **Liquid Glass**와 **표준 재질(standard materials)**입니다.

- Liquid Glass는 탭 바, 사이드바 같은 **컨트롤·탐색 요소**가 콘텐츠 위에 뜨는 별도의 기능 층을 만듭니다. 아래 콘텐츠가 비쳐 보이면서도 컨트롤은 읽기 쉽게 유지합니다.
- 표준 재질(블러, 비브런시, 블렌딩)은 **콘텐츠 층 안에서** 구조를 나누는 데 씁니다. iOS·iPadOS에는 ultra-thin, thin, regular(기본), thick 네 가지가 있습니다.

개발자가 지킬 규칙은 세 가지입니다.

1. **콘텐츠 층에는 Liquid Glass를 쓰지 않습니다.** 앱 배경 같은 콘텐츠 층 요소는 표준 재질을 씁니다. 예외는 슬라이더·토글처럼 잠깐 조작되는 컨트롤로, 조작하는 동안 Liquid Glass 모양을 띱니다.
2. **직접 만든 컨트롤에는 아껴서 씁니다.** 표준 컴포넌트는 자동으로 받으니, 직접 붙이는 것은 가장 중요한 기능 요소로 제한합니다.
3. **투명한 clear 변형은 사진·영상처럼 화려한 배경 위에서만** 씁니다. 대부분의 시스템 컴포넌트는 regular 변형을 쓰며, 글자가 많은 컴포넌트에도 regular가 맞습니다. clear 아래의 콘텐츠가 밝다면 35% 불투명도의 어두운 층을 까는 것을 고려하라고 합니다.

Layout 페이지도 같은 이야기를 합니다. 컨트롤 아래에 불투명하거나 반투명한 배경색을 까는 대신 스크롤 가장자리 효과(scroll edge effect)로 컨트롤을 콘텐츠 위로 띄우라고 합니다. [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) 페이지 역시 툴바에 직접 배경과 색조를 입히는 것을 줄이라고 합니다. 시스템이 주는 배경 효과와 겹치기 때문입니다.

SwiftUI에서 직접 만든 뷰에 Liquid Glass를 붙이는 API는 `glassEffect(_:in:)`입니다(iOS 26 SDK부터).

```swift
// 영상 위에 뜨는 재생 컨트롤: 기능 층이므로 Liquid Glass 사용
HStack(spacing: 24) {
    Button("이전", systemImage: "backward.fill") { }
    Button("재생", systemImage: "play.fill") { }
    Button("다음", systemImage: "forward.fill") { }
}
.labelStyle(.iconOnly)
.padding()
.glassEffect()
```

**개발자가 할 일**: 시스템 막대는 그대로 두고 직접 배경을 칠하지 않기. 목록 카드나 앱 배경 같은 콘텐츠에 Liquid Glass를 쓰지 않기.

## 아이콘: SF Symbols

[SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)는 시스템 글꼴 San Francisco와 맞물려 굵기·크기에 맞춰 정렬되는 기호 모음입니다. 툴바, 탭 바, 메뉴, 글 안처럼 아이콘이 들어갈 곳 어디에나 씁니다. 개발자가 알아 둘 것은 이렇습니다.

- **굵기와 크기**: 기호는 시스템 글꼴의 굵기 9단계(ultralight부터 black까지)에 대응하고, 크기는 small, medium(기본), large 세 단계입니다. 옆 글자와 굵기가 맞습니다.
- **변형은 보통 뷰가 고릅니다**: iOS 탭 바는 채운(fill) 변형을, 툴바는 외곽선(outline) 변형을 씁니다. 그래서 대개 직접 지정하지 않아도 됩니다.
- **렌더링 모드 네 가지**: monochrome, hierarchical, palette, multicolor. 어떤 모드든 시스템 색을 쓰면 접근성 설정과 다크 모드에 자동으로 맞춰집니다.
- **버전 확인**: 개별 기호와 기능은 대상 OS 버전에 따라 다릅니다. 새로 나온 기호는 이전 OS에 없습니다.
- **사용 조건**: 앱 아이콘, 로고, 그 밖의 상표 용도로 기호(또는 헷갈릴 만큼 비슷한 그림)를 쓰는 것은 금지입니다. Apple 제품을 그린 기호는 쓸 수는 있지만 수정할 수 없습니다.
- **애니메이션은 목적이 있을 때만**: bounce, pulse, scale 같은 기호 애니메이션이 있지만, 너무 많으면 화면이 산만해집니다.

Typography 페이지가 짚듯이, 중요한 정보를 전하는 아이콘은 글자가 커질 때 같이 커져야 합니다. SF Symbols를 쓰면 Dynamic Type 크기 변화에 맞춰 자동으로 커집니다.

**개발자가 할 일**: 직접 그린 PNG 아이콘보다 SF Symbols를 먼저 찾기. 최소 지원 OS에서 그 기호가 있는지 확인하기.

## 탐색: 탭 바는 이동, 동작은 툴바

[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) 페이지의 첫 규칙은 **탭 바는 이동용이지 동작용이 아니다**입니다. 지금 화면의 요소에 무언가를 하는 컨트롤이 필요하면 툴바를 씁니다. Toolbars 페이지도 툴바는 보기 안의 콘텐츠에 작용하고, 탭 바는 앱의 영역 사이를 이동하는 데만 쓴다고 구분합니다.

- **탭 바는 계속 보이게** 둡니다. 숨기면 사람이 앱의 어느 영역에 있는지 잊습니다. 예외는 모달 뷰가 탭 바를 덮을 때로, 모달은 잠깐 쓰고 닫는 독립된 화면이기 때문입니다.
- **탭 버튼을 끄거나 숨기지 않습니다.** 내용이 비었다면 왜 비었는지 그 화면에서 설명합니다.
- **탭 라벨을 붙이고, 가능하면 한 단어로** 씁니다.
- **넘치는 탭(More 탭)을 피합니다.** 가로 공간이 모자라면 마지막 탭이 More 탭이 되어 나머지가 별도 목록으로 숨습니다.
- **배지는 중요한 정보에만** 씁니다.

```swift
struct RootView: View {
    var body: some View {
        TabView {
            Tab("메모", systemImage: "note.text") {      // 탭: 영역 이동
                NavigationStack {
                    Text("메모 목록")
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                // 동작은 탭이 아니라 툴바에
                                Button("새 메모", systemImage: "square.and.pencil") { }
                            }
                        }
                }
            }
            Tab("검색", systemImage: "magnifyingglass") { Text("검색") }
            Tab("설정", systemImage: "gearshape") { Text("설정") }
        }
    }
}
```

`Tab` 구조체는 iOS 18부터 쓸 수 있습니다. "새 메모"를 탭으로 만들고 싶은 유혹이 생길 때가 있는데, 그것은 동작이므로 툴바 버튼이 맞습니다.

툴바 쪽 규칙도 몇 가지 알아 둡니다. 표준 뒤로(Back)·닫기(Close) 버튼을 쓰고 기호 대신 "Back", "Close"라는 글자 라벨을 쓰지 않습니다. 완료·제출처럼 핵심 동작 하나만 눈에 띄는 스타일로 강조해 툴바의 뒤쪽(trailing)에 둡니다. HIG는 이 스타일을 `.prominent`라고 부르는데, 이 이름은 SwiftUI 수정자가 아니라 UIKit의 [`UIBarButtonItem.Style.prominent`](https://developer.apple.com/documentation/uikit/uibarbuttonitem/style-swift.enum/prominent)(iOS 26부터)에 해당합니다. 창 제목에는 앱 이름을 쓰지 않습니다.

**개발자가 할 일**: 탭에는 영역만, 동작은 툴바에. 탭은 어느 화면에서나 보이게(모달 제외).

## 모달과 시트: 취소·완료·뒤로의 역할

[Modality](https://developer.apple.com/design/human-interface-guidelines/modality) 페이지가 말하는 모달은 부모 화면과의 상호작용을 막고, **명시적인 동작으로만 닫히는** 별도 모드입니다. 일반 원칙은 이렇습니다.

- **분명한 이점이 있을 때만** 모달을 씁니다.
- 모달 작업은 **단순하고 짧게** 합니다. 모달 안에 화면 계층을 만들어 "앱 속의 앱"처럼 만들지 않습니다.
- **닫는 방법을 항상 분명하게** 줍니다. iOS에서는 위쪽 툴바의 버튼이나 아래로 쓸어내리기를 기대합니다.
- 닫으면 사용자가 만든 내용이 사라질 수 있다면 **닫기 전에 확인**합니다. iOS에서는 저장 선택지가 있는 액션 시트를 예로 듭니다.
- **다른 모달을 띄우기 전에 앞의 모달을 닫게** 합니다. 알림(alert)은 다른 모달 위에도 뜰 수 있지만, 알림을 동시에 두 개 띄우지는 않습니다.

[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) 페이지에는 플랫폼 차이가 있습니다. macOS, tvOS, visionOS, watchOS의 시트는 항상 모달입니다. iOS·iPadOS의 시트는 모달일 수도 있고 비모달일 수도 있습니다. 비모달 시트를 띄운 채로 부모 화면에 영향을 줄 수 있는데, iPhone·iPad의 메모 앱이 글을 편집하는 동안 서식 시트를 비모달로 띄우는 것이 예입니다.

시트를 닫는 버튼 셋의 역할이 섞이기 쉽습니다.

| 버튼 | 하는 일 | 하지 않는 일 |
|---|---|---|
| 취소(Cancel, 또는 닫기 Close) | 변경을 저장하지 않고 시트를 닫음 | |
| 완료(Done) | 작업을 마치거나 변경을 저장한 뒤 닫음 | 혼자만 두지 않음. 취소나 뒤로와 짝을 지음 |
| 뒤로(Back) | 여러 단계 흐름에서 이전 단계로 이동 | 시트를 닫는 용도가 아님 |

완료 버튼만 두면 작업을 마치는 것 말고는 나갈 길이 없는 것처럼 보이니 취소나 뒤로와 짝을 짓습니다. 다만 세 버튼을 한꺼번에 다 보여 주지는 않습니다. iOS·iPadOS의 단일 화면 시트에서는 취소가 위쪽 툴바의 앞쪽(leading), 완료가 뒤쪽(trailing)에 옵니다. SwiftUI의 `cancellationAction`, `confirmationAction` 자리는 이 위치를 시스템이 정하게 해 줍니다.

```swift
struct EditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    var onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("제목", text: $title)
            }
            .navigationTitle("메모 편집")            // 시트가 하는 일을 제목으로
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }     // 저장 없이 닫기
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {                 // 저장하고 닫기
                        onSave(title)
                        dismiss()
                    }
                }
            }
        }
    }
}
```

이 예시는 쓸어내려 닫기에 대한 확인을 넣지 않은 최소 형태입니다. 저장하지 않은 변경이 있을 때 쓸어내리기를 시작하면 액션 시트로 확인하라는 것이 Sheets 페이지의 권고이니, 실제 앱에서는 그 처리를 더해야 합니다.

시트는 메인 화면에서 **한 번에 하나만** 띄웁니다. 시트 안의 동작이 다른 시트를 부른다면 앞의 시트를 닫고 새 시트를 띄웁니다. 크기를 바꿀 수 있는 시트에는 손잡이(grabber)를 넣는데, 손잡이는 VoiceOver로도 크기를 바꿀 수 있게 해 줍니다. 오래 걸리거나 복잡한 작업이라면 시트 대신 전체 화면 모달을 고려합니다.

**개발자가 할 일**: 취소는 저장 없이 닫기, 완료는 저장하고 닫기, 뒤로는 단계 이동만. 시트 위에 시트를 쌓지 않기.

## 권한 요청: 기능을 쓰려는 순간에, 버튼 하나로

[Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy) 페이지는 위치·건강·연락처 같은 개인 데이터, 사진·메시지 같은 사용자 콘텐츠, 블루투스·로컬 네트워크 같은 보호 자원, 카메라·마이크 같은 기기 기능에 접근하려면 허락을 받아야 한다고 정리합니다. 시스템이 표준 알림을 보여 주고, 개발자는 **왜 필요한지 설명하는 문구**만 넣습니다. 사람은 나중에 설정 앱의 개인정보 보호(Privacy) 항목에서도 이 설명을 다시 보고 선택을 바꿀 수 있습니다.

<figure class="diagram">
{% include figures/apple-hig-essentials/permission-flow.svg %}
<figcaption>권한은 기능을 쓰려는 순간에 묻고, 앞에 안내 화면을 둔다면 “계속” 같은 버튼 하나만 둔다.</figcaption>
</figure>

### 언제 묻나

- **실제로 필요한 데이터만** 요청합니다. 기능에 필요한 것보다 많이 묻거나, 사람이 그 기능에 관심을 보이기 전에 물으면 신뢰를 잃습니다.
- **이상적으로는 그 기능을 실제로 쓰려는 순간까지 기다립니다.**
- **앱을 실행하자마자 묻지 않습니다.** 그 자원 없이는 앱이 동작할 수 없을 때만 예외입니다. 내비게이션 앱이 위치를 묻는 것처럼 이유가 분명하면 사람도 덜 불편해합니다.

[Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding) 페이지도 같은 방향입니다. 앱이 동작하는 데 개인 데이터가 꼭 필요하다면 온보딩 흐름 안에 요청을 넣어 이유와 이점을 보여 줄 수 있고, 그렇지 않다면 그 데이터에 기대는 기능에 처음 들어갈 때 요청합니다.

### purpose string 쓰는 법

시스템 알림에 앱 이름 다음, 허용·거부 버튼 앞에 나오는 문구를 purpose string(usage description string)이라고 부릅니다. HIG는 **짧고 구체적인 완결 문장**으로, 문장형 대소문자를 쓰고, 수동태를 피하고, 마침표로 끝내라고 합니다. HIG의 예시는 영어이니, 같은 기준을 한국어로 옮겨 보면 이렇습니다.

| 문구 | 판단 |
|---|---|
| "녹음한 음성을 글로 바꾸려고 마이크를 사용합니다." | 좋음. 무엇에 왜 쓰는지 능동문으로 말함 |
| "더 나은 경험을 위해 마이크 접근이 필요합니다." | 나쁨. 이유가 막연함 |
| "마이크 접근을 켜세요." | 나쁨. 명령만 있고 이유가 없음 |

문구는 `Info.plist`의 키로 넣습니다. 마이크라면 `NSMicrophoneUsageDescription`입니다. UIKit의 [Requesting access to protected resources](https://developer.apple.com/documentation/uikit/requesting-access-to-protected-resources) 문서는 보호 자원을 쓰면서 purpose string을 넣지 않으면 접근이 실패하고 앱이 크래시할 수도 있다고 경고합니다.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>녹음한 음성을 글로 바꾸려고 마이크를 사용합니다.</string>
```

요청 시점은 버튼을 누른 순간입니다.

```swift
import AVFAudio

struct RecordButton: View {
    var body: some View {
        Button("음성 입력", systemImage: "mic") {
            // 실행할 때가 아니라, 기능을 쓰려고 누른 순간에 묻습니다
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    if granted {
                        // 녹음 시작
                    } else {
                        // 마이크 없이 할 수 있는 길(예: 글자 입력)로 안내
                    }
                }
            }
        }
    }
}
```

`AVAudioApplication.requestRecordPermission(completionHandler:)`은 iOS 17부터 쓸 수 있습니다.

### 시스템 알림 앞의 안내 화면

맥락만으로 이유가 분명하지 않다면 시스템 알림 전에 직접 만든 안내 화면을 둘 수 있습니다. 이 화면에는 규칙이 엄격합니다.

- **버튼은 하나만** 둡니다. 그 버튼이 시스템 알림을 연다는 것이 분명해야 합니다.
- 버튼 이름은 **"Allow"(허용)가 아니라 "Continue"(계속)나 "Next"(다음)** 같은 말로 합니다. 안내 화면의 버튼이 시스템 알림의 허용 버튼과 뜻도 무게도 비슷하면, 사람이 의도와 다르게 알림의 허용을 누르기 쉬워집니다.
- 법적 동의를 받는 경우가 아니면 **다른 동작을 넣지 않습니다.** 알림을 보지 않고 나가는 닫기·취소도 넣지 않습니다.
- 보상을 주거나, 요청처럼 보이는 화면을 만들거나, 알림 그림을 보여 주거나, 알림 뒤 화면에 주석을 다는 디자인은 **App Store 심사에서 거절**되는 예로 나옵니다.

위치는 Core Location의 위치 버튼(`LocationButton`)을 쓰면 버튼을 누른 순간에만 한 번 쓸 권한을 받을 수 있습니다. 메시지에 위치를 붙이는 것처럼 가끔 쓰는 기능에 맞습니다.

**개발자가 할 일**: 실행 시점에 몰아 묻지 않기. purpose string은 구체적인 한 문장. 안내 화면을 둔다면 "계속" 버튼 하나.

## 실행 화면과 온보딩

[Launching](https://developer.apple.com/design/human-interface-guidelines/launching) 페이지에서 실행(launching)은 앱을 연 순간부터 첫 화면이 준비될 때까지입니다. 온보딩은 **실행이 끝난 뒤**에 오는 것이고, 실행 경험의 일부가 아닙니다.

실행 화면(launch screen)은 iOS, iPadOS, tvOS에서 필요합니다. macOS, visionOS, watchOS는 필요 없습니다. 실행 화면의 유일한 역할은 앱이 빨리 뜨고 바로 쓸 수 있다는 인상을 주는 것입니다. 그래서 규칙이 이렇습니다.

- **첫 화면과 거의 똑같이** 만듭니다. 다르게 생긴 요소가 있으면 실행 화면에서 첫 화면으로 넘어갈 때 번쩍임이 생깁니다. 첫 화면 전에 단색을 보여 준다면 실행 화면도 그 단색만 둡니다.
- **기기의 현재 방향과 밝게/어둡게 모드에 맞춥니다.**
- **글자를 넣지 않습니다.** 실행 화면의 내용은 바뀌지 않아서 현지화되지 않습니다.
- **광고하지 않습니다.** 스플래시 화면이나 "정보" 창처럼 보이게 만들지 않고, 첫 화면에 고정으로 있는 것이 아니면 로고도 넣지 않습니다.
- 다시 시작했을 때 **이전 상태를 복원해** 하던 곳에서 이어 가게 합니다. 스크롤 위치까지 되살릴 수 있으면 좋습니다.

브랜드를 보여 주는 스플래시 화면이 꼭 필요하다면 온보딩 흐름의 시작에 짧게 둡니다.

온보딩 규칙은 Onboarding 페이지에 있습니다.

- 사람이 써 보는 것만으로 이해할 수 있는 앱이 가장 좋습니다. 온보딩이 필요하다면 **빠르고 재미있고 선택할 수 있게** 만듭니다.
- 설명을 보여 주기보다 **직접 해 보며 배우게** 합니다.
- 한 번에 몰아 가르치는 대신 **상황에 맞는 팁**을 그 화면 근처에 보여 주는 것을 고려합니다.
- 튜토리얼을 건너뛰었다면 다음 실행 때 다시 띄우지 않되, 도움말이나 설정에서 다시 찾을 수 있게 둡니다.
- **시스템이나 기기 사용법은 가르치지 않습니다.** 앱이 주는 경험에 집중합니다.
- 큰 다운로드 때문에 시작을 막지 않고, 필수가 아닌 설정 단계는 뒤로 미루고 합리적인 기본값을 줍니다. 평점이나 구매 요청은 앱을 충분히 써 본 뒤에 합니다.

**개발자가 할 일**: 실행 화면은 첫 화면의 빈 틀로. 글자는 넣지 않고, 로고는 첫 화면에 고정으로 있는 것일 때만. 온보딩은 실행 뒤, 짧게, 건너뛸 수 있게.

## 웹·크로스플랫폼 개발자를 위한 대응표

웹 화면이 iPhone에서도 자연스럽게 보이게 하려면 위 규칙을 웹 기술로 옮겨야 합니다. 아래 표의 웹 쪽 내용은 MDN, W3C(WCAG 2.2), WebKit 문서에서 확인한 것만 적었고, 각 행에 근거 링크를 달았습니다.

| HIG 규칙 | 웹에서 쓰는 것 | 근거와 주의 |
|---|---|---|
| 터치 영역 44×44pt | `min-width: 44px; min-height: 44px` | WCAG 2.2의 [Target Size (Enhanced)](https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html)(AAA)가 44×44 CSS px, [Target Size (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)(AA)가 24×24 CSS px입니다. 두 기준 모두 같은 기능을 하는 충분히 큰 컨트롤이 따로 있거나 문장 속 링크인 경우 같은 예외를 둡니다. **CSS의 `pt`는 Apple의 pt와 다른 단위**입니다. CSS에서는 1in = 72pt = 96px이라 `44pt`라고 쓰면 약 58.7px가 됩니다 ([MDN length](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Values/length)) |
| safe area | `viewport-fit=cover` + `env(safe-area-inset-*)` | `cover`는 뷰포트를 기기 화면 전체로 넓히므로, [MDN viewport](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/meta/name/viewport)는 safe area inset 값으로 중요한 콘텐츠가 가려지지 않게 하라고 강하게 권합니다. [MDN env()](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Values/env) 설명으로는 뷰포트가 직사각형이고 툴바나 키보드 같은 요소가 뷰포트 공간을 차지하지 않을 때 0이고, 그 밖에는 0보다 큰 px 값입니다. 값을 짐작하지 말고 브라우저가 주는 값을 그대로 씁니다 |
| 다크 모드 | `prefers-color-scheme`, `color-scheme` | `color-scheme`을 선언하면 브라우저가 스크롤바·폼 컨트롤 같은 기본 UI 색을 맞춰 줍니다. 나머지 요소는 `prefers-color-scheme`으로 직접 처리합니다 ([MDN color-scheme](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/color-scheme), [MDN prefers-color-scheme](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-color-scheme)) |
| 움직임 줄이기(Reduce Motion) | `prefers-reduced-motion: reduce` | 기기에서 움직임 줄이기 설정을 켰는지 알려 줍니다 ([MDN prefers-reduced-motion](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-reduced-motion)) |
| 글자 크기 조절 | `rem`, `em` 같은 상대 단위 | MDN은 사용자가 기본 글꼴 크기를 키우는 경우가 많으니 `font-size`에 절대 길이 대신 상대 길이를 쓰라고 권합니다. `rem`은 루트 요소의 글자 크기 기준입니다 ([MDN length](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Values/length)) |
| 대비 4.5:1, 3:1 | 일반 글자 4.5:1, 큰 글자 3:1 | 큰 글자는 18pt 이상 또는 굵은 14pt 이상(CSS pt, 약 24px·18.5px)입니다. HIG 표의 "굵은 글자 3:1"을 크기 조건 없이 옮기지 않습니다 ([WCAG Contrast (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)) |

Apple의 pt와 CSS의 px는 둘 다 기기 픽셀과 분리된 추상 단위입니다. HIG의 [Images](https://developer.apple.com/design/human-interface-guidelines/images) 페이지는 2D 플랫폼에서 1pt가 화면 해상도에 따라 여러 픽셀에 대응한다고 하고, MDN은 고해상도 화면에서 1 CSS px가 여러 기기 픽셀에 대응한다고 합니다. 하지만 iPhone Safari에서 1 CSS px = 1pt라고 못 박은 공식 문서는 이번에 찾지 못했습니다. 그래서 "44pt는 44px"를 사실로 적지는 않습니다. 웹에서는 WCAG AAA 목표인 44×44 CSS px로 시작하되 실제 기기에서 확인하는 것을 권합니다.

iOS의 Dynamic Type을 웹에서 따라가는 방법도 있습니다. WebKit 블로그의 2015년 글 [Using the System Font in Web Content](https://webkit.org/blog/3709/using-the-system-font-in-web-content/)는 `font: -apple-system-body` 같은 값으로 iOS의 Dynamic Type 글자 스타일을 웹에서 쓸 수 있다고 소개합니다. 오래된 글이고 WebKit 전용 값이라, 쓴다면 지금 버전의 iOS Safari에서 직접 확인해야 합니다.

채팅 화면의 아래쪽 입력창을 예로 들면 이렇게 됩니다.

```html
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
```

```css
:root {
  color-scheme: light dark;          /* 폼 컨트롤·스크롤바 색을 모드에 맞춤 */
}

.composer {
  position: sticky;
  bottom: 0;
  /* 홈 인디케이터 영역만큼 띄우고, inset이 0이면 기본 여백 */
  padding-bottom: max(12px, env(safe-area-inset-bottom));
  /* 가로 화면에서 노치·둥근 모서리 쪽 여백 */
  padding-left: max(12px, env(safe-area-inset-left));
  padding-right: max(12px, env(safe-area-inset-right));
  font-size: 1rem;                   /* 루트 요소의 글자 크기를 따름 */
}

.composer button {
  min-width: 44px;                   /* 44pt가 아니라 44px */
  min-height: 44px;
}

@media (prefers-color-scheme: dark) {
  .composer { background: #1c1c1e; }
}

@media (prefers-reduced-motion: reduce) {
  .message { animation: none; }      /* 새 메시지 등장 애니메이션 끄기 */
}
```

`max(12px, env(...))`는 inset이 0일 때도 기본 여백을 남기기 위해서입니다. 이 쓰임은 WebKit 블로그의 [Designing Websites for iPhone X](https://webkit.org/blog/7929/designing-websites-for-iphone-x/)에도 나옵니다. `1rem`은 루트 요소의 글자 크기라서, 루트 글자 크기를 px로 고정해 두면 사용자가 바꾼 브라우저 기본 글자 크기와 달라질 수 있습니다. iOS의 Dynamic Type과 자동으로 이어지는 값도 아닙니다.

이 CSS는 문법만 확인했고 실제 iPhone Safari에서는 확인하지 않았습니다. 입력창이 키보드 위로 제대로 올라오는지도 이 예시로는 알 수 없으니 실제 기기에서 봐야 합니다.

## 다시 채팅 화면 설계로: 그때 건너뛴 것과 주의할 점

처음의 결정으로 돌아가 보겠습니다. 그때는 HIG 세 페이지를 "지식으로만 기록"하고 넘어갔습니다. 다시 읽어 보니 채팅 화면에 바로 걸리는 규칙이 꽤 많았습니다.

- **메시지 한 줄**: 큰 글자에서는 본문 옆의 시각을 아래로 내리는 쌓인 배치. Typography 페이지가 타임스탬프를 예로 들 만큼 흔한 문제입니다.
- **아래쪽 입력창**: safe area 안쪽에 두되 배경은 화면 끝까지. 웹이라면 `env(safe-area-inset-bottom)`.
- **보내기·첨부 버튼**: 아이콘 버튼이라 터치 영역이 작아지기 쉬우니 iOS는 44×44pt 이상, 웹은 WCAG AAA 목표인 44×44 CSS px를 출발점으로. 아이콘만 있으니 접근성 라벨도.
- **말풍선 색**: 시맨틱 색이나 두 모드 변형이 있는 색으로, 양쪽 모드에서 대비 확인.
- **음성 입력**: 앱을 열 때가 아니라 마이크 버튼을 누른 순간에 권한 요청.
- **새 메시지 애니메이션**: 움직임 줄이기 설정에서는 끄거나 페이드로.

그리고 이번에 얻은 주의할 점입니다.

1. **"지식으로만 기록"은 "확인 안 함"으로 적습니다.** 기억으로 아는 숫자는 맥락이 빠지기 쉽습니다. 44×44pt가 Accessibility 표에서는 iOS 컨트롤의 "기본" 크기이고, 버튼의 터치 영역 권고는 Buttons 페이지에 따로 있다는 구분이 그런 예입니다. 기준 숫자는 원문 표에서 행과 열을 짝지어 확인합니다.
2. **문서 도구가 실패하면 원인을 나눠 봅니다.** 본문이 JavaScript로 채워지는 페이지인지, 주소가 바뀌었는지(`navigation-bars` → `toolbars`), 정말 없는 페이지인지를 따로 확인합니다. 셋은 해결 방법이 다릅니다.
3. **HIG는 바뀝니다.** 이번에 읽은 Layout 페이지의 변경 기록 맨 위는 2026년 9월 9일 갱신이었고, Liquid Glass 관련 지침은 2025년에 추가됐습니다. 이 글의 내용도 2026년 11월 5일 기준입니다. 구현 전에는 각 페이지 맨 아래의 변경 기록(Change log)을 봅니다.
4. **시스템 것을 먼저 씁니다.** 직접 만든 컨트롤, 직접 넣은 글꼴, 직접 고른 색에서 규칙이 깨집니다. 직접 만들기로 했다면 Dynamic Type, 두 모드, 대비 높이기, 터치 영역을 직접 챙겨야 합니다.
5. **웹으로 옮길 때 단위를 조심합니다.** CSS에 `44pt`라고 쓰면 의도보다 커집니다.

## 정리: 출시 전 체크리스트

| 항목 | 확인할 것 | 원문 |
|---|---|---|
| safe area | 글자·버튼이 상태 바·툴바·탭 바·Dynamic Island에 가리지 않는가. 배경은 끝까지 깔렸는가 | [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) |
| 크기 변화 | 회전, 창 크기 변경, 크기 클래스 조합에서 기능이 그대로인가 | [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) |
| 터치 영역 | 직접 만든 버튼의 터치 영역이 44×44pt 이상인가. 간격은 충분한가 | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) |
| 글자 | text style을 쓰는가. 가장 큰 접근성 크기에서 잘림·겹침이 없는가 | [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) |
| 대비 | 앱: HIG 표 기준을 두 모드 모두에서 맞추는가(작고 굵은 글자는 4.5:1로). 웹: 일반 글자 4.5:1, 큰 글자(18pt 이상 또는 굵은 14pt 이상, CSS pt) 3:1인가 | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [WCAG](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) |
| 색 | 시스템·시맨틱 색을 쓰는가. 색 값을 코드에 박지 않았는가. 색만으로 상태를 알리지 않는가 | [Color](https://developer.apple.com/design/human-interface-guidelines/color), [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) |
| 재질 | 콘텐츠 층에 Liquid Glass를 쓰지 않았는가. 시스템 막대에 직접 배경을 칠하지 않았는가 | [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| 아이콘 | SF Symbols를 먼저 쓰는가. 최소 지원 OS에 그 기호가 있는가 | [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) |
| 탐색 | 탭은 이동만 하는가. 동작은 툴바에 있는가. 탭 바가 늘 보이는가(모달이 덮을 때는 예외) | [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) |
| 시트 | 취소·완료·뒤로의 역할이 맞는가. 시트 위에 시트를 쌓지 않는가 | [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) |
| 권한 | 기능을 쓰는 순간에 묻는가. purpose string이 구체적인 문장인가. 안내 화면 버튼은 "계속" 하나인가 | [Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy) |
| 실행·온보딩 | 실행 화면이 첫 화면과 같은가(글자 없음, 로고는 첫 화면에 고정으로 있을 때만). 온보딩은 실행 뒤, 건너뛸 수 있는가 | [Launching](https://developer.apple.com/design/human-interface-guidelines/launching), [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding) |
| 웹 | `viewport-fit=cover`를 썼다면 `env(safe-area-inset-*)`를 함께 썼는가. `prefers-color-scheme`, `prefers-reduced-motion`에 반응하는가 | [MDN env()](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Values/env), [MDN viewport](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/meta/name/viewport) |

HIG 전체를 외울 필요는 없습니다. 시스템 컴포넌트를 쓰면 대부분은 이미 지켜지고, 개발자가 챙길 것은 직접 만든 부분에서 시스템이 해 주던 일을 대신 하는 것입니다. 그리고 숫자가 필요할 때는 기억 대신 원문 표를 엽니다.
