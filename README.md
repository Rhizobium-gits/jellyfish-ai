# Jellyfish AI

デスクトップの右端に Claude のドット絵キャラクターが常駐し、1 体ずつが独立した AI エージェント（Claude Code）として動く macOS アプリです。

*A macOS desktop companion: each little pixel character on the edge of your screen is an independent Claude Code agent. Press ⌘L, type, and watch it think, work and finish.*

<p align="center">
  <img src="docs/media/demo-basic.gif" width="820" alt="⌘L で新しいクラゲを出して指示し、完了したらタップして結果を開き、続けて指示する様子">
</p>

> [!NOTE]
> 個人が作った非公式のアプリです。Anthropic とは関係ありません。Claude・Claude Code および Claude Code のキャラクターは Anthropic のものです。

## できること

- **⌘L で即エージェント**：どのアプリを使っていても ⌘L で新しいクラゲが現れ、そのまま指示を打てる。Enter で送信すると入力欄は閉じ、クラゲが作業を始める
- **動きで状態がわかる**：考え中・作業中（ツール実行中）・完了・エラー・キャンセルを、Claude Code の実際のイベントに合わせて表示。完了したら動きが止まり、CPU をほぼ使わない
- **並列・独立**：クラゲごとに別のセッション・作業フォルダ・履歴・プロセス。1 体が失敗しても他は影響を受けない
- **タップで結果と続き**：チャットウィンドウで結果を読み、同じセッションのまま続けて指示できる。ウィンドウは普通の Mac のウィンドウ（しまう・フルスクリーン・自由にリサイズ）
- **モデルと考える強さ**をクラゲごとにチャットから切り替え（`--model` / `--effort`）
- **画面を見て作業**：「この画面」「表示されているエラー」などと書くと、送信時の画面を撮って渡す（Jellyfish 自身のウィンドウは写さない）
- **エージェント同士で分業**：クラゲを別のクラゲの隣に置くと線でつながり、同じチームになる。エージェントは仲間に作業を頼んだり、新しい仲間を作って分担させたりでき、依頼（依頼元の色）と結果（依頼先の色）が線の上を光って行き来する。線にポインタを置くと出る ✂︎ で切れる
- **名前を付けられる**：右クリック「名前を変える…」かチャットの「名前」。エージェント同士はこの名前で呼び合う
- **Claude Code の記録に残る**：会話は Claude Code 自身のセッション（`~/.claude/projects`）に保存されるので、VS Code やターミナルからも続きを開ける。メニューバーの「過去のセッションを開く」で、VS Code・ターミナルで作ったセッションもクラゲとして呼び出せる

<p align="center">
  <img src="docs/media/demo-parallel.gif" width="820" alt="複数のクラゲが並列に作業し、終わったものから止まり、長押しで消える様子">
</p>

<p align="center">
  <img src="docs/media/demo-team.gif" width="820" alt="リーダーが仲間を 2 体作って詩を書かせ、レビュー係に選ばせて結果をまとめ、最後に線を切る様子">
</p>

<p align="center">
  <img src="docs/media/states.gif" width="720" alt="待機・考え中・作業中・完了・エラー・キャンセルの 6 つの状態">
</p>

## 操作

| 操作 | 動作 |
|---|---|
| **⌘L**（どのアプリからでも） | 新しいクラゲを出して、すぐ入力欄を開く |
| **タップ** | チャットウィンドウを開く（Enter 送信 / ⇧Enter 改行 / Esc 閉じる） |
| **長押し** | そのクラゲを消す（作業中なら「作業は続ける / キャンセルして消す」を確認） |
| **ドラッグ** | 好きな場所へ移動（位置は保存） |
| **右クリック** | チャット・キャンセル・隠す・定位置に戻す・削除 |
| **⌥⌘L** / メニューバー | 全員を隠す・表示（隠しても作業は続く） |

### チーム（分業）

1. クラゲを別のクラゲの**隣にドラッグして置く**と線でつながる（ドラッグ中は点線でつながる相手が見える）。つながった塊が 1 つのチーム
2. どれかに「仲間を作って分担して」「レビュー係に添削してもらって」のように頼む。エージェントは Jellyfish の MCP ツールで
   - `create_teammate`：新しい仲間を自分の隣に出して作業を任せる（作業フォルダ・モデルは引き継ぐ）
   - `assign_task`：チームの仲間に作業を頼む（相手が作業中なら順番待ち）
   - `wait_for_tasks`：頼んだ作業の結果を受け取る
   - `list_team`：仲間と状態を見る
3. 頼まれた側のチャットには「📨 〇〇 からの依頼」として残る。結果は依頼元に戻り、依頼元がまとめる
4. つながりは、線にポインタを置くと出る ✂︎、または右クリック › つながり で切れる

1 チーム最大 8 体。エージェントが作った仲間がさらに作れるのは 1 段まで（ユーザーのクラゲから数えて 2 段）。メニューバーの「チーム（分業）」で機能ごと止められます。

チャットウィンドウの下段では、モデル・強さ・画面の添付（自動判定 / 毎回 / しない）・ファイル添付・作業フォルダを変えられます。「Claude Code で開く」で同じセッションをターミナルの `claude --resume` で開けます。

## 必要なもの

- macOS 14 以降（Apple Silicon で動作確認）
- [Claude Code](https://docs.claude.com/en/docs/claude-code) がインストール済みでログインしていること（PATH・`~/.local/bin`・Homebrew・VS Code 拡張に同梱の `claude` から最新版を自動で選びます）
- ビルドに Swift 5.10 以降（Swift 6.3 で確認。Xcode は不要で、Command Line Tools だけでビルドできます）

## ビルドと起動

```bash
git clone https://github.com/Rhizobium-gits/jellyfish-ai.git
cd jellyfish-ai
scripts/build.sh            # → dist/JellyfishAI.app
open dist/JellyfishAI.app
```

メニューバーのアイコンから、見た目・大きさ・画面認識・ログイン時の自動起動などを設定できます。

## 権限と安全

- エージェントは Claude Code 公式の **Auto Mode**（`--permission-mode auto`）で動きます。確認なしでファイル操作・コマンド実行を進め、認証情報の持ち出し・意図しない外部送信・取り返しのつかない操作などは Claude Code 側の安全判定が止めます。付けるオプションは起動時に `claude --help` で存在を確かめてから使います
- 今の権限の範囲と使っている `claude` の場所・版はメニューバーの「実行ポリシー」で確認できます
- macOS の権限設定は変更しません。画面認識を使うときだけ「システム設定 › プライバシーとセキュリティ › 画面収録」で Jellyfish AI を許可してください

## 知っておくこと

- ⌘L はグローバルに使うため、ブラウザのアドレスバー移動と競合します。`settings.json` の `hotKeyPassthroughApps` に bundle ID を入れたアプリが前面の間は ⌘L をそのアプリに返します。他のアプリが先に ⌘L を使っていれば ⌃⌥L に切り替えます
- アプリを終了すると、実行中のエージェントは中断されます（次回起動時に「中断」として残ります）
- アドホック署名なので、ビルドし直すと画面収録の許可が外れることがあります

## データの保存場所

`~/Library/Application Support/JellyfishAI/`（設定・クラゲ・エージェントごとの履歴と生イベント・ログ）。会話そのものは Claude Code のセッションとして `~/.claude/projects/` に残ります。環境変数 `JELLYFISH_DATA_DIR` を付けて起動すると別の場所を使います（デモ録画・テスト用）。

## 開発

- 設計メモ：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- `jellyfish://` URL スキームで外部から操作できます（ショートカット.app・Raycast・自動テスト用）：`new`, `open?agent=2`, `prompt?agent=2&text=…`, `rename?agent=2&name=…`, `link?a=2&b=3`, `unlink?a=2&b=3`, `type?agent=2&text=…`, `press?agent=2`, `state?agent=2&s=working`, `remove?agent=2`, `toggle`, `arrange`, `style?v=pixel|realistic`, `debug`
- `.build/debug/JellyfishAI --pixel-sheet out.png` でドット絵のコマ一覧、`--settle-test` で完了時の静止を検証
- README の GIF は `scripts/demo/record.sh` で撮り直せます（普段のデータには触れず、空のデモ用データで実際に Claude Code を動かして録画。Pillow と ffmpeg が必要）
