# AI Usage Widget

Claude Code와 Codex의 남은 사용량을 Windows 바탕화면에 항상 띄워 두는 작은 위젯입니다.
5시간 창과 7일 창의 남은 퍼센트, 그리고 각 창이 초기화되기까지 남은 시간을 보여 줍니다.

## 설치

Claude Code나 Codex CLI에 로그인되어 있으면 됩니다. WSL에 설치했든 Windows에 설치했든 상관없습니다.
저장소를 clone 한 폴더에서 아래 한 줄을 실행하십시오.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

토큰이 어디에 있는지 알아서 찾고, 시작 프로그램에 등록한 뒤 위젯을 띄웁니다.
여러 번 실행해도 안전하며, 업데이트할 때도 같은 명령을 씁니다.

설치 출력의 `Token locations:` 아래에 `"unset"` 이 보인다면 그 CLI에 아직 로그인하지 않은 상태입니다.
로그인한 뒤 다시 실행하십시오.

필요한 것은 Windows 10 이상뿐입니다(PowerShell 5.1이 기본으로 들어 있습니다).
CLI를 WSL에 설치했다면 WSL 2가 필요합니다.

## 사용

창을 끌어서 옮기면 그 위치가 저장됩니다. 오른쪽 클릭하면 갱신 주기를 바꾸거나, 즉시 갱신하거나, 종료할 수 있습니다.

명령으로 다룰 일이 있다면 PowerShell에서 아래처럼 실행하십시오.

```powershell
$w = "$env:LOCALAPPDATA\ai-usage-widget\ai-usage-widget.ps1"

& $w -Stop         # 종료
& $w -Configure    # 토큰 위치를 다시 찾고 결과 출력
& $w -FetchOnly    # 화면 없이 사용량만 JSON 으로 출력
```

시작 메뉴에서 `AI Usage Widget` 을 검색하면 다시 띄울 수 있습니다.
이미 떠 있을 때 눌러도 재시작되지 않습니다. 재시작할 때마다 API를 호출하기 때문에
짧은 시간에 여러 번 재시작하면 응답이 거부될 수 있어서 그렇게 만들었습니다.

## 설정

설치할 때 `%LOCALAPPDATA%\ai-usage-widget\config.json` 이 자동으로 만들어지므로 보통은 건드릴 일이 없습니다.

```json
{
  "wsl": { "distro": "Ubuntu", "user": "yourname" },
  "services": { "claude": "wsl", "codex": "off" }
}
```

각 서비스의 값은 `wsl`(WSL 홈에서 읽음), `windows`(`%USERPROFILE%` 에서 읽음),
`off`(표시하지 않음) 중 하나입니다.

**한쪽 CLI만 쓴다면 나머지를 `off` 로 두십시오.** 위젯에서 그 줄이 사라지고 API도 호출하지 않습니다.
파일을 고친 뒤에는 `& $w -Stop` 으로 종료했다가 시작 메뉴에서 다시 띄우면 반영됩니다.

자동 감지가 엉뚱한 홈을 골랐다면 직접 지정할 수 있습니다.

```powershell
& $w -Configure -WslDistro Ubuntu -WslUser yourname
```

## 문제가 생기면

| 증상 | 확인할 것 |
| --- | --- |
| `설정 필요` 로 표시됨 | 그 CLI에 로그인한 뒤 `& $w -Configure` 를 실행하십시오. |
| `토큰 만료` 가 계속됨 | `widget.log` 의 `stderr` 줄을 보십시오. 갱신 시도는 서비스마다 15분에 한 번입니다. |
| 창을 엉뚱한 곳에 두었음 | 종료한 뒤 `state.json` 을 지우면 기본 모니터의 오른쪽 아래로 돌아옵니다. |

로그와 상태 파일은 모두 `%LOCALAPPDATA%\ai-usage-widget\` 에 있습니다.

## 제거

```powershell
& "$env:LOCALAPPDATA\ai-usage-widget\uninstall.ps1"
```

바로가기와 설치 폴더를 지웁니다. 토큰 파일은 건드리지 않습니다.

## 알아 둘 점

- 토큰 파일은 **읽기만** 합니다. 갱신이 필요하면 각 CLI를 한 번 호출해서 CLI가 스스로 갱신하도록 맡깁니다.
- 화면과 로그와 저장 파일 어디에도 토큰, 이메일, 계정 식별자를 남기지 않습니다.
- 두 CLI가 내부적으로 사용하는 **비공식 API**를 호출합니다. 예고 없이 바뀔 수 있으며,
  그런 경우에는 오류 상태를 표시하고 마지막으로 알려진 값을 유지합니다.
- 헤더 로고는 각 회사의 상표입니다. Claude 아이콘은 Simple Icons(CC0 1.0), OpenAI 심볼은
  Wikimedia Commons에서 가져왔으며 색과 형태를 변형하지 않았습니다.

개발자와 에이전트를 위한 지침은 [AGENTS.md](./AGENTS.md) 에 있습니다.
