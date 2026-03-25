#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Slack ニュースレター通知スクリプト
# Usage: ./notify_slack.sh YYYY-MM-DD
#
# .env に以下を設定:
#   SLACK_TOKEN=xoxb-xxxx
#   SNG_SLACK_NOTIFY=カテゴリ名:#channel1,カテゴリ2名:#channel2
# =============================================================================

DATE="${1:-}"

if [ -z "$DATE" ]; then
  echo "Usage: $0 YYYY-MM-DD" >&2
  echo "Example: $0 2026-03-24" >&2
  exit 1
fi

if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "エラー: 日付は YYYY-MM-DD 形式で指定してください" >&2
  exit 1
fi

# --- 依存チェック ---
missing=0
if ! command -v curl >/dev/null 2>&1; then
  echo "エラー: curl が見つかりません" >&2
  echo "  インストール: https://curl.se/download.html" >&2
  missing=1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "エラー: jq が見つかりません" >&2
  echo "  インストール: https://jqlang.github.io/jq/download/" >&2
  missing=1
fi
[ "$missing" -eq 1 ] && exit 1

# --- .env 読み込み ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "エラー: .env ファイルが見つかりません" >&2
  echo "  ${ENV_FILE} を作成し、以下を設定してください:" >&2
  echo "    SLACK_TOKEN=xoxb-xxxx" >&2
  echo "    SNG_SLACK_NOTIFY=カテゴリ名:#channel1,カテゴリ2名:#channel2" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

if [ -z "${SLACK_TOKEN:-}" ]; then
  echo "エラー: SLACK_TOKEN が .env に設定されていません" >&2
  echo "  Slack App のトークン取得: https://api.slack.com/apps" >&2
  echo "  必要なスコープ: chat:write" >&2
  exit 1
fi

if [ -z "${SNG_SLACK_NOTIFY:-}" ]; then
  echo "エラー: SNG_SLACK_NOTIFY が .env に設定されていません" >&2
  echo "  形式: カテゴリ名:#channel1,カテゴリ2名:#channel2" >&2
  exit 1
fi

# --- ニュースレターディレクトリ確認 ---
NEWS_DIR="${SCRIPT_DIR}/${DATE}"
if [ ! -d "$NEWS_DIR" ]; then
  echo "エラー: ${NEWS_DIR} が見つかりません。先に generate.sh を実行してください。" >&2
  exit 1
fi

# --- SNG_SLACK_NOTIFY をパースして送信 ---
post_to_slack() {
  local channel="$1"
  local text="$2"

  local response
  response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -n --arg channel "$channel" --arg text "$text" \
      '{ channel: $channel, markdown_text: $text, username: "Backlog Daily News", icon_emoji: ":newspaper:" }')")

  local ok
  ok=$(echo "$response" | jq -r '.ok')
  if [ "$ok" = "true" ]; then
    echo "    送信成功"
  else
    local error
    error=$(echo "$response" | jq -r '.error // "不明なエラー"')
    echo "    送信失敗: ${error}" >&2
  fi
}

echo "=== Slack通知開始 (${DATE}) ==="

IFS=',' read -ra MAPPINGS <<< "$SNG_SLACK_NOTIFY"
for mapping in "${MAPPINGS[@]}"; do
  # "カテゴリ名:#channel" を分割
  category="${mapping%%:*}"
  channel="${mapping#*:}"

  if [ -z "$channel" ]; then
    echo "  スキップ（不正な形式）: ${mapping}" >&2
    continue
  fi

  # カテゴリー空 → news.md（全体サマリ）、それ以外 → {カテゴリー}news.md
  safe_category=$(echo "$category" | tr '/' '_')
  news_file="${NEWS_DIR}/${safe_category}news.md"

  if [ ! -f "$news_file" ]; then
    echo "  スキップ（ファイルなし）: ${news_file}"
    continue
  fi

  content=$(cat "$news_file")
  if [ -z "$content" ]; then
    echo "  スキップ（内容が空）: ${news_file}"
    continue
  fi

  echo "  送信中: ${category} → ${channel}"
  post_to_slack "$channel" "$content"
done

echo "=== 完了 ==="
