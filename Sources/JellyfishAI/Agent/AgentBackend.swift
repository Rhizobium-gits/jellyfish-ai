import Foundation

/// AI バックエンドから届くイベントを正規化したもの。
/// クラゲの状態はこのイベントだけから決まる（応答テキストの内容から推測しない）。
enum AgentEvent {
    case started(session: String?, model: String?, permissionMode: String?)
    case text(String)
    case thinking
    case toolStarted(name: String, summary: String)
    case toolFinished(isError: Bool)
    case finished(success: Bool, result: String, costUSD: Double?, durationMs: Int?)
    /// 使ったトークン（モデルごと。CLI が出したものだけ。model が nil なら CLI の既定のモデル）
    case usage(model: String?, input: Int, output: Int, cached: Int)
}

/// ターンごとの実行オプション（クラゲごとにチャット画面から変えられる）
struct AgentRunOptions {
    /// nil なら既定
    var model: String?
    /// low / medium / high / xhigh / max。nil なら既定
    var effort: String?
    /// チーム機能：Jellyfish の MCP サーバー設定・追加の system prompt・事前許可するツール・環境変数
    var mcpConfig: URL? = nil
    var appendSystemPrompt: String? = nil
    var allowedTools: [String] = []
    var env: [String: String] = [:]
    /// ユーザー設定の MCP サーバー・claude.ai コネクタを読み込まない（--strict-mcp-config）
    var strictMCPConfig = false
    /// 作業フォルダのほかに読み書きを許すフォルダ（チームの受け渡し用のフォルダ）。
    /// Claude は --add-dir、Codex はサンドボックスの writable_roots、Gemini は --include-directories
    var addDirs: [URL] = []
    /// 指示に添える画像（Codex の --image。Codex はファイルを読めても画像は見られないので、画面の画像・落とした画像を添える）
    var images: [URL] = []
    /// Codex・Gemini に渡す Jellyfish の MCP（チームのツール）：起動するコマンドと引数、出してよいツールの名前
    var mcpBridge: (command: String, args: [String])? = nil
    var mcpTools: [String] = []
    /// Codex の developer_instructions に入れるチームの案内（Gemini は MCP の instructions で渡す）
    var instructions: String? = nil
}

/// 実行中の 1 ターン
protocol AgentHandle: AnyObject {
    var isRunning: Bool { get }
    /// 実行中のプロセス（チーム用ソケットにつないできた相手が、このエージェントの claude の子かを確かめるため）
    var processID: Int32? { get }
    func cancel()
}

/// AI の実行基盤。Claude Code CLI 以外（Claude API / OpenAI API / ローカル LLM など）も
/// このプロトコルを実装すれば同じクラゲで動かせる。
protocol AgentBackend {
    /// どの AI か
    var engine: AgentEngine { get }
    /// CLI が会話の ID を自分で決めるか（Codex）。true なら started の session を受け取って使う
    var assignsSessionID: Bool { get }
    var displayName: String { get }
    /// クラゲごとの指定が無いときに使うモデル（設定の model。nil = Claude Code の既定、"auto" = 自動）
    var defaultModel: String? { get }
    /// 実際に適用される権限ポリシーの説明（ユーザーが確認できるように UI に出す）
    var policyDescription: String { get }

    /// 1 ターン実行する。onEvent / onExit はメインスレッドで呼ばれる。
    func run(prompt: String,
             sessionID: String,
             resume: Bool,
             cwd: URL,
             logDir: URL,
             options: AgentRunOptions,
             onEvent: @escaping (AgentEvent) -> Void,
             onExit: @escaping (_ status: Int32, _ stderrTail: String) -> Void) throws -> AgentHandle
}
