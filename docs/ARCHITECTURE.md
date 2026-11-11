# Jellyfish AI — 設計メモ

デスクトップに常駐するクラゲ（= Claude Code のドット絵キャラクター）が、それぞれ独立した AI エージェントとして動く macOS アプリ。

## 1. 技術選定

| 候補 | 判断 | 理由 |
|---|---|---|
| **Swift + AppKit + Core Animation / Metal**（採用） | ◎ | 常駐アプリとして最軽量（実測 46MB・6体で CPU 0.5%）。非アクティブ化パネル、ScreenCaptureKit、Accessibility (AXUIElement)、Carbon ホットキー、SMAppService、Liquid Glass（NSGlassEffectView）を追加ライブラリなしで直接使える。Command Line Tools だけでビルドでき、環境を変えずに済む |
| Electron + React | △ | 実装は速いが常駐で 200MB 超。Accessibility/画面認識はネイティブアドオンが必要。フォーカスを奪わないパネルの挙動が弱い |
| Tauri | △ | 軽いが Rust ツールチェーンの導入が必要（環境に重大な変更）。透明ウィンドウは private API 依存 |

Framer Motion / CSS Animation の役割は Core Animation が担う（アニメーションは WindowServer 側で補間されるので、アプリのメインスレッドは毎フレーム起きない）。

## 2. 全体構成

```
┌─────────────── JellyfishAI.app（UI プロセス, LSUIElement）────────────────┐
│ AppDelegate ── Shortcuts(⌘L / ⌥⌘L, Carbon)  StatusBar(メニューバー)        │
│      │                                                                    │
│ JellyManager ── 配置・表示/非表示・永続化・クリック透過のポインタ追跡          │
│      ├── JellyController ×N   透明 NSPanel（nonactivating）+ マウス操作       │
│      │      └── Avatar        PixelAvatar（既定, Core Animation）             │
│      │                        RealisticAvatar（Metal シェーダ）               │
│      ├── AgentRuntime ×N      セッション・履歴・状態遷移・ログ                 │
│      │      └── AgentBackend  ClaudeCodeBackend（他の AI もこの口で差し替え）  │
│      └── AgentChatController ×N チャットウィンドウ（入力・会話・モデル切替）     │
└───────────────────────────────────────────────────────────────────────────┘
          │ 1 ターン = 1 子プロセス（クラゲごとに独立）
          ▼
   claude -p <prompt> --output-format stream-json --verbose
          --permission-mode auto --permission-prompts none
          --session-id <uuid>（初回） / --resume <uuid>（2 回目以降）
```

- **エージェントの独立性**：クラゲごとに別のセッション ID・作業フォルダ・履歴・ログ・OS プロセスを持つ。1 体のプロセスが落ちても他には影響しない。
- **状態は実イベントから**：stream-json のイベントだけで遷移させ、応答文から推測しない。

  | イベント | 状態 |
  |---|---|
  | 起動 / text / thinking | Thinking |
  | `tool_use` 〜 対応する `tool_result` | Working |
  | `result` success | Completed（揺れが減衰して完全停止。タイマー・アニメーションも 0） |
  | `result` error / 結果なしで異常終了 | Error |
  | ユーザーのキャンセル（SIGINT → 3 秒後 SIGTERM） | Cancelled |

- **権限（Auto Mode + Full Access）**：Claude Code 公式の `--permission-mode auto`。確認なしでファイル操作・コマンド実行を進め、認証情報の持ち出し・意図しない外部送信・取り返しのつかない操作などは Claude Code 側の安全判定が止める。`--permission-prompts none` で確認待ちのまま固まらない。オプションは起動時に `claude --help` で存在を確かめてから付ける（古い版で auto が無ければ acceptEdits に落とす）。OS の権限設定（画面収録・アクセシビリティ）は変更しない。
- **claude の検出**：PATH・`~/.local/bin`・Homebrew・VS Code/Cursor 拡張同梱版の `--version` を比べて最新を使う。
- **環境変数**：GUI アプリは PATH が最小限なので、ログインシェルの環境を一度取り込んでエージェントに渡す。

## 3. 保存場所

`~/Library/Application Support/JellyfishAI/`

| ファイル | 内容 |
|---|---|
| `settings.json` | ショートカット、見た目、大きさ、自動起動、権限モード、claude のパス等 |
| `jellies.json` | クラゲ（番号・色・位置・状態・表示） |
| `agents/<id>/meta.json` | セッション ID・作業フォルダ |
| `agents/<id>/history.json` | 指示と結果の履歴 |
| `agents/<id>/events.jsonl` | Claude Code の生イベント |
| `app.log` | アプリのログ |

環境変数 `JELLYFISH_DATA_DIR` を付けて起動すると、この保存先を差し替える（README の GIF を撮る `scripts/demo/record.sh` が、普段のクラゲや会話に触れずに空のデータで録画するために使う）。

## 4. ロードマップと現状

| Phase | 内容 | 状態 |
|---|---|---|
| 1 基本 UI | 常駐、Claude キャラ、浮遊、⌘L 生成、色分け、ドラッグ、非表示/再表示、自動起動、長押しで削除 | ✅ 動作確認済み |
| 2 AI 連携 | ⌘L で即入力、タップでチャットウィンドウ（閉じる/しまう/フルスクリーン/自由リサイズ）、Claude Code 接続（Auto Mode）、独立エージェントの並列実行、`--resume` で前の成果物に続けて指示、モデル・強さ（--model / --effort）をクラゲごとに切替、会話は Claude Code のセッション記録から表示、過去のセッション（VS Code・ターミナル製も含む）をメニューから呼び出し、ターミナルで同じセッションを開く | ✅ 実行→完了・エラー・再実行・続けて指示を確認 |
| 3 状態の可視化 | Idle/Thinking/Working/Completed/Error/Cancelled のアニメーション、完了で静止 | ✅ 実イベントで遷移を確認 |
| 4 画面認識 | 指示が画面を指していれば送信時に ScreenCaptureKit で撮影（Jellyfish のウィンドウは除外）、前面アプリ名・ウィンドウ名を添付、📎 添付を優先、対象ディスプレイ選択（使っていたアプリの画面 / 全ディスプレイ）、自動判定/毎回/しない | 🟡 実装済み・画面収録の権限付与後の実機確認待ち。AX（アクセシビリティ）で選択テキスト等を取るのは未 |
| 5 仕上げ | 全クラゲの管理画面、設定画面、音声入力、アプリ終了後もエージェントを続ける常駐デーモン化、固定の署名 | 未着手 |

## 画面認識の流れ

1. 送信時に `ScreenIntent.refersToScreen`（「この画面」「表示されて」「今開いて」「このエラー」「この図」「スクショ」、"this screen" など）で判定
2. `SCShareableContent` → 自分のアプリを除外した `SCContentFilter` → `SCScreenshotManager.captureImage`（長辺 2560px）
3. `agents/<id>/attachments/screen-*.png` に保存し、指示の末尾に「画面コンテキスト」としてパス・前面アプリ・ウィンドウ名を添える
4. Claude Code が Read ツールで画像を読んで作業する（チャット表示ではこの部分を「📷 画面を添付しました」に置き換える）

## 5. 既知の注意点

- ⌘L はグローバルに奪うため、ブラウザのアドレスバー移動などと競合する。`settings.json` の `hotKeyPassthroughApps` に bundle ID を入れたアプリが前面の間だけ ⌘L を解放する。他アプリが先に ⌘L を登録していた場合は ⌃⌥L に切り替えてメニューに表示する。
- アドホック署名なので、Phase 4 で画面収録権限を与えると再ビルドのたびに許可が外れる。Phase 4 着手時に固定の自己署名証明書を作るかを決める。
- アプリを終了すると実行中のエージェントは中断される（次回起動時に「中断」として記録）。終了後も続けるには Phase 5 のデーモン化が必要。
