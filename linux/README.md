# AI Usage Widget (Linux)

Claude Code와 Codex의 남은 사용량을 Linux 바탕화면에 항상 띄워 두는 작은 위젯입니다.
5시간 창과 7일 창의 남은 퍼센트, 그리고 각 창이 초기화되기까지 남은 시간을 보여 줍니다.

## 설치

Claude Code나 Codex CLI에 로그인되어 있으면 됩니다.
저장소를 clone 한 폴더(저장소 루트)에서 아래 한 줄을 실행하십시오.

```bash
linux/install.sh
```

토큰 파일과 CLI 경로를 찾고, 로그인할 때 자동으로 시작되도록 등록한 뒤 위젯을 띄웁니다.
여러 번 실행해도 안전하며, 업데이트할 때도 같은 명령을 씁니다.

설치 출력의 `Token locations:` 아래에 `"token_found": false` 가 보인다면 그 CLI에 아직 로그인하지 않은 상태입니다.
로그인한 뒤 다시 실행하십시오.

Ubuntu 24.04 GNOME 기본 설치에 들어 있는 시스템 Python과 GTK 3만 사용하므로, 따로 설치할 패키지는 없습니다.
다른 배포판에서 GTK 3 바인딩이 없다고 나오면 안내된 명령으로 설치하십시오.
Wayland 세션에서는 XWayland를 거쳐 실행되도록 만들었지만, 아직 Wayland 세션에서 확인하지는 못했습니다.

## 사용

창을 끌어서 옮기면 그 위치가 저장됩니다. 오른쪽 클릭하면 갱신 주기와 투명도(없음, 15%, 30%, 45%)를 바꾸거나,
즉시 갱신하거나, 종료할 수 있습니다. 선택한 값은 다음 실행에도 그대로 유지됩니다.

### 상단바로 숨기기

오른쪽 클릭 메뉴에서 `상단바로 숨기기` 를 누르면 창이 사라지고, 화면 맨 위 상단바의 오른쪽에 사용량이 표시됩니다.
서비스마다 로고, `5h`/`7d` 표시, 남은 퍼센트, 초기화까지 남은 시간(`25m`, `3h`, `2d`)이 나옵니다.
색상 기준은 창에 표시되는 막대와 같습니다.

창으로 되돌리려면 상단바 표시를 클릭하고 메뉴에서 `위젯 보이기` 를 누르십시오. 가운데 버튼으로 클릭하거나,
프로그램 목록에서 `AI Usage Widget` 을 다시 실행해도 창이 돌아옵니다. 숨긴 상태는 다음 로그인에도 유지됩니다.

이 기능은 Ubuntu에 기본으로 켜져 있는 AppIndicator 확장(`ubuntu-appindicators`)이 있어야 동작합니다.
확장이 꺼져 있으면 메뉴 항목이 비활성화되고, 숨긴 상태에서 확장이 꺼지면 창이 자동으로 다시 나타납니다.

명령으로 다룰 일이 있다면 아래처럼 실행하십시오. 경로는 XDG 기본 위치 기준입니다.

```bash
w=~/.local/share/ai-usage-widget/ai-usage-widget.py

/usr/bin/python3 "$w" --stop         # 종료
/usr/bin/python3 "$w" --configure    # 토큰 파일과 CLI 경로를 다시 찾고 결과 출력
/usr/bin/python3 "$w" --fetch-only   # 화면 없이 사용량만 JSON 으로 출력
```

프로그램 목록에서 `AI Usage Widget` 을 검색하면 다시 띄울 수 있습니다.
이미 실행 중일 때 누르면 재시작하지 않고, 상단바로 숨긴 창만 다시 보여 줍니다. 재시작할 때마다 API를 호출하기 때문에
짧은 시간에 여러 번 재시작하면 응답이 거부될 수 있어서 그렇게 만들었습니다.

## 설정

설치할 때 `~/.config/ai-usage-widget/config.json` 이 자동으로 만들어지므로 보통은 건드릴 일이 없습니다.

```json
{
  "claude": { "enabled": true, "token_file": "/home/you/.claude/.credentials.json", "cli": "/home/you/.local/bin/claude" },
  "codex": { "enabled": false, "token_file": "/home/you/.codex/auth.json", "cli": "" }
}
```

**한쪽 CLI만 쓴다면 나머지의 `enabled` 를 `false` 로 두십시오.** 위젯에서 그 줄이 사라지고 API도 호출하지 않습니다.
파일을 고친 뒤에는 `--stop` 으로 종료했다가 다시 띄우면 반영됩니다. `--configure` 를 다시 실행해도 `enabled` 값은 유지됩니다.

`CLAUDE_CONFIG_DIR` 이나 `CODEX_HOME` 환경 변수를 쓴다면, 그 변수가 설정된 터미널에서 설치 스크립트나 `--configure` 를 실행하십시오.

## 문제가 생기면

| 증상 | 확인할 것 |
| --- | --- |
| `설정 필요` 로 표시됨 | 그 CLI에 로그인한 뒤 `--configure` 를 실행하십시오. |
| `토큰 만료` 가 계속됨 | `widget.log` 의 `stderr` 줄을 보십시오. 갱신 시도는 서비스마다 15분에 한 번입니다. `config.json` 의 `cli` 가 비어 있다면 `--configure` 를 실행하십시오. |
| `오류: http 429` 로 표시됨 | 사용량 API가 요청을 제한한 상태입니다. 위젯은 그 서비스의 호출을 10분(계속되면 최대 30분) 쉬었다가 다시 시도하고, 그동안 마지막 값을 회색으로 보여 줍니다. 갱신 주기를 짧게 바꾸거나 여러 번 재시작하면 더 오래 막힐 수 있습니다. |
| 창을 엉뚱한 곳에 두었음 | 종료한 뒤 `state.json` 을 지우면 기본 모니터의 오른쪽 아래로 돌아옵니다. |
| 창이 뜨지 않음 | 터미널에서 `/usr/bin/python3 "$w" --force` 로 실행해 오류 메시지를 확인하십시오. |

로그와 상태 파일은 `~/.local/state/ai-usage-widget/` 에 있습니다.

## 제거

```bash
~/.local/share/ai-usage-widget/uninstall.sh
```

자동 시작 항목, 프로그램 목록 항목, 설치 폴더, 설정과 상태 파일을 지웁니다. 토큰 파일은 건드리지 않습니다.

## 알아 둘 점

토큰과 개인정보를 다루는 방식, 비공식 API와 로고에 관한 안내는 [저장소 README](../README.md#알아-둘-점) 에 있습니다.

개발자와 에이전트를 위한 지침은 이 폴더의 [AGENTS.md](./AGENTS.md) 와 저장소 루트의 [AGENTS.md](../AGENTS.md) 에 있습니다.
