# AGENTS.md

이 저장소에서 작업하는 모든 에이전트(Claude Code, Codex 등)를 위한 지침입니다.
코드와 git 히스토리만으로는 알 수 없는 사실과 결정 사항을 기록합니다.

## 1. 프로젝트 목적

Windows 11 데스크톱에 항상 떠 있는 작은 위젯으로, Claude Code와 Codex의
구독 사용량(5시간 창, 7일 창)의 **남은 퍼센트**와 리셋까지 남은 시간을 표시합니다.
개발은 WSL(Ubuntu)에서 하고, 실행은 Windows 호스트에서 합니다.

저장소를 clone 한 다른 사용자도 수정 없이 쓸 수 있어야 합니다. 따라서 경로, 배포판 이름,
사용자명처럼 머신마다 달라지는 값을 코드에 적어 넣지 마십시오. 사용자용 안내는 README.md 에 있습니다.

## 2. 아키텍처 결정 (되돌리지 말 것)

- **단일 PowerShell 스크립트 + WPF** 로 만듭니다. Windows 쪽에 아무것도 설치하지 않습니다.
- 토큰 파일은 **읽기만** 합니다. 파일의 위치는 실행할 때 결정하며 코드에 고정하지 않습니다
  (바로 아래 항목 참고). API는 CLI를 거치지 않고 PowerShell의 `Invoke-RestMethod` 로 직접 호출합니다.
- **토큰 위치는 서비스마다 따로 결정합니다.** Claude는 WSL에 있고 Codex는 Windows에 있는 구성도
  가능하기 때문입니다. 각 서비스의 소스는 `wsl`, `windows`, `off` 중 하나입니다.
  - 결정 순서: `-WslDistro`/`-WslUser` 파라미터 → `config.json` → 자동 감지.
  - 자동 감지는 레지스트리 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss` 에서 배포판 목록을
    읽습니다. `wsl.exe -l` 은 목록을 얻으려고 WSL 서비스를 깨우지만 레지스트리는 그렇지 않습니다.
    그다음 Windows 프로필과 모든 WSL 홈에서 토큰 파일을 찾아 **가장 최근에 기록된 것**을 고릅니다.
    실제로 사용하는 설치본이 토큰을 갱신하므로 수정 시각이 곧 사용 중이라는 신호입니다.
  - 결과는 `config.json` 에 캐시하므로 평소 실행에서는 탐색하지 않습니다. `-Configure` 로 다시 감지합니다.
  - 접근 권한이 없는 홈(다른 사용자나 root의 홈)에서 `Test-Path` 는 `UnauthorizedAccessException` 을
    던지고, `$ErrorActionPreference = 'Stop'` 이라 스크립트가 중단됩니다. 우리가 소유하지 않은 경로를
    검사할 때에는 반드시 `Test-PathSafe` 를, 파일 시각을 얻을 때에는 `Get-FileWrittenAt` 를 사용하십시오.
  - `windows` 소스는 아직 실환경에서 검증하지 못했습니다(2026-09-09 기준). 이 개발 머신의 Windows 홈에는
    두 CLI의 자격 증명 파일이 없어서 확인할 수 없었습니다. 확인되면 이 줄을 갱신하십시오.
- **토큰 갱신은 만료를 감지했을 때 한 번만** 해당 서비스의 CLI를 호출해서 처리합니다.
  - 명령: `claude -p "ok" --model haiku`
  - 실행 위치는 그 서비스의 소스를 따릅니다. `wsl` 이면 `wsl.exe -d <배포판> -u <사용자> -- bash -lc "<명령>"`,
    `windows` 이면 `cmd.exe /c <명령>` 으로 실행합니다. `cmd.exe` 를 거치는 이유는 npm 전역 설치의
    `claude.cmd` 와 네이티브 실행 파일을 모두 PATH에서 찾아 주기 때문입니다.
  - Claude Code는 요청을 보내기 직전에 만료된 토큰을 갱신하므로, 최소 메시지 한 건이 곧 갱신 수단입니다.
  - `claude auth status` 는 저장된 자격 증명을 출력만 하고 갱신하지 않습니다(위젯 로그 8회 시도 중 0회 갱신, 2026-09-07 확인).
    한때 1순위로 썼으나 30초만 낭비해서 제거했습니다.
- 갱신 명령의 표준 오류는 마지막 3줄을 위젯 로그에 남깁니다(이메일은 가림). 갱신 실패 원인을 진단하는 용도입니다.
- 위젯이 **refresh_token으로 직접 토큰을 갱신하지 않습니다.** Claude Code와 동시에 갱신하면
  서로의 토큰을 무효화할 수 있습니다.
- **주기적인 headless 메시지 전송은 하지 않습니다.** 사용량을 소모하고 세션 기록이 쌓입니다.
- Codex 토큰도 같은 원칙으로, **만료를 감지했을 때 한 번만** Codex CLI를 호출해서 갱신합니다.
  - 명령: `codex doctor --summary` (실행 위치는 Claude와 같은 규칙을 따릅니다)
  - 근거(codex-rs `login/src/auth/manager.rs`): `doctor` 가 `AuthManager::auth()` 를 호출하고,
    이 함수는 access token 만료 5분 전이거나 `last_refresh` 가 8일이 지났으면 refresh_token으로 갱신합니다.
    모델 요청을 보내지 않으므로 사용량을 소모하지 않습니다. `codex login status` 는 파일만 읽고 갱신하지 않습니다.
  - 실제로 갱신되는지는 아직 실환경에서 확인하지 못했습니다(2026-09-07 기준). 확인되면 이 줄을 갱신하십시오.
- 갱신 쿨다운(15분)은 서비스별로 따로 적용됩니다. Claude 갱신 시도가 Codex 갱신을 막지 않습니다.
- API를 호출하지 못하는 동안에는 마지막 값을 유지하고, 리셋 시각이 지나면 로컬에서 0% 사용으로 되돌립니다.
- **위젯은 한 번에 하나만 실행됩니다.** 이미 실행 중인데 다시 실행하면, 새 프로세스는 로그를 남기고 즉시 종료합니다.
  위젯은 항상 최상위(`Topmost`)로 떠 있으므로 창을 앞으로 가져오는 처리는 하지 않습니다.
  재시작할 때마다 즉시 API를 호출하기 때문에, 짧은 시간에 여러 번 재시작하면 HTTP 429 가 발생합니다.
  의도적으로 교체해야 하는 설치 과정에서만 `-Force` 를 사용합니다.

## 3. 환경 사실

이 프로젝트가 전제하는 호스트 환경입니다. 사용자명, 배포판 이름, 절대 경로처럼 머신마다 달라지는
값은 자동 감지와 `config.json` 이 결정하므로 **코드에도 이 문서에도 적어 넣지 마십시오.**
지금 인식된 값을 알아야 한다면 `-Configure` 출력을 보면 됩니다.

- 호스트: Windows 11 Pro. **Windows PowerShell 5.1만 존재.**
  pwsh 7, Node, 실제 Python(Store 스텁만 있음), .NET SDK, Rainmeter 는 **없습니다.**
- Windows 사용자 홈은 `%USERPROFILE%`, WSL에서는 `/mnt/c/Users/<Windows 사용자>` 입니다.
- WSL 홈은 Windows에서 `\\wsl.localhost\<배포판>\home\<사용자>` 로 보입니다. 이 개발 머신에서는
  자동 감지가 두 서비스 모두 WSL 홈을 찾아냅니다(2026-09-09 확인).
- WSL에서 `powershell.exe`를 부를 때는 **먼저 `cd /mnt/c`** 를 해야 UNC 작업 디렉터리 경고가 나지 않습니다.
  항상 `-NoProfile` 을 붙이고, 출력은 `| tr -d '\r'` 로 정리합니다. 한글 오류 메시지는 코드페이지 때문에 깨져 보일 수 있습니다.
- Windows → WSL 호출(`wsl.exe -d <배포판> -u <사용자> -- <cmd>`) 지연은 약 0.2초입니다.
- 시작 프로그램 폴더는 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` 입니다.
  설치 스크립트는 여기와 시작 메뉴(`...\Programs`)에 같은 바로가기 `AI Usage Widget.lnk` 를 만듭니다.

## 4. 데이터 소스 (비공식 API)

두 엔드포인트 모두 각 CLI가 내부적으로 쓰는 비공식 API입니다. 예고 없이 바뀔 수 있으므로,
필드가 없거나 형식이 다르면 예외를 내지 말고 **오류 상태로 표시**합니다.

아래에서 `~` 는 그 서비스의 소스가 가리키는 홈입니다. `wsl` 이면 WSL 홈을 UNC로 접근한 경로이고,
`windows` 이면 `%USERPROFILE%` 입니다.

### Claude Code
- 토큰 파일: `~/.claude/.credentials.json` → `claudeAiOauth.accessToken`, `claudeAiOauth.expiresAt` (epoch ms)
- 요청: `GET https://api.anthropic.com/api/oauth/usage`
  - 헤더: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`
- 사용하는 응답 필드:
  - `five_hour.utilization` (사용 %, 0~100), `five_hour.resets_at` (ISO 8601)
  - `seven_day.utilization`, `seven_day.resets_at`
- access token 수명은 약 8시간입니다. Claude Code가 API를 호출할 때 만료 근처면 스스로 갱신하고 파일을 다시 씁니다.

### Codex
- 토큰 파일: `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id`
- 요청: `GET https://chatgpt.com/backend-api/wham/usage`
  - 헤더: `Authorization: Bearer <access_token>`, `ChatGPT-Account-ID: <account_id>`
- access token은 JWT이며 `exp` 클레임으로 만료를 판단합니다(수명 약 10일, `id_token` 은 1시간이지만 사용하지 않음).
  `auth.json` 의 `last_refresh` 는 Codex CLI가 마지막으로 갱신한 시각입니다.
- 사용하는 응답 필드:
  - `rate_limit.primary_window.used_percent`, `rate_limit.primary_window.reset_at` (epoch s) — 5시간 창
  - `rate_limit.secondary_window.used_percent`, `rate_limit.secondary_window.reset_at` — 7일 창
- 응답에 `email`, `user_id`, `account_id` 가 포함됩니다. **표시하거나 저장하지 않습니다.**

표시 값은 `100 - 사용%` 인 **남은 퍼센트** 입니다.

### 로고
- 헤더 로고는 SVG 경로 데이터를 스크립트 안에 내장하고 WPF `Path` 로 그립니다. 이미지 파일을 쓰지 않습니다.
  - Claude: Simple Icons 의 `claude` 아이콘 (CC0 1.0), viewBox 0 0 24 24, 브랜드 색 `#D97757`.
  - Codex: OpenAI 심볼 (Wikimedia Commons `ChatGPT-Logo.svg`, 단일 path, viewBox 0 0 320 320), 어두운 배경 위에 흰색.
- 두 로고 모두 각 회사의 상표이며 개인용 위젯에서만 사용합니다. 색이나 형태를 변형하지 않습니다.

## 5. 보안과 개인정보 규칙 (필수)

- 토큰 파일은 **읽기 전용**입니다. 어떤 경우에도 쓰거나 이동하거나 삭제하지 않습니다.
- 토큰 값, refresh token, account id, 이메일을 **로그, 화면, 파일, 대화 출력, 커밋**에 남기지 않습니다.
  디버깅 출력이 필요하면 키 이름만 출력하거나 값을 마스킹합니다.
- API 응답 원문을 디스크에 저장하지 않습니다. 상태 파일에는 퍼센트, 리셋 시각, 마지막 갱신 시각, 창 위치만 저장합니다.
- `.credentials.json`, `auth.json`, 상태 파일, 스크래치 결과는 저장소에 포함하지 않습니다 (`.gitignore` 유지).
- `config.json` 에는 WSL 배포판 이름과 리눅스 사용자명이 들어갑니다. 자격 증명은 아니지만 개인 환경
  정보이므로 저장소에 넣지 않습니다. `-Configure` 출력에도 경로만 담고 토큰 값은 담지 않습니다.

## 6. PowerShell 5.1 호환 규칙

- PowerShell 7 전용 문법 금지: 삼항 연산자 `? :`, null 병합 `??`, `ForEach-Object -Parallel`, `Get-Error`, `-SkipHttpErrorCheck` 등.
- **한글이 들어가는 `.ps1` 파일은 반드시 UTF-8 with BOM 으로 저장**합니다. 5.1은 BOM 없는 UTF-8을 ANSI로 읽어 한글이 깨집니다.
  WSL에서 파일을 쓸 때 BOM을 붙이는 것을 잊지 마십시오. 위젯 UI 문구는 한국어입니다.
- WPF는 **STA 스레드** 가 필요하므로 실행 시 `-STA` 옵션을 붙입니다.
- `Invoke-RestMethod` 에는 항상 `-TimeoutSec` 을 지정하고, 호출 전에 `[Net.ServicePointManager]::SecurityProtocol` 에 TLS 1.2를 포함시킵니다.
- 타이머는 `System.Windows.Threading.DispatcherTimer` 를 사용합니다 (UI 스레드에서 안전).
- **변수명은 대소문자를 구분하지 않습니다.** 스크립트 최상위에서 `$ui` 와 `$script:Ui` 는 같은 변수입니다.
  스크립트 범위 변수와 루프 지역 변수는 이름을 완전히 다르게 짓습니다 (예: `$script:Views` 와 `$view`).
- 문자열 `'--%'` 는 따옴표 안이라도 파싱 중단 기호로 해석될 수 있습니다. `--%` 로 시작하는 리터럴을 쓰지 않습니다.
- `$ErrorActionPreference = 'Stop'` 상태에서 타이머 tick 이나 이벤트 처리기 안의 예외는 프로세스를 조용히 종료시킵니다.
  모든 처리기는 try/catch 로 감싸고 `Write-Log` 로 남기며, `Dispatcher.UnhandledException` 처리기를 마지막 안전망으로 둡니다.
- `WS_EX_TOOLWINDOW` 를 적용한 창은 `Process.MainWindowTitle` 이 비어 있습니다. 실행 중 인스턴스 탐지는 `widget.pid` 를 기준으로 합니다.
- `Window.DragMove()` 는 드래그가 끝날 때까지 블로킹되고 `MouseLeftButtonUp` 을 삼킵니다. 위치 저장은 `DragMove` 반환 직후에 합니다.
- 자동 변수 `$host`, `$input`, `$args` 등을 지역 변수 이름으로 쓰지 않습니다.
- `ai-usage-widget.ps1` 은 UI 문구가 한국어이므로 **UTF-8 BOM** 으로 저장되어 있습니다. Python 으로 편집할 때는
  `encoding='utf-8-sig'` 로 읽고 쓰며, sed 등으로 편집한 뒤에는 `head -c3 | xxd` 로 BOM(`ef bb bf`)이 남아 있는지 확인합니다.
- Hangul 폰트 폴백을 위해 FontFamily 는 `'Segoe UI, Malgun Gothic'` 으로 지정합니다.

## 7. 파일 구성과 배포 흐름

```
README.md             # 사용자용 설치와 설정 안내 (clone 한 사람이 읽는 문서)
ai-usage-widget.ps1   # 위젯 본체 (UI + 수집 + 갱신)
ai-usage-widget.ico   # 바로가기 아이콘 (생성물이지만 저장소에 포함)
install.ps1           # Windows 쪽 폴더로 복사, 시작 프로그램 바로가기 등록, 실행 중인 위젯 재시작
uninstall.ps1         # 바로가기 제거, 위젯 종료
tools/capture-widget.ps1  # 개발용: 위젯 창을 PNG 로 캡처 (설치 대상 아님)
tools/make-icon.py    # 개발용: 아이콘을 코드로 렌더링 (설치 대상 아님)
AGENTS.md / CLAUDE.md # 이 지침
```

- 바로가기에는 `-Force` 를 넣지 않습니다. 넣으면 시작 메뉴에서 누를 때마다 위젯이 재시작됩니다.
  설치 스크립트가 직접 실행할 때에만 `-Force` 를 붙입니다.
- 아이콘은 Windows 에 이미지 도구가 없으므로 WSL 의 Python 표준 라이브러리만으로 렌더링합니다
  (`python3 tools/make-icon.py`). 부호 있는 거리 함수로 그려서 별도 라이브러리 없이 계단 현상을 없앱니다.
  16~48px 는 단일 링, 64px 이상은 이중 링으로 분기합니다. 작은 크기에서 두 링이 뭉개지기 때문입니다.
  아이콘을 다시 만들면 Windows 아이콘 캐시 때문에 화면에 바로 반영되지 않을 수 있습니다.

- 개발은 이 WSL 폴더에서 합니다. 설치 대상 폴더는 `%LOCALAPPDATA%\ai-usage-widget\` 입니다.
- 상태 파일: `%LOCALAPPDATA%\ai-usage-widget\state.json` (창 위치, 마지막 값), `widget.pid` (실행 중인 프로세스 ID),
  `config.json` (토큰 위치). 설치 스크립트가 `-Configure` 를 호출해 `config.json` 을 만듭니다.
- 위젯 창 제목은 `AI Usage Widget` 으로 고정합니다. 종료 시에는 `widget.pid` 를 우선 사용하고, 없으면 창 제목으로 찾습니다.
- 설치 스크립트는 여러 번 실행해도 안전해야 합니다 (멱등).

## 8. 실행과 검증 방법

WSL에서 위젯을 띄우거나 테스트할 때 사용하는 명령입니다.

`powershell.exe` 를 부르기 전에 `cd /mnt/c` 로 옮겨야 UNC 작업 디렉터리 경고가 나지 않으므로,
저장소의 Windows 경로를 먼저 잡아 둡니다.

```bash
# 이 저장소 루트에서 한 번 실행합니다.
REPO="$(wslpath -w "$PWD")"

# 설치(복사 + 토큰 위치 감지 + 바로가기 등록 + 재시작)
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$REPO\install.ps1" | tr -d '\r'

# 위젯 창을 PNG 로 캡처 (개발용 도구, 설치 대상 아님)
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$REPO\tools\capture-widget.ps1" | tr -d '\r'
```

설치된 위젯을 다룰 때는 **`-Command` 와 bash 작은따옴표**를 씁니다. bash 큰따옴표 안에서는
`$env:LOCALAPPDATA` 를 bash가 먼저 확장해서 경로가 `:LOCALAPPDATA\...` 로 깨집니다.

```bash
# 인식된 토큰 위치를 출력 (경로만 출력, 토큰 값은 출력하지 않음)
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '& "$env:LOCALAPPDATA\ai-usage-widget\ai-usage-widget.ps1" -Configure' | tr -d '\r'

# 화면 없이 수집 결과만 JSON으로 출력 (토큰 값은 출력하지 않음)
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '& "$env:LOCALAPPDATA\ai-usage-widget\ai-usage-widget.ps1" -FetchOnly' | tr -d '\r'

# 위젯 종료
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '& "$env:LOCALAPPDATA\ai-usage-widget\ai-usage-widget.ps1" -Stop' | tr -d '\r'
```

- 위젯 UI를 직접 띄우는 명령은 **프로세스가 살아 있는 동안 반환되지 않습니다.** 재시작이 필요하면
  `install.ps1` 을 쓰십시오. 설치 스크립트는 `Start-Process` 로 띄우고 바로 돌아옵니다.
  굳이 직접 띄워야 한다면 끝에 `&` 를 붙여 배경으로 돌리십시오.
- `-FetchOnly`, `-Stop`, `-Force`, `-Configure` 스위치는 위젯 스크립트가 반드시 지원해야 합니다.
- 화면 확인은 `tools/capture-widget.ps1` 로 **위젯 창 자체를 PrintWindow 로 캡처**합니다. 전체 화면 앱이 덮고 있거나
  위젯이 다른 모니터에 있어도 잡힙니다. 결과는 `%LOCALAPPDATA%\Temp\widget-window.png` 에 저장되며, 출력에 창의 실제 좌표가 함께 나옵니다.
  모니터 구성에 의존하지 않으므로 화면 확인은 이 방법을 우선 사용하십시오.
- 화면 전체 맥락이 필요할 때만 아래처럼 기본 모니터의 오른쪽 아래를 잘라서 캡처합니다.

```bash
cd /mnt/c && powershell.exe -NoProfile -Command 'Add-Type -AssemblyName System.Drawing,System.Windows.Forms; $b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $r=New-Object System.Drawing.Rectangle ($b.Width-480),($b.Height-300),480,300; $bmp=New-Object System.Drawing.Bitmap $r.Width,$r.Height; $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.Location,[System.Drawing.Point]::Empty,$r.Size); $bmp.Save("$env:TEMP\widget-crop.png")'
```

- 시작 오류를 보려면 `-Command 'try { & "<path>" } catch { $_.ScriptStackTrace; $_.Exception.Message }'` 로 실행합니다. `-File` 은 줄 번호를 잃습니다.
- 로그는 `%LOCALAPPDATA%\ai-usage-widget\widget.log` 에 남습니다. 정상 상태에서는 갱신 주기마다 `fetch claude=ok codex=ok` 한 줄이 쌓입니다.
- 변경 후에는 최소한 `-FetchOnly` 가 두 서비스 모두 `ok` 상태를 돌려주는지 확인합니다.

## 9. 언어와 작업 관례

- 사용자에게는 **한국어**로 응답합니다.
- **코드 주석과 커밋 메시지는 영어**로 작성합니다. 커밋 제목은 명령형, 72자 이내.
- 커밋은 사용자가 명시적으로 승인한 뒤에만 합니다.
- 아직 검증하지 않은 사항(예: `codex doctor` 가 만료 토큰을 실제로 갱신하는지)은 검증 후 이 문서를 갱신합니다.
