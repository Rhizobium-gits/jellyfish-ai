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

- **権限（Auto Mode）**：Claude Code 公式の `--permission-mode auto`。`settings.json` の `permissionMode` は `--help` の choices にあるものだけ使い、`bypassPermissions` は使わない（`ClaudeCodeBackend.effectiveMode`）。確認なしでファイル操作・コマンド実行を進め、認証情報の持ち出し・意図しない外部送信・取り返しのつかない操作などは Claude Code 側の安全判定が止める。`--permission-prompts none` で確認待ちのまま固まらない。オプションは起動時に `claude --help` で存在を確かめてから付ける（古い版で auto が無ければ acceptEdits に落とす）。OS の権限設定（画面収録・アクセシビリティ）は変更しない。
- **claude の検出**：PATH・`~/.local/bin`・Homebrew・VS Code/Cursor 拡張同梱版の `--version` を比べて最新を使う。
- **環境変数**：GUI アプリは PATH が最小限なので、ログインシェルの環境を一度取り込んでエージェントに渡す。

## 2.4 外部 MCP は呼んだときだけ

`AgentRuntime.submit` が毎ターン `mcpPolicy`（JellyManager）に指示文・作業フォルダ・「この会話ですでに読み込んだか」を渡して決める。読み込まないときは `--strict-mcp-config`（`--help` に有ることを確かめてから付ける）で Jellyfish の `--mcp-config` だけにし、`--append-system-prompt` に「読み込んでいない。必要なら名前を入れて頼み直してもらう」を足す。サーバー名は `~/.claude.json`（ユーザー設定・プロジェクト設定）と作業フォルダから上の `.mcp.json` のキーだけを読む（中身は読まない）。名前やカタカナ表記（ブレンダー・フィグマ等）が指示に出たら読み込み、その会話 ID を meta.json に覚えて続きのターンも読み込む。

画面の添付は長辺 1568px まで（実画素より拡大しない）。PC 操作の `screen_capture` は 1 ポイント = 1 ピクセルのまま（現行モデルは長辺 2576px まで座標が画素と 1:1 なので、クリック位置の換算をしない）。

## 2.5 チーム（エージェント同士の分業）

```
claude -p ... --mcp-config agents/<id>/mcp.json --allowedTools mcp__jellyfish --append-system-prompt <チームの説明>
   └─ stdio ─▶ JellyfishAI --mcp-bridge <bus.sock> <agentID>   （同じ実行ファイルの中継モード）
                   └─ unix socket（データフォルダ、0600）─▶ TeamBus ─▶ TeamCoordinator（アプリ内）
```

- **MCP サーバーはアプリ側**：ブリッジは標準入出力とソケットを中継するだけで、JSON-RPC（initialize / tools/list / tools/call）は TeamCoordinator が処理する。どのエージェントからの呼び出しかはブリッジの hello で分かる
- **ツール**：`list_team`、`assign_task`（すぐ task_id を返す。相手が作業中なら順番待ち）、`create_teammate`（呼んだクラゲの隣に出し、線でつなぎ、作業フォルダ・モデル・強さを引き継ぐ）、`wait_for_tasks`（最大 1800 秒待つ。過ぎたらその時点の状況を返し、もう一度呼べば続きを待てる）。待ちが長いので子プロセスに `MCP_TOOL_TIMEOUT` を渡す
- **依頼の実行**：依頼先の次のターンとして `--resume` で送る（目印 `[Jellyfish チーム依頼 from: 名前]` を先頭に付け、チャットでは「📨 名前 からの依頼」と表示）。ターンが終わったら結果（stream-json の result）を依頼元へ返す
- **つながり**：無向の辺（links.json）。つながりの塊が 1 チームで、チーム内なら隣でなくても頼める（光は線をたどる最短経路を流れる）。ドラッグ中、中心どうしが体 1.5 個ぶん以内の最も近いクラゲを「つながる先」として、ドラッグ元の色の流れる点線・相手を囲む脈打つ輪・「離すと 〇〇 とつながる」の吹き出しで見せる（チームが 8 体を超えるなら赤）。離すと、線が体に隠れず ✂︎ も出せるよう、相手から体 1.6 個ぶんの空いた位置へ 0.22 秒で滑らせてからつなぐ。⇧ ドラッグはチーム全体を平行移動、⌥ を押したまま離すとそのクラゲのつながりを全部切る（修飾キーはドラッグ中もポインタ追跡で拾うので、マウスを止めたまま押しても表示が切り替わる）。右クリック › つなぐ で離れたクラゲともつなげる
- **描画**：LinkOverlay（ディスプレイごとの透明な重ね窓、クラゲより 1 段下のレベル、クリックは素通し）。線は CAShapeLayer の点線、依頼が流れている間だけ lineDashPhase を流す。光は CAKeyframeAnimation。静止中はアニメーションが無いので CPU を使わない。✂︎ は線の近くにポインタがあるときだけ出る小さなクリック可能パネル
- **上限**：1 チーム 8 体、全体 20 体、作成の深さ 2（ユーザーのクラゲ = 0）。毎ターンの system prompt に今のチームと残り枠を書く

## 2.6 自律組織モード（Org/）

```
ユーザーの依頼 ─▶ TeamCoordinator.runConfig（ユーザーのターンだけ）
                   └─ OrgLearner.begin：前の依頼への反応を読む → TaskFeatures → OrgPolicy.recommend → エピソードを始める
                   └─ system prompt に「おすすめの形・組み方・ほかの候補・残り枠」
リーダー ─▶ form_team(members[name, role, task, after], formation) ─▶ 仲間を作る / 同じ名前は使い続ける / 要らない仲間を片付ける
                   └─ after のある依頼は blocked に置き、前の担当が全部終わったら結果を依頼文に付けて dispatch
リーダーのターンの終わり ─▶ endEpisode：成果（状態・時間・費用・仲間の成否）→ OrgLearner.finish → 裏で進化・保存・レポート
👍👎・再実行・キャンセル・次の指示の文 ─▶ OrgReaction ─▶ 点数（OrgReward）
```

- **考える部分は純粋な値の計算**（`Org/OrgModel.swift`。画面・ファイル・claude を使わないのでテストで確かめる）
  - `OrgGenome`：形（solo / parallel / pipeline / ensemble / hierarchy）・人数・レビュー係の有無。`parallel3+r` のような key で記録する
  - `TaskFeatures`：漢字・カタカナは 2 文字ずつ、英数字は単語にして重み（長さ 1 に正規化）、依頼の種類のタグ（日本語・英語・中国語のキーワード）と長さ（漢字かなは 2.5 文字ぶん）。似ている度合い = 語のコサイン 0.7 ＋ タグの Jaccard 0.3
  - `OrgPolicy`：型ごとに Beta(α, β)。出発点は依頼の種類からの見込み p（α = 1+2p, β = 1+2(1-p)）。過去のエピソードは似ている度合い s で w = 4s² + 0.12（同じ形で人数違いは 0.3 倍）を足す。Thompson サンプリングで選び、人数 × 0.015 を割り引く。似た依頼（s ≥ 0.35）が無ければ novel
  - `OrgReward`：完了 0.65・失敗 0.15・キャンセル 0.1、仲間の失敗・長時間で減点、👍 は 0.85 以上に、👎 は 0.25 以下に、再実行・キャンセル・「違う」で減点、「ありがとう」で加点
  - `OrgEvolution`：2 件以上の型の上位 2 つから、人数 ±1・レビュー係の付け外し・形の変更の子を 1 つずつ。4 件以上でいちばんの型より 0.3 低い型は引退（solo は残す）。リーダーが自分で選んだ一覧にない形は取り込む
- **OrgLearner**：状態はメインスレッド。保存（`org/episodes.json` 0600・`population.json`・`report.md`）と進化は 3 秒待ってまとめて `jellyfish.org`（utility）キューで。終了時は `flush` で書き切る。エピソードは 600 件まで
- **片付け**：form_team が作った仲間は `JellyRecord.orgSpawned`。次の form_team で使わない、空いている仲間（とその下の仲間）を消す。リーダーが仲間を使わずにターンを終えたら、前の依頼の仲間を消す
- **安全**：PC 操作のツールは仲間からの依頼のターンでは渡さない（`usesPCTools`）。仲間からの依頼の文では外部 MCP を読み込まない。学習は端末内だけで、どこにも送らない

## 2.7 表示の言語（Localization/）

- ソースには日本語をそのまま書き、`L("…")` / `L("…%@…", x)` で包む。`L10n.translate` が今の言語の表（`Strings+en.swift`・`Strings+zh.swift`、日本語 → 訳）を引き、無ければ日本語のまま
- 訳の元は `l10n/en.json`・`l10n/zh.json`。`scripts/l10n.py` がソースから L() のキーを実行時の文字列そのもので取り出し（複数行の字下げ・エスケープ・コメントの中は除く）、抜け・%@ の数の違い・L() の中の `\( )` を調べ（CI）、Swift の表を作る
- 言語を変えたら、メニュー（開くたびに作る）・メインメニュー（通知で作り直す）・開いているチャット（作り直す）に反映。エージェントへの案内（チーム・PC 操作・自律組織・ツールの説明）も L() を通すので、その言語で渡る
- 履歴の読み取りに使う目印（`requestMarker`・`ScreenContext.marker`・`attachMarker`）と、判定に使う語の一覧（画面を指す言葉・依頼の種類・反応・色の別名）は訳さない。判定の語は 3 言語を並べる
- `JELLYFISH_LANGUAGE=ja|en|zh` で設定より優先して決める（`scripts/test.sh` は ja に固定。CI の macOS は英語のため）

## 3. 保存場所

`~/Library/Application Support/JellyfishAI/`

| ファイル | 内容 |
|---|---|
| `settings.json` | ショートカット、見た目、大きさ、自動起動、権限モード、claude のパス等 |
| `jellies.json` | クラゲ（番号・色・位置・状態・表示） |
| `agents/<id>/meta.json` | セッション ID・作業フォルダ |
| `links.json` | クラゲ同士のつながり |
| `bus.sock` | チーム機能のソケット（0600） |
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
| 5 チーム | 名前、隣に置くとつながる線、依頼と結果の受け渡しを線上で可視化、✂︎ で切る、エージェントが仲間を作って分担（MCP） | ✅ 実機で 4 体の分業（作成 → 並列 → レビュー → 統合）を確認 |
| 6 拡張 | セッションのアーカイブ、メニューバーのアニメーション、ファイルのドロップ、PC 操作（アクセシビリティ）、システム音声の文字起こし・議事録、3D ドット絵、リアルなクラゲの動き、デスクトップごとの配置、管理画面（CPU/GPU）、ChatGPT 連携（API キー）、固定の署名 | 未着手 |

## 画面認識の流れ

1. 送信時に `ScreenIntent.refersToScreen`（「この画面」「表示されて」「今開いて」「このページ」「スクショ」、"this screen" など、画面をはっきり指す言い回しだけ）で判定。「一覧を表示して」「このコードを直して」のような普通の指示では撮らない
2. `SCShareableContent` → 自分のアプリを除外した `SCContentFilter` → `SCScreenshotManager.captureImage`（長辺 1568px まで、実ピクセルより大きくしない）
3. `agents/<id>/attachments/screen-*.png` に保存し、指示の末尾に「画面コンテキスト」としてパス・前面アプリ・ウィンドウ名を添える
4. Claude Code が Read ツールで画像を読んで作業する（チャット表示ではこの部分を「📷 画面を添付しました」に置き換える）

## 5. 既知の注意点

- ⌘L はグローバルに奪うため、ブラウザのアドレスバー移動などと競合する。`settings.json` の `hotKeyPassthroughApps` に bundle ID を入れたアプリが前面の間だけ ⌘L を解放する。他アプリが先に ⌘L を登録していた場合は ⌃⌥L に切り替えてメニューに表示する。
- アドホック署名なので、再ビルド・新しい版への入れ替えのたびに画面収録・アクセシビリティの許可が外れる（TCC が署名の cdhash で識別するため）。Apple Developer ID で署名・公証すれば解消する。
- アプリを終了すると実行中のエージェントは中断される（次回起動時に「中断」として記録）。終了後も続けるには Phase 5 のデーモン化が必要。

## 6. 配布と外部からの入口

- **ビルド**：`scripts/build.sh`（この Mac の CPU）/ `--universal`（arm64 と x86_64 を別々に `swift build --arch` して `lipo`）。`VERSION` を CFBundleShortVersionString、コミット数を CFBundleVersion に入れ、アドホック署名する
- **配布物**：`scripts/release.sh` が テスト → universal ビルド → 署名と CPU の確認 → .dmg（Applications へのリンクと「はじめにお読みください」）・.zip・SHA256SUMS.txt を作る。`--publish` で CHANGELOG の該当節をノートにして `gh release create`
- **CI**：`.github/workflows/ci.yml`（macos-26。SpeechAnalyzer など macOS 26 の SDK が要る）でテストと universal ビルド
- **テスト**：`Tests/JellyfishAITests`（Swift Testing）。画面や claude を使わない判定ロジック（URL の受け付け、バージョン比較、外部 MCP の判定、設定の読み込み、画面添付の判定、プロセスの親子判定、セッションの増分読み込み）。Command Line Tools だけの環境では `scripts/test.sh` が Testing.framework の場所を渡す
- **`jellyfish://`**：`URLRoutes.allowed` が受け付ける操作を決める。普段は表示系（`new`・`open`・`toggle`・`show`・`hide`・`arrange`・`style`・`scale`）だけ。指示の送信・PC 操作の許可・作業フォルダ・削除などは `JELLYFISH_AUTOMATION=1` で起動したときだけ（デモ録画は `scripts/demo/record.sh` が付ける）
- **チームのソケット**：`bus.sock`（0600）。接続ごとに `LOCAL_PEERPID` で相手のプロセスを取り、hello で名乗ったエージェントの claude（`AgentRuntime.processID`）の子孫であることを `ProcessTree.isDescendant` で確かめてから受け付ける
- **通信**：アプリ自身はメニューの「アップデートを確認…」のときだけ `api.github.com/repos/…/releases/latest` を読む。自動の確認・利用状況の送信はしない
- **片付け**：起動時に 7 日より古い画面の画像を消す（`DataJanitor`）。`app.log` は 2MB、`events.jsonl` は 4MB で 1 世代に入れ替える（`LogRotation`）。クラゲを消すとそのクラゲの生イベントと画像を消す

