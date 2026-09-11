# AI Usage Widget

Claude Code와 Codex의 남은 사용량을 바탕화면에 띄워 두는 작은 위젯입니다.
5시간 창과 7일 창의 남은 퍼센트, 그리고 각 창이 초기화되기까지 남은 시간을 보여 줍니다.

## 플랫폼

| 플랫폼 | 상태 | 설치와 사용 안내 |
| --- | --- | --- |
| Windows 10 이상 | 사용 가능 | [windows/README.md](./windows/README.md) |
| Linux (GNOME) | 사용 가능 (Wayland 세션은 미확인) | [linux/README.md](./linux/README.md) |

## 알아 둘 점

- 토큰 파일은 **읽기만** 합니다. 갱신이 필요하면 각 CLI를 한 번 호출해서 CLI가 스스로 갱신하도록 맡깁니다.
- 화면과 로그와 저장 파일 어디에도 토큰, 이메일, 계정 식별자를 남기지 않습니다.
- 두 CLI가 내부적으로 사용하는 **비공식 API**를 호출합니다. 예고 없이 바뀔 수 있으며,
  그런 경우에는 오류 상태를 표시하고 마지막으로 알려진 값을 유지합니다.
- 헤더 로고는 각 회사의 상표입니다. Claude 아이콘은 Simple Icons(CC0 1.0), OpenAI 심볼은
  Wikimedia Commons에서 가져왔으며 색과 형태를 변형하지 않았습니다.

개발자와 에이전트를 위한 공통 지침은 [AGENTS.md](./AGENTS.md) 에 있습니다.
