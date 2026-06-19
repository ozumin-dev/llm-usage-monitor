# LLM Usage Monitor

CodexとClaude Desktop Codeの利用状況・リセット時刻を、Windowsのタスクトレイからひと目で確認する軽量モニターです。CLIや推論セッションを定期実行せず、既存のセッション情報と使用量APIから取得します。

## アイコンの見方

各プロバイダーに1個ずつ、Codexは青系、Claudeは橙・紫系のアイコンを表示します。

| アイコンの部分 | 表示内容 | 読み方 |
| --- | --- | --- |
| 最外周の白い5区画 | 5時間枠のリセットまでの時間 | 約1時間ごとに1区画減り、リセット時刻を過ぎると0区画になります |
| 太いリング | 5時間枠の使用率 | 上から時計回りに増えます |
| 中央の円グラフ | 週間枠の使用率 | 上から時計回りに増えます |

最外周の5区画は「各1時間の使用量」ではなく、現在の5時間枠がリセットされるまでの残り時間です。リセット時刻を取得できない場合は灰色で表示します。

使用率が70%未満ならプロバイダーの基本色、70%以上なら警告色、90%以上なら危険色に変わります。100%に達すると、利用不可の状態を示す濃いグレーに変わります。

> **用語について**  このREADMEでは、データを読み直すことを「取得更新」、利用制限が再設定されることを「リセット」と表記します。トレイアイコンの最外周が示すのはリセットまでの時間です。

## 主な機能

- CodexとClaudeを別々のトレイアイコンで表示
- 5時間枠・週間枠の使用率と、5時間枠のリセットまでの時間をアイコン内に表示
- 80%・95%を跨いだときだけ通知（起動直後は通知しません）
- Codexは既定30秒、Claudeは既定5分ごとに取得更新
- Windowsログイン時の自動起動
- ローカルの読み取り専用JSON API
- GUIからの動作設定とAPI専用モード

## 動作要件

- Windows 10またはWindows 11
- Windows PowerShell 5.1以降
- Codex DesktopまたはCodex CLI
- Claude Desktop Codeの監視にはPython 3.9以降

## データの取得方法

### Codex

`~/.codex/sessions` にCodex自身が保存する最新の `rate_limits` イベントを読みます。CLIの自動操作や追加のAPIリクエストは行いません。

### Claude Desktop Code

Claude CodeのOAuth認証を使い、Anthropicの `/api/oauth/usage` を既定で5分ごとに読みます。CLIや推論セッションは起動せず、モデル利用も発生しません。

認証トークンはメモリ内だけで扱い、Anthropic以外には送信しません。ディスクへ保存するのは使用率とリセット時刻だけです。このエンドポイントは公開APIとして保証されていないため、Claude側の変更により追従が必要になる場合があります。

CLI版Claude Codeを使用する場合は、公式status lineからの取得もフォールバックとして利用できます。

## インストール

リポジトリをダウンロードまたはクローンし、PowerShellでそのフォルダーを開いて次を実行します。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
```

インストーラーは次を行います。

1. `%LOCALAPPDATA%\LLMUsageMonitor` に本体をコピー
2. Claude Desktop Codeの利用状況連携を有効化
3. CLI版Claude Code用のstatus lineフォールバックを設定
4. スタートアップへショートカットを登録
5. モニターを起動

Claude設定を変更しない場合は `-SkipClaudeConfiguration`、自動起動が不要なら `-NoStartup` を指定できます。

完了すると通知領域にCodexとClaudeのアイコンが表示されます。まずはどちらかを左クリックし、詳細画面に使用率とリセット時刻が出ていることを確認してください。

## 使い方

- トレイアイコンを左クリック：詳細ウィンドウを表示
- トレイアイコンを右クリック：概要表示、即時更新、自動起動設定、終了
- トレイアイコンにマウスを乗せる：使用率とリセットまでの時間を表示
- アイコンのホバー、右クリック、詳細画面上部：次回取得までの秒数を表示
- 詳細ウィンドウの「×」：ウィンドウを隠してトレイで動作を継続

5時間枠のリセット時刻を過ぎたあと、新しい利用がまだ始まっていない場合は「期限経過（次回利用時に更新）」と表示します。

## 設定

トレイメニューまたは詳細ウィンドウの「設定...」から、次を変更できます。

- Codex・Claude各トレイアイコンの表示
- ローカル表示・Codexの更新間隔（5～3600秒）
- Claude APIの更新間隔（5～3600秒）
- ローカルAPIの有効化とポート番号
- Windowsログイン時の自動起動

両方のトレイアイコンを非表示にすると、API専用モードとしてバックグラウンド動作します。設定画面はWindowsのスタートメニューにある「LLM Usage Monitor Settings」からいつでも開けます。

## ローカルAPI

ローカルAPIが有効な状態でモニターを起動すると、`127.0.0.1:47831` で読み取り専用APIを利用できます。既定では有効で、外部ネットワークには公開されません。

```text
GET http://127.0.0.1:47831/health
GET http://127.0.0.1:47831/api/v1/usage
```

PowerShellでの取得例：

```powershell
Invoke-RestMethod http://127.0.0.1:47831/api/v1/usage
```

レスポンスにはCodexとClaudeの5時間枠・週間枠、リセット時刻、データ取得元が含まれます。認証情報や会話内容は含まれません。

APIの有効・無効とポート番号は設定画面から変更できます。スクリプトを直接起動する場合は、`-DisableApi` と `-ApiPort` も利用できます。

## テスト

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Settings.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TrayIcon.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UsageData.ps1
python -m unittest .\tests\test_usage_api.py
```

## アンインストール

先にトレイメニューから終了し、次を実行します。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Claude Codeの以前のstatus line設定は、モニターの設定がそのまま残っている場合に限り復元します。

## License

[MIT License](LICENSE)
