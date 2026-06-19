# LLM Usage Monitor

CodexとClaude Desktop Codeの利用制限を、Windowsのタスクトレイから確認する軽量モニターです。

## 機能

- CodexとClaudeを別々のトレイアイコンで表示
- 外周リングに5時間枠、中央の円グラフに週間枠の使用率を表示
- 70%・90%を境にグラフ色を変更
- 80%・95%を跨いだときだけ通知（起動直後は通知しません）
- ローカル表示は既定30秒、Claude APIは既定5分ごとに更新
- Windowsログイン時の自動起動
- ローカルの読み取り専用JSON API
- GUIからの動作設定とAPI専用モード

Codexは青系、Claudeは橙・紫系の配色なので、アイコンを見分けられます。

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

PowerShellでこのフォルダーを開き、次を実行します。

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

## 使い方

- トレイアイコンを左クリック：詳細ウィンドウを表示
- トレイアイコンを右クリック：概要表示、即時更新、自動起動設定、終了
- トレイアイコンにマウスを乗せる：使用率とリセットまでの時間を表示
- 詳細ウィンドウの「×」：ウィンドウを隠してトレイで動作を継続

外周が5時間枠、中央が週間枠です。制限値がリセット時刻を過ぎている場合は、次回利用時の更新待ちとして表示します。

## 設定

トレイメニューまたは詳細ウィンドウの「設定...」から、次を変更できます。

- Codex・Claude各トレイアイコンの表示
- ローカル表示・Codexの更新間隔（5～3600秒）
- Claude APIの更新間隔（5～3600秒）
- ローカルAPIの有効化とポート番号
- Windowsログイン時の自動起動

両方のトレイアイコンを非表示にすると、API専用モードとしてバックグラウンド動作します。設定画面はWindowsのスタートメニューにある「LLM Usage Monitor Settings」からいつでも開けます。

## ローカルAPI

モニター起動中は、`127.0.0.1:47831` で読み取り専用APIを利用できます。外部ネットワークには公開されません。

```text
GET http://127.0.0.1:47831/health
GET http://127.0.0.1:47831/api/v1/usage
```

PowerShellでの取得例：

```powershell
Invoke-RestMethod http://127.0.0.1:47831/api/v1/usage
```

レスポンスにはCodexとClaudeの5時間枠・週間枠、リセット時刻、データ取得元が含まれます。認証情報や会話内容は含まれません。

APIを無効にする場合は本体を `-DisableApi` 付きで起動します。ポートは `-ApiPort` で変更できます。

## テスト

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UsageData.ps1
```

## アンインストール

先にトレイメニューから終了し、次を実行します。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Claude Codeの以前のstatus line設定は、モニターの設定がそのまま残っている場合に限り復元します。

## License

[MIT License](LICENSE)
