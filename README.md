<p align="center">
  <img src="docs/media/icon.png" width="160" alt="Jellyfish AI のアイコン（透明なクラゲ）">
</p>

<h1 align="center">Jellyfish AI</h1>

<p align="center">
  <a href="https://github.com/Rhizobium-gits/jellyfish-ai/actions/workflows/ci.yml"><img src="https://github.com/Rhizobium-gits/jellyfish-ai/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/Rhizobium-gits/jellyfish-ai/releases/latest"><img src="https://img.shields.io/github/v/release/Rhizobium-gits/jellyfish-ai" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14+">
</p>

<p align="center">
  デスクトップの右端に Claude のドット絵キャラクターが常駐し、1 体ずつが独立した AI エージェント（Claude Code）として動く macOS アプリです。<br>
  <i>A macOS desktop companion: each little pixel character on the edge of your screen is an independent Claude Code agent.<br>Press ⌘L, type, and watch it think, work and finish.</i>
</p>

<p align="center">
  <a href="https://github.com/Rhizobium-gits/jellyfish-ai/releases/latest"><b>⬇︎ ダウンロード（.dmg）</b></a>
  &nbsp;·&nbsp; <a href="#ダウンロードとインストール">インストール</a>
  &nbsp;·&nbsp; <a href="#起動のしかた">起動のしかた</a>
  &nbsp;·&nbsp; <a href="#はじめかた">はじめかた</a>
  &nbsp;·&nbsp; <a href="#できること">できること</a>
</p>

<p align="center">
  <img src="docs/media/demo-basic.gif" width="820" alt="⌘L で新しいクラゲを出して指示し、完了したらタップして結果を開き、続けて指示する様子">
</p>

> [!NOTE]
> 個人が作った非公式のアプリです。Anthropic とは関係ありません。Claude・Claude Code および Claude Code のキャラクターは Anthropic のものです。

## ダウンロードとインストール

**必要なもの**

- macOS 14 以降。Apple シリコン / Intel の両方で動く universal 版です（動作確認は Apple シリコンの macOS 26）。システムの音の文字起こしは macOS 26 以降
- ログイン済みの [Claude Code](https://code.claude.com/docs/en/setup)。PATH・`~/.local/bin`・Homebrew・VS Code / Cursor 拡張に同梱の `claude` から最新版を自動で選びます（使っている版と場所はメニューバーの「実行ポリシー」に出ます）

1. **Claude Code を入れてログインする**
   [Claude Code のセットアップ](https://code.claude.com/docs/en/setup) に沿って入れ、ターミナルで `claude` を一度起動してログインします（`claude auth login` でも可）。VS Code / Cursor の Claude Code 拡張を使っているなら、拡張に同梱の `claude` をそのまま使えます
2. **ダウンロード**
   [Releases の最新版](https://github.com/Rhizobium-gits/jellyfish-ai/releases/latest) から `JellyfishAI-<版>.dmg` をダウンロードします（`.zip` もあります。中身は同じ）
3. **アプリケーションフォルダに入れる**
   .dmg を開き、**JellyfishAI** を隣の **Applications** へドラッグします
4. **初回だけ「このまま開く」**
   アプリケーションフォルダの JellyfishAI を開くと、初回だけ macOS が「開けません」と止めます（Apple の公証を受けていない個人の開発物のため）。ダイアログを閉じ、**システム設定 › プライバシーとセキュリティ** の下の方にある「このまま開く」を押してください。2 回目からは普通に開けます

ダウンロードしたファイルが壊れていないかは、同じリリースの `SHA256SUMS.txt` と `shasum -a 256 JellyfishAI-<版>.dmg` の結果を見比べて確かめられます。

> [!IMPORTANT]
> エージェントは **確認なしで** ファイルの作成・編集・削除やコマンドの実行を行います（Claude Code の Auto モード。危ない操作は Claude Code の安全判定が止めます）。作業フォルダは既定でホームです。詳しくは [権限と安全](#権限と安全) と [SECURITY.md](SECURITY.md)。
>
> エージェントは あなたの Claude Code（Pro / Max プランや API キー）で動き、その使用量を消費します。Claude Code は 1 回の呼び出しの土台だけで数万トークンを使うので、たくさんのクラゲを並列に動かすと使用量の上限に早く届きます。今週どれだけ使ったかはメニューバーのクラゲで確かめられます。

## 起動のしかた

ターミナルは要りません。普通の Mac のアプリと同じように開けます。

| どこから | やり方 |
|---|---|
| **Spotlight** | ⌘Space で「Jellyfish」と打って Enter |
| **Launchpad / アプリ** | Jellyfish AI のアイコンをクリック |
| **Finder** | 「アプリケーション」フォルダの JellyfishAI をダブルクリック |
| **Dock** | アプリケーションフォルダの JellyfishAI を Dock へドラッグしておくと、次からはクリックだけ |
| **ログイン時に自動で** | メニューバーのクラゲ › **ログイン時に自動起動** をオン |

- 起動すると、メニューバーにドット絵のクラゲのアイコンが出ます。Jellyfish AI は常駐型のアプリなので、普段は Dock に出ません（チャットウィンドウを開いている間だけ Dock と ⌘Tab に出ます）
- 動いている最中にもう一度アイコンを開くと、隠していたクラゲを出します。1 体もいなければ新しいクラゲを出します
- 終了はメニューバーのクラゲ › **Jellyfish AI を終了**（⌘Q）。実行中のエージェントは中断されます

## はじめかた

1. どのアプリを使っていても **⌘L** を押すと、新しいクラゲが現れて入力欄が開きます
2. やってほしいことを書いて **Enter**。入力欄が閉じ、クラゲが動きで状態を見せながら作業します（考え中・作業中・完了・エラー）
3. 終わったクラゲを **タップ** すると、チャットウィンドウで結果を読めます。そのまま続けて指示できます
4. 要らなくなったクラゲは **長押し** で消せます

初回の起動では、使い方とエージェントに与える権限の案内が出ます。

## メニューバー

メニューバーのクラゲをクリックすると、いちばん上に **Claude Code のアカウントと今週の使用量** が出ます（VS Code の Claude Code 拡張と同じ情報）。

- ログインしているアカウントのメールとプラン（例：Claude Max 20x）
- 今週の使用量のバーとパーセンテージ：**全モデル** と **Fable** の枠、それぞれのリセット日時（75% でオレンジ、90% で赤）
- メニューを開いたときに、前に読んでから 1 分以上たっていれば Claude Code から読み直します（`claude auth status` と `claude -p /usage`。`/usage` は Claude Code の組み込みコマンドなので、モデルは呼ばずトークンも使いません）。裏で定期的に取りに行くことはしません

その下で、新しいクラゲ・全員を隠す / 表示・過去のセッション・エージェントの一覧と、見た目・大きさ・画面認識・実行ポリシー・PC 操作・チーム・外部ツール（MCP）・ログイン時の自動起動を設定できます。「Jellyfish AI について」「アップデートを確認…」もここにあります。

## できること

- **⌘L で即エージェント**：どのアプリを使っていても ⌘L で新しいクラゲが現れ、そのまま指示を打てる。Enter で送信すると入力欄は閉じ、クラゲが作業を始める
- **動きで状態がわかる**：考え中・作業中（ツール実行中）・完了・エラー・キャンセルを、Claude Code の実際のイベントに合わせて表示。完了したら動きが止まり、CPU をほぼ使わない
- **並列・独立**：クラゲごとに別のセッション・作業フォルダ・履歴・プロセス。1 体が失敗しても他は影響を受けない
- **タップで結果と続き**：チャットウィンドウで結果を読み、同じセッションのまま続けて指示できる。ウィンドウは普通の Mac のウィンドウ（しまう・フルスクリーン・自由にリサイズ）
- **モデルと考える強さ**をクラゲごとにチャットから切り替え（`--model` / `--effort`）
- **使用量が見える**：メニューバーのクラゲに、アカウントと今週の使用量（全モデル・Fable）がバーで出る
- **画面を見て作業**：「この画面」「表示されているエラー」「スクショ」のように画面をはっきり指すと、送信時の画面を撮って渡す（Jellyfish 自身のウィンドウは写さない。「一覧を表示して」のような普通の指示では撮らない。チャットで「毎回 / しない」にも切り替えられる）。画像は長辺 1568px までに縮めて送るので、1 枚あたり約 1,800 トークン（2560px のときの約 4 割）
- **外部ツールは呼んだときだけ**：Claude Code に設定してある MCP サーバー（Figma・Blender など）と claude.ai のコネクタは、指示に名前が出てきたときだけ読み込む。普段は読み込まないぶん 1 回あたり約 4,800 トークン少なく、起動も速い
- **エージェント同士で分業**：クラゲを別のクラゲに近づけると相手が光って「離すとつながる」と出て、離すと線でつながり同じチームになる。エージェントは仲間に作業を頼んだり、新しい仲間を作って分担させたりでき、依頼（依頼元の色）と結果（依頼先の色）が線の上を光って行き来する。⇧ ドラッグでチームごと移動、⌥ を押しながら離すか線の ✂︎ で切れる
- **名前を付けられる**：右クリック「名前を変える…」かチャットの「名前」。エージェント同士はこの名前で呼び合う。名前のないクラゲは「Agent 番号」で、番号は空いている一番小さいものを使い回す（増え続けない。飛んでいたらメニューバーの「番号を 1 から振り直す」）
- **ファイルやページを開く**：「デスクトップの〇〇の資料を開いて」と頼むと、探して Mac の既定のアプリ（プレビュー・Finder・ブラウザなど）で開く。「何て書いてある？」ならチャットで答える
- **ファイルを渡す**：クラゲやチャットウィンドウにファイルをドロップすると添付になる（📎 ボタンでも可）
- **Claude Code の記録に残る**：会話は Claude Code 自身のセッション（`~/.claude/projects`）に保存されるので、VS Code やターミナルからも続きを開ける。メニューバーの「過去のセッションを開く」で、VS Code・ターミナルで作ったセッションもクラゲとして呼び出せる。⌥ を押しながら選ぶとアーカイブ（一覧から外すだけで記録は消さない。「アーカイブ済み」から戻せる）

<p align="center">
  <img src="docs/media/demo-parallel.gif" width="820" alt="複数のクラゲが並列に作業し、終わったものから止まり、長押しで消える様子">
</p>

<p align="center">
  <img src="docs/media/demo-link.gif" width="820" alt="クラゲを近づけると相手が光って線でつながり、⇧ でチームごと動かし、⌥ で切り離し、線の ✂ でも切る様子">
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
| **↑ / ↓**（入力欄） | そのセッションで前に送った指示を呼び出す（1 行目で ↑・最後の行で ↓。VS Code・ターミナルで打った指示も含む。いちばん新しいものの次は書きかけに戻る） |
| **長押し** | そのクラゲを消す（作業中なら「作業は続ける / キャンセルして消す」を確認） |
| **ドラッグ** | 好きな場所へ移動（位置は保存）。別のクラゲに近づけて離すとつながる |
| **⇧ ドラッグ** | 線でつながったチームごと移動 |
| **⌥ を押しながら離す** | そのクラゲのつながりを全部切る |
| **右クリック** | チャット・名前・つなぐ / つながりを切る・キャンセル・隠す・定位置に戻す・削除 |
| **⌥⌘L** / メニューバー | 全員を隠す・表示（隠しても作業は続く） |

チャットウィンドウの下段では、モデル・強さ・画面の添付（自動判定 / 毎回 / しない）・ファイル添付・作業フォルダを変えられます。「Claude Code で開く」で同じセッションをターミナルの `claude --resume` で開けます。

### PC 操作

チャットの **🖱 PC 操作** をオンにしたエージェントだけが、Jellyfish の MCP ツールでこの Mac を操作できます（既定はオフ）。

- `screen_capture`（1 ピクセル = 1 ポイントで撮るので、画像の座標がそのままクリック座標になる）、`list_windows`、`ui_elements`（アクセシビリティでボタンや入力欄の位置を読む）、`open_app`、`mouse_click`、`mouse_drag`、`scroll`、`type_text`、`press_keys`
- 同時に操作できるのは 1 体だけ。操作中は画面の縁がそのエージェントの色で光り、**Esc で止まる**（メニューバーの「PC 操作」からも止められる）
- これらのツールは事前許可せず、毎回 Claude Code の Auto Mode の安全判定を通ります。パスワード入力・支払い・送信・公開の投稿などはユーザーが明示的に頼まない限りしないよう指示しています
- 「システム設定 › プライバシーとセキュリティ」の **アクセシビリティ** と **画面収録** で Jellyfish AI を許可してください
- 画面を読むだけのツール（`screen_capture`・`list_windows`・`ui_elements`）を使っている間も縁が光り、Esc で止まります。`open_app` で開ける URL は http / https だけです
- macOS の許可はアプリ全体に付くので、スイッチがオフのエージェントでも、Claude Code が実行するコマンド（`screencapture` など）は許可の範囲で動けます。使わなくなったら許可を外してください
- Blender は Claude Code に Blender の MCP を入れていれば、指示に「Blender」と書くとエージェントから使えます（[外部ツール（MCP）は呼んだときだけ](#外部ツールmcpは呼んだときだけ)）

### 聞き取り（文字起こし・翻訳・議事録）

チャットの **🎧** を押すと、Mac から流れている音（オンライン会議・動画など。Jellyfish 自身の音は除く）をその場で文字にします。文字起こしは macOS 26 の SpeechAnalyzer で端末内で処理し（初回だけ OS が言語モデルをダウンロード）、時刻つきでテキストファイルに残ります。

- 止めると文字起こしがチャットに添付されるので、「議事録にまとめて」「英語に翻訳して」「Word で報告書にして」と続けて頼める
- エージェントは `read_transcript` で聞き取り中の文字起こしも読めるので、リアルタイムの翻訳・要約もできる（チームの仲間の文字起こしも読める）
- 報告書を書く係と添削する係をチームにすれば、「書く → 添削 → 直す」を最後まで回せる（.docx は pandoc や python-docx で作れる）
- 音の取り込みに **画面収録** の権限が必要。macOS 26 以降

### 外部ツール（MCP）は呼んだときだけ

Claude Code に設定してある MCP サーバー（`~/.claude.json` やプロジェクトの `.mcp.json` にあるもの。Figma・Blender など）と claude.ai のコネクタは、毎回読み込むとそれだけで土台のトークンが増えます。そこで Jellyfish は普段、公式オプション `--strict-mcp-config` を付けて自分の MCP（チーム・PC 操作）だけで動かします。

- 指示に「Blender」「ブレンダー」「Figma」「フィグマ」のようにサーバー名が入っていると、そのターンから読み込む。同じ会話の続き（「もう少し大きくして」など）は読み込んだまま
- 仲間への依頼文に名前が入っていれば、仲間の側でも読み込む
- 読み込まなかったターンでは、エージェントに「外部ツールは読み込んでいない。必要なら名前を入れて頼み直してもらう」と一言伝える
- メニューバーの「外部ツール（MCP）」で「呼んだときだけ / いつも読み込む / 使わない」を切り替えられる。チャットの状態欄に、読み込んでいるときは 🧩 と名前が出る

実測（Haiku 5.5、「OK とだけ返して」1 回）：読み込む 39,945 トークン・3.8 秒 → 読み込まない 35,139 トークン・2.9 秒。

### チーム（分業）

1. クラゲをドラッグして別のクラゲに**近づける**と、相手が点線の輪で光り「離すと 〇〇 とつながる」と出る。離すと線が見える距離にすっと収まってつながる。つながった塊が 1 つのチーム
   - 離れたクラゲとは 右クリック › つなぐ でもつなげる
   - ⇧ を押しながらドラッグするとチームごと動かせる（離すまでに ⇧ を離すと仲間は元の位置へ戻る）
   - チャットウィンドウの上に「👥 〇〇 とチーム」と出て、誰に分担させられるかがわかる
2. どれかに「仲間を作って分担して」「レビュー係に添削してもらって」のように頼む。エージェントは Jellyfish の MCP ツールで
   - `create_teammate`：新しい仲間を自分の隣に出して作業を任せる（作業フォルダ・モデルは引き継ぐ）
   - `assign_task`：チームの仲間に作業を頼む（相手が作業中なら順番待ち）
   - `wait_for_tasks`：頼んだ作業の結果を受け取る
   - `list_team`：仲間と状態を見る
3. 頼まれた側のチャットには「📨 〇〇 からの依頼」として残る。結果は依頼元に戻り、依頼元がまとめる
4. つながりは、線にポインタを置くと出る ✂︎、⌥ を押しながらドラッグして離す（線が赤くなり「離すと つながりを切る」）、または右クリック › つながり で切れる

1 チーム最大 8 体。エージェントが作った仲間がさらに作れるのは 1 段まで（ユーザーのクラゲから数えて 2 段）。メニューバーの「チーム（分業）」で機能ごと止められます。

## アップデート

- メニューバーのクラゲ › **アップデートを確認…** で、新しい版があるか GitHub に確かめます（選んだときだけ。自動では通信しません）
- 新しい版があれば .dmg をダウンロードして、[インストール](#ダウンロードとインストール) と同じようにアプリケーションフォルダへドラッグして置き換えます（設定・クラゲ・会話は残ります）
- 置き換えたあと PC 操作・画面の添付を使うなら、画面収録・アクセシビリティの許可をもう一度付けてください（[知っておくこと](#知っておくこと)）

## ソースからビルド

Xcode は不要で、Command Line Tools の Swift（5.10 以降、6.3 で確認）だけでビルドできます。

```bash
git clone https://github.com/Rhizobium-gits/jellyfish-ai.git
cd jellyfish-ai
scripts/install.sh          # ビルドしてアプリケーションフォルダに入れ、起動する
```

- `scripts/install.sh` で入れておくと、あとは普通のアプリと同じくターミナルなしで開けます。動いている Jellyfish AI は終えてから入れ替えます（作業中のエージェントがいるときは何もしません）
- ビルドだけなら `scripts/build.sh`（→ `dist/JellyfishAI.app`、この Mac の CPU 用）、テストは `scripts/test.sh`（swift test）
- アプリのアイコンは `Resources/AppIcon.png`（1024px の正方形）を macOS のアイコンの角丸の枠に収めて作ります。差し替えてビルドし直せば変わります
- 配布物は `scripts/release.sh` で `dist/release/` に作ります（universal の .dmg・.zip・SHA256SUMS.txt）。`VERSION` と `CHANGELOG.md` を更新してコミット・push し、`scripts/release.sh --publish` で GitHub Releases に公開します

## 権限と安全

- エージェントは Claude Code 公式の **Auto Mode**（`--permission-mode auto`）で動きます。確認なしでファイル操作・コマンド実行を進め、認証情報の持ち出し・意図しない外部送信・取り返しのつかない操作などは Claude Code 側の安全判定が止めます。付けるオプションは起動時に `claude --help` で存在を確かめてから使います
- 今の権限の範囲と使っている `claude` の場所・版はメニューバーの「実行ポリシー」で確認できます
- macOS の権限設定は変更しません。画面認識を使うときだけ「システム設定 › プライバシーとセキュリティ › 画面収録」で Jellyfish AI を許可してください
- Jellyfish AI 自身の通信は「アップデートを確認…」を選んだときに GitHub の公開 API を 1 回読むことだけです（自動の確認・利用状況の送信はしない）。指示や添付は Claude Code を通じて Anthropic に送られます。メニューの使用量は、メニューを開いたときに Claude Code が Anthropic から読みます
- `jellyfish://` URL での外からの操作は、表示の切り替えなど無害なものだけを受け付けます（指示の送信・PC 操作の許可などは受け付けない）
- 詳しくは [SECURITY.md](SECURITY.md)。脆弱性は Security タブから非公開で報告してください

## 知っておくこと

- ⌘L はグローバルに使うため、ブラウザのアドレスバー移動と競合します。`settings.json` の `hotKeyPassthroughApps` に bundle ID を入れたアプリが前面の間は ⌘L をそのアプリに返します。他のアプリが先に ⌘L を使っていれば ⌃⌥L に切り替えます
- アプリを終了すると、実行中のエージェントは中断されます（次回起動時に「中断」として残ります）
- アドホック署名なので、新しい版に入れ替える（ビルドし直す）と、macOS は別のアプリとみなします。画面収録・アクセシビリティは、システム設定で Jellyfish AI をいったん外して（−）許可し直してください

## データの保存場所

`~/Library/Application Support/JellyfishAI/`（設定・クラゲ・エージェントごとの履歴と生イベント・文字起こし・ログ）。メニューバーの「設定フォルダを開く」で開けます。エージェントに渡した画面の画像は 7 日で消え、クラゲを消すとそのクラゲの生イベントと画像も消えます。会話そのものは Claude Code のセッションとして `~/.claude/projects/` に残ります。環境変数 `JELLYFISH_DATA_DIR` を付けて起動すると別の場所を使います（デモ録画・テスト用）。

### アンインストール

1. メニューバーのクラゲで「ログイン時に自動起動」をオフにしてから「Jellyfish AI を終了」
2. アプリケーションフォルダの JellyfishAI をゴミ箱へ
3. データも消すなら `~/Library/Application Support/JellyfishAI/` を削除（ウインドウの位置などは `defaults delete ai.jellyfish.desktop`）
4. 許可した権限は「システム設定 › プライバシーとセキュリティ」の各項目（画面収録・アクセシビリティ）から外せます

Claude Code のセッション（`~/.claude/projects/`）は Claude Code のものなので、Jellyfish を消しても残ります。

## 開発

- 設計メモ：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- `jellyfish://` URL スキームで外から操作できます
  - いつでも（ショートカット.app・Raycast など）：`new`, `open?agent=2`, `toggle`, `show`, `hide`, `arrange`, `style?v=pixel|realistic`, `scale?v=1.25`
  - 環境変数 `JELLYFISH_AUTOMATION=1` を付けて起動したときだけ（自動テスト・デモ録画用）：`renumber`, `prompt?agent=2&text=…`, `type?agent=2&text=…`, `new?cwd=…`, `folder?agent=2&path=…`, `pc?agent=2&on=1`, `rename?agent=2&name=…`, `link?a=2&b=3`, `unlink?a=2&b=3`, `move?agent=2&dx=…`, `press?agent=2`, `state?agent=2&s=working`, `remove?agent=2`, `login?on=1`, `debug`
- `.build/debug/JellyfishAI --pixel-sheet out.png` でドット絵のコマ一覧、`--settle-test` で完了時の静止を検証、`--account-menu out.png` でメニューのアカウント・使用量の欄を描き出す（実際に claude から読む）
- README の GIF は `scripts/demo/record.sh` で撮り直せます（普段のデータには触れず、空のデモ用データで実際に Claude Code を動かして録画。Pillow と ffmpeg が必要）

## ライセンス

[MIT](LICENSE)。変更履歴は [CHANGELOG.md](CHANGELOG.md)。
