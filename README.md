# LLM Usage Monitor

Codex･Claude Desktop Code･Antigravity(agy)の利用状況とリセット時刻を､Windowsのタスクトレイからひと目で確認する軽量モニターです｡推論セッションは起動せず､各サービスが用意している使用量の取得口(メタデータのみ)から読みます｡

## アイコンの見方

プロバイダーごとに1個ずつアイコンを表示します｡Codexは水色､Claudeは橙､Antigravityは紫が基本色です｡

| アイコンの部分 | 表示内容 | 読み方 |
| --- | --- | --- |
| 最外周の白い5区画 | 5時間枠のリセットまでの時間 | 約1時間ごとに1区画減り､リセット時刻を過ぎると0区画になります |
| 太いリング | 5時間枠の使用率 | 上から時計回りに増えます |
| 中央の円グラフ | 週間枠の使用率 | 上から時計回りに増えます |
| 四隅(Claudeのみ) | Fableの週次上限の使用率 | 円の外側の四隅を､上中央から時計回りに塗ります |

最外周の5区画は｢各1時間の使用量｣ではなく､現在の5時間枠がリセットされるまでの残り時間です｡リセット時刻を取得できない場合は灰色で表示します｡

リングと円グラフの未使用部分は､プロバイダーの基本色を中くらいの明るさにした色です｡使用部分は使用率に応じて次のように変わります｡

| 使用率 | Codex | Claude | Antigravity |
| --- | --- | --- | --- |
| 70%未満 | 水色 | 橙 | 薄紫 |
| 70%以上 | 琥珀 | 黄 | 琥珀 |
| 90%以上 | 赤 | 赤 | 赤 |
| 100% | 暗い赤 | 暗い赤 | 暗い赤 |

Claudeは､5時間枠か週間枠のどちらかが90%を超えるとアイコン全体(地と外枠)も赤くなります｡16ピクセルでは小さな中央の円グラフだけが赤くなっても見落としやすいためです｡

AntigravityのアイコンはGemini枠を表示します｡Claude/GPT枠は詳細ウィンドウで確認できます｡

> **用語について**  このREADMEでは､データを読み直すことを｢取得更新｣､利用制限が再設定されることを｢リセット｣と表記します｡トレイアイコンの最外周が示すのはリセットまでの時間です｡

## 主な機能

- Codex･Claude･Antigravityを別々のトレイアイコンで表示
- 5時間枠･週間枠の使用率と､5時間枠のリセットまでの時間をアイコン内に表示
- ClaudeのFable週次上限(週間枠とは別に効く上限)の表示
- Codexのリセットクレジット(枚数と各期限)の表示と､一覧･消費用のコマンドラインツール
- Antigravityの2系統(Gemini枠とClaude/GPT枠)の表示
- 80%･95%を跨いだときだけ通知(起動直後は通知しません｡ClaudeはFable上限､AntigravityはGemini枠が対象)
- サービスごとの取得のオン･オフと取得間隔(既定はCodex 60秒､Claude 5分､Antigravity 5分)
- Windowsログイン時の自動起動
- ローカルの読み取り専用JSON API
- GUIからの動作設定とAPI専用モード

## 動作要件

- Windows 10またはWindows 11
- Windows PowerShell 5.1以降
- Python 3.9以降(Claude･Antigravityの取得と､Codexの主取得経路に使います)
- Codex CLI(`codex app-server` が使えるもの)
- Antigravityを監視する場合はAntigravity CLI(`agy`)

どれかのサービスを使っていない場合､そのアイコンは｢データなし｣のまま動作します｡

## データの取得方法

### Codex

Codex CLIの `codex app-server` をJSON-RPCで起動し､`account/rateLimits/read` で5時間枠･週間枠とリセットクレジットを読みます(`codex-usage.py`)｡メタデータの読み取りだけでトークンは消費しません｡起動の負荷を抑えるため､取得更新は60秒以上の間隔を空けます｡

この取得に失敗したときや結果が15分より古いときは､`~/.codex/sessions` にCodex自身が保存する最新の `rate_limits` イベントを読むフォールバックに切り替わります｡この経路ではリセットクレジットは表示されません｡

#### リセットクレジットの一覧と消費

`codex` のサブコマンドにはリセットクレジットを扱うものが無いため､app-serverを直接呼ぶツールを同梱しています｡

```powershell
python "$env:LOCALAPPDATA\LLMUsageMonitor\codex-reset-credit.py" --list
python "$env:LOCALAPPDATA\LLMUsageMonitor\codex-reset-credit.py" --consume <CREDIT_ID> --yes
```

`--list` は読み取りだけです｡`--consume` はクレジットを1枚使い､取り消せません｡誤操作を防ぐため `--yes` を付けない限り実行しません｡モニター本体が自動で消費することはありません｡

### Claude Desktop Code

Claude CodeのOAuth認証を使い､Anthropicの `/api/oauth/usage` を読みます(`claude-desktop-usage.py`)｡CLIや推論セッションは起動せず､モデル利用も発生しません｡

Fableの週次上限は､同じレスポンスの `limits` 配列にある `kind: "weekly_scoped"` かつ `scope.model.display_name: "Fable"` の項目から読みます｡その週にFableを使っていない場合は項目自体が無いことがあり､そのときは｢データなし｣と表示します｡

このエンドポイントは同じトークンで短い間隔に呼ぶと `HTTP 429` を返すことがあります｡失敗した回は前回の値を残すので表示は崩れません｡取得の成否は `~/.ai-usage/claude-desktop-usage.log` に記録します(トークンは伏せ字にします)｡

認証トークンはメモリ内だけで扱い､Anthropic以外には送信しません｡ディスクへ保存するのは使用率とリセット時刻だけです｡このエンドポイントは公開APIとして保証されていないため､Claude側の変更により追従が必要になる場合があります｡

CLI版Claude Codeを使用する場合は､公式status lineからの取得もフォールバックとして利用できます｡

### Antigravity

Antigravity CLIを `agy -p /usage --output-format json` で5分ごとに呼び､表示されるGemini枠とClaude/GPT枠の残量を読みます(`agy-usage.py`)｡スラッシュコマンドの表示だけで推論は走りません｡

agyは定期的に自動更新チェッカーを別プロセスで起動し､そのたびに新しいコンソールが一瞬開きます｡これを避けるため､モニターからの呼び出しに限り `AGY_CLI_DISABLE_AUTO_UPDATE=true` を渡します｡普段の対話的なagyの自動更新には影響しません｡

## インストール

リポジトリをダウンロードまたはクローンし､PowerShellでそのフォルダーを開いて次を実行します｡

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
```

インストーラーは次を行います｡

1. `%LOCALAPPDATA%\LLMUsageMonitor` に本体をコピー
2. Claude Desktop Codeの利用状況連携を有効化
3. CLI版Claude Code用のstatus lineフォールバックを設定
4. スタートアップへショートカットを登録
5. モニターを起動

Claude設定を変更しない場合は `-SkipClaudeConfiguration`､自動起動が不要なら `-NoStartup` を指定できます｡

完了すると通知領域にCodex･Claude･Antigravityのアイコンが表示されます｡まずはどれかを左クリックし､詳細画面に使用率とリセット時刻が出ていることを確認してください｡

インストール後は､Windowsのスタートメニューから｢LLM Usage Monitor｣を選ぶだけで起動できます｡コンソールを持たないWindows Script Host経由で起動するため､PowerShell画面は表示されません｡｢LLM Usage Monitor Settings｣は設定画面だけを開きます｡

## 使い方

- トレイアイコンを左クリック: 詳細ウィンドウを表示
- トレイアイコンを右クリック: 概要表示､即時更新､自動起動設定､終了
- トレイアイコンにマウスを乗せる: 使用率とリセットまでの時間を表示(CodexはリセットクレジットのRC枚数､ClaudeはFable使用率も表示)
- アイコンのホバー､右クリック､詳細画面上部: 次回取得までの秒数を表示
- 詳細ウィンドウの｢x｣: ウィンドウを隠してトレイで動作を継続

詳細ウィンドウには次を表示します｡

- Codex: 5時間枠､週間枠､リセットクレジットの枚数と各期限
- Claude Code: 5時間枠､週間枠､Fable週間
- Antigravity: Gemini枠とClaude/GPT枠の､それぞれ5時間枠と週間枠

5時間枠のリセット時刻を過ぎたあと､新しい利用がまだ始まっていない場合は｢期限経過(次回利用時に更新)｣と表示します｡

## 設定

トレイメニューまたは詳細ウィンドウの｢設定...｣から､次を変更できます｡

サービスごと(Codex･Claude･Antigravity)に次の3つを設定します｡

| 項目 | 内容 |
| --- | --- |
| 取得する | オフにすると､そのサービスの取得をやめます｡ファイルも読まず､トレイアイコンも出ません｡APIでは `available: false, disabled: true` になります |
| トレイに表示 | トレイアイコンを出すかどうか｡取得をオフにすると選べなくなります |
| 取得間隔 | 使用量を取りに行く間隔(5-3600秒)｡既定はCodex 60秒､Claude 300秒､Antigravity 300秒 |

ほかに次を変更できます｡

- 80%･95%到達通知の有効･無効
- Windowsログイン時の自動起動
- ローカルAPIの有効化とポート番号

取得が終わるとすぐに詳細ウィンドウとアイコンへ反映します｡すべてのトレイアイコンを非表示にすると､API専用モードとしてバックグラウンド動作します｡設定画面はWindowsのスタートメニューにある｢LLM Usage Monitor Settings｣からいつでも開けます｡

以前の設定ファイルにあった `local_refresh_seconds`(旧｢ローカル表示･Codex｣)は､取得済みファイルの定期的な読み直し間隔として残っていますが､設定画面には出しません｡

## アイコンのカスタマイズ

インストール先の `%LOCALAPPDATA%\LLMUsageMonitor` に `CustomTrayIcon.ps1` を置くと､アイコン描画だけを差し替えられます｡本体は次の関数を検出して呼び出します｡`$Provider` には `Codex`･`Claude`･`Antigravity` のいずれかが入ります｡

```powershell
function New-CustomProviderUsageIcon {
    param($Provider, $FiveHourUsed, $WeeklyUsed, $FiveHourResetRemainingPercent)
    # System.Drawing.Iconを返す｡$nullなら標準アイコンを使用｡
}
```

インストール先の `CustomTrayIcon.example.ps1` は､`icons\codex.ico`･`icons\claude.ico`･`icons\antigravity.ico` を読み込む最小サンプルです｡ファイル名を `CustomTrayIcon.ps1` に変更して利用できます｡

このサンプルで読み込める形式はWindowsアイコン(`.ico`)だけです｡PNGやSVGはそのままでは使用できません｡16x16ピクセルを含む32bit透過のマルチサイズICO(16､20､24､32､48､256ピクセル推奨)を用意してください｡

静的ICOを使うと使用率グラフは表示されなくなるため､動的表示を維持したい場合は渡された使用率を使ってアイコンを生成してください｡独自の変換処理を `CustomTrayIcon.ps1` に実装し､最終的に `System.Drawing.Icon` を返す場合は､ICO以外の素材も利用できます｡

カスタム描画が `$null` を返すかエラーになった場合は､標準アイコンへフォールバックします｡`CustomTrayIcon.ps1` と `icons` フォルダーは再インストール時にも削除されません｡PowerShellスクリプトとして実行されるため､信頼できるコードだけを配置してください｡

## ローカルAPI

ローカルAPIが有効な状態でモニターを起動すると､`127.0.0.1:47831` で読み取り専用APIを利用できます｡既定では有効で､外部ネットワークには公開されません｡

```text
GET http://127.0.0.1:47831/health
GET http://127.0.0.1:47831/api/v1/usage
```

PowerShellでの取得例:

```powershell
Invoke-RestMethod http://127.0.0.1:47831/api/v1/usage
```

`providers` の下に `codex`･`claude`･`antigravity` が入ります｡各プロバイダーには5時間枠(`five_hour`)､週間枠(`weekly`)､取得元(`source`)､取得時刻(`captured_at`)が含まれ､さらに次の追加項目があります｡

| 項目 | 内容 |
| --- | --- |
| `claude.fable` | Fableの週次上限｡`five_hour` などと同じ形(`used_percent`･`left_percent`･`resets_at`･`expired`) |
| `codex.reset_credits` | `available_count` と､各クレジットの `id`･`status`･`title`･`expires_at_epoch` など |
| `antigravity.families` | `gemini` と `claude_gpt` の2系統｡それぞれに `five_hour` と `weekly`｡`antigravity` 直下の2枠はGemini枠と同じ値 |

レスポンスの抜粋:

```json
{
  "schema_version": 1,
  "providers": {
    "claude": {
      "available": true,
      "five_hour": { "used_percent": 2, "left_percent": 98, "resets_at": "2026-09-11T07:19:59.0000000+09:00", "expired": false },
      "weekly": { "used_percent": 68, "left_percent": 32, "resets_at": "2026-09-11T17:59:59.0000000+09:00", "expired": false },
      "fable": { "used_percent": 91, "left_percent": 9, "resets_at": "2026-09-11T17:59:59.0000000+09:00", "expired": false }
    },
    "codex": {
      "available": true,
      "reset_credits": { "available_count": 3, "credits": [ { "id": "RateLimitResetCredit_...", "status": "available", "expires_at_epoch": 1789946079 } ] }
    },
    "antigravity": {
      "available": true,
      "families": { "gemini": { "label": "Gemini Models" }, "claude_gpt": { "label": "Claude and GPT models" } }
    }
  }
}
```

`expired: true` は､リセット時刻を過ぎていて新しい利用がまだ始まっていない(実質的に残量100%)という意味です｡設定で取得をオフにしたサービスは `{ "available": false, "disabled": true }` になります｡追加項目は既存のクライアントを壊さないよう後から足したもので､`schema_version` は1のままです｡認証情報や会話内容は含まれません｡

APIの有効･無効とポート番号は設定画面から変更できます｡スクリプトを直接起動する場合は､`-DisableApi` と `-ApiPort` も利用できます｡

## テスト

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Settings.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CustomTrayIcon.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TrayIcon.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UsageData.ps1
python -m unittest .\tests\test_usage_api.py .\tests\test_usage_helpers.py
```

## アンインストール

先にトレイメニューから終了し､次を実行します｡

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Claude Codeの以前のstatus line設定は､モニターの設定がそのまま残っている場合に限り復元します｡

## License

[MIT License](LICENSE)
