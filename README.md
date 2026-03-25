# Backlog ニュースレター生成ツール

Backlogの課題情報から、カテゴリーごとの日次ニュースレターを自動生成し、Slackに通知するツールです。

## セットアップ

### 1. 依存ツールのインストール

| ツール | 用途 | インストール |
|--------|------|-------------|
| [bee](https://nulab.github.io/bee/getting-started/installation/) | Backlog CLI | `npm install -g @niclab/bee` |
| [jq](https://jqlang.github.io/jq/download/) | JSON処理 | `sudo apt install jq` |
| [claude](https://docs.anthropic.com/en/docs/claude-code/overview) | ニュースレター生成 | `npm install -g @anthropic-ai/claude-code` |
| curl | Slack API通信 | 通常プリインストール済み |

### 2. Backlog認証

```bash
bee auth login
```

### 3. .env の作成

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

### 4. cron設定（自動実行する場合）

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

# 追加情報をパイプで渡す
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
2. 各issueのコメント・親課題情報を取得
3. Backlogカテゴリーごとに `.txt` ファイルに整理
4. カテゴリーごとに `claude -p` でニュースレター（Markdown）を生成
5. `notify_slack.sh` で対応するSlackチャンネルに投稿
