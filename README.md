# Backlog ニュースレター生成ツール

Backlogの課題情報から、カテゴリーごとの日次ニュースレターを自動生成し、Slackに通知するツールです。

## セットアップ

### 1. 依存ツールのインストール

| ツール | 用途 | インストール |
|--------|------|-------------|
| [bee](https://nulab.github.io/bee/getting-started/installation/) | Backlog CLI | `npm install -g @niclab/bee` |
| [jq](https://jqlang.github.io/jq/download/) | JSON処理 | `sudo apt install jq` |
| [Node.js](https://nodejs.org/) | ニュースレター生成アプリ実行 | v18以上を推奨 |
| [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview) | ニュースレター生成 | リポジトリで `npm install`（下記） |
| curl | Slack API通信 | 通常プリインストール済み |

> ニュースレター生成は Claude Agent SDK（`@anthropic-ai/claude-agent-sdk`）で行います。
> 認証は Claude Code のログインを継承するため、初回のみ `claude login` を実行してください（`ANTHROPIC_API_KEY` は不要）。

### 2. Node依存のインストール

```bash
npm install
```

### 3. Backlog認証

```bash
bee auth login
```

### 4. .env の作成

```bash
cp .env.example .env
```

`.env` を編集して値を設定:

```env
# Backlogプロジェクトキー（generate.shで引数省略時に使用）
BACKLOG_PROJECT=S_PROJECT

# Backlogスペース名（課題リンク生成に使用）
# https://<SPACE_NAME>.backlog.jp の部分
BACKLOG_SPACE_NAME=your-space

# Slack Bot Token (chat:write スコープが必要)
# https://api.slack.com/apps で作成
SLACK_TOKEN=xoxb-xxxx

# カテゴリーとSlackチャンネルの対応（カンマ区切り）
# 空カテゴリー（:#channel）で全体サマリ(news.md)を送信
SNG_SLACK_NOTIFY=カテゴリ1:#tech-news,カテゴリ2:#global-news,:#summary-ch
```

### 5. プロジェクト固有コンテキストの作成（任意・推奨）

`context/{プロジェクトキー}/` にファイルを置くと、生成プロンプトに自動で注入されます（gitignore対象）。
雛形は `context/example/` を参照してください。

| ファイル | 内容 | 注入先 |
|---------|------|--------|
| `service.md` | サービス概要・ユーザー像（呼称）・用語 | 全生成フェーズ |
| `data-notes.md` | コメント・変更履歴の読み方の注意（例: 朝会メモの扱い） | Backlog生データを直接読むフェーズのみ |

```bash
mkdir -p context/S_PROJECT
cp context/example/service.md context/S_PROJECT/service.md
# 内容を編集
```

### 6. cron設定（自動実行する場合）

```bash
crontab -e
```

```cron
# 平日毎朝9時に前営業日分を生成+Slack通知（休日明けはまとめて取得）
3 9 * * 1-5 cd /path/to/backlog-news-letter && ./cron_run.sh >> /tmp/backlog-newsletter.log 2>&1
```

## 使い方

### ニュースレター生成

```bash
# プロジェクトキーを指定
./generate.sh S_SD 2026-03-24

# .env の BACKLOG_PROJECT を使用
./generate.sh 2026-03-24

# 当日限りの追加情報をパイプで渡す（恒久的な前提は context/ へ）
echo "本日15時から全社会議があります" | ./generate.sh 2026-03-24
```

### Slack通知

```bash
./notify_slack.sh 2026-03-24
```

## 出力

```
2026-03-24/
├── backlog/
│   ├── カテゴリ1.txt
│   ├── カテゴリ2.txt
│   └── ...
├── additional.txt           # 追加情報（渡した場合のみ）
├── カテゴリ1news.md
├── カテゴリ2news.md
├── news.md　　　　　　　　　# 全カテゴリを統合したnews
└── ...
```

## 仕組み

1. `bee` CLIで指定日に更新・作成されたissueを取得
2. 各issueの説明・コメント・親課題情報を取得
3. Backlogカテゴリーごとに `.txt` ファイルに整理
4. カテゴリーごとに Claude Agent SDK（`npm run gen:*`）でニュースレター（Markdown）を生成
   （`context/{プロジェクトキー}/` があればプロンプトに注入）
5. `notify_slack.sh` で対応するSlackチャンネルに投稿
