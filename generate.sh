#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Backlog ニュースレター生成スクリプト
# Usage: ./generate.sh PROJECT_KEY YYYY-MM-DD
#        echo "追加情報" | ./generate.sh PROJECT_KEY YYYY-MM-DD
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# 引数パース
# 形式: [PROJECT_KEY] YYYY-MM-DD [START_DATE]
#   PROJECT_KEY省略時は .env の BACKLOG_PROJECT を使用
#   START_DATE省略時は DATE と同じ（1日分）
PROJECT=""
DATE=""
START_DATE=""

date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
args=()
for arg in "$@"; do
  args+=("$arg")
done

case ${#args[@]} in
  1)
    # YYYY-MM-DD
    DATE="${args[0]}"
    ;;
  2)
    if [[ "${args[0]}" =~ $date_re ]]; then
      # YYYY-MM-DD START_DATE
      DATE="${args[0]}"
      START_DATE="${args[1]}"
    else
      # PROJECT_KEY YYYY-MM-DD
      PROJECT="${args[0]}"
      DATE="${args[1]}"
    fi
    ;;
  3)
    # PROJECT_KEY YYYY-MM-DD START_DATE
    PROJECT="${args[0]}"
    DATE="${args[1]}"
    START_DATE="${args[2]}"
    ;;
  *)
    echo "Usage: $0 [PROJECT_KEY] YYYY-MM-DD [START_DATE]" >&2
    echo "  PROJECT_KEY省略時は .env の BACKLOG_PROJECT を使用" >&2
    echo "  START_DATE指定時はその日からDATEまでの範囲を取得" >&2
    exit 1
    ;;
esac

PROJECT="${PROJECT:-${BACKLOG_PROJECT:-}}"
START_DATE="${START_DATE:-$DATE}"

if [ -z "$PROJECT" ]; then
  echo "エラー: プロジェクトキーが指定されていません" >&2
  echo "  引数で指定するか、.env に BACKLOG_PROJECT を設定してください" >&2
  exit 1
fi

# --- Step 1: 依存チェック ---
missing=0
if ! command -v bee >/dev/null 2>&1; then
  echo "エラー: bee CLI が見つかりません" >&2
  echo "  インストール: https://nulab.github.io/bee/getting-started/installation/" >&2
  missing=1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "エラー: jq が見つかりません" >&2
  echo "  インストール: https://jqlang.github.io/jq/download/" >&2
  missing=1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "エラー: claude CLI が見つかりません" >&2
  echo "  インストール: https://docs.anthropic.com/en/docs/claude-code/overview" >&2
  missing=1
fi
[ "$missing" -eq 1 ] && exit 1

# --- Step 2: 初期化 ---
if ! [[ "$DATE" =~ $date_re ]]; then
  echo "エラー: 日付は YYYY-MM-DD 形式で指定してください" >&2
  exit 1
fi
if ! [[ "$START_DATE" =~ $date_re ]]; then
  echo "エラー: 開始日は YYYY-MM-DD 形式で指定してください" >&2
  exit 1
fi

OUTPUT_DIR="${SCRIPT_DIR}/${DATE}/backlog"
NEWS_DIR="${SCRIPT_DIR}/${DATE}"
mkdir -p "$OUTPUT_DIR"

# 標準入力から追加情報を読み取り（パイプがあれば）
ADDITIONAL_FILE="${NEWS_DIR}/additional.txt"
if [ ! -t 0 ]; then
  cat > "$ADDITIONAL_FILE"
  if [ ! -s "$ADDITIONAL_FILE" ]; then
    rm -f "$ADDITIONAL_FILE"
  else
    echo "=== 追加情報を読み込みました ==="
  fi
fi

# --- Step 3: issue一覧取得（ページネーション対応） ---
fetch_all_issues() {
  local since="$1" until="$2" project="$3" filter_type="$4"
  local offset=0 count=100 batch
  local all_issues="[]"

  while true; do
    batch=$(bee issue list -p "$project" \
      "--${filter_type}-since" "$since" \
      "--${filter_type}-until" "$until" \
      --json -L "$count" --offset "$offset" 2>/dev/null) || batch="[]"

    local batch_len
    batch_len=$(echo "$batch" | jq 'length')

    if [ "$batch_len" -eq 0 ]; then
      break
    fi

    all_issues=$(echo "$all_issues" "$batch" | jq -s '.[0] + .[1]')
    offset=$((offset + count))

    if [ "$batch_len" -lt "$count" ]; then
      break
    fi
  done

  echo "$all_issues"
}

RANGE_LABEL="${START_DATE}"
[ "$START_DATE" != "$DATE" ] && RANGE_LABEL="${START_DATE} ~ ${DATE}"

echo "=== issue取得中 (updated: ${RANGE_LABEL}) ==="
UPDATED_ISSUES=$(fetch_all_issues "$START_DATE" "$DATE" "$PROJECT" "updated")

echo "=== issue取得中 (created: ${RANGE_LABEL}) ==="
CREATED_ISSUES=$(fetch_all_issues "$START_DATE" "$DATE" "$PROJECT" "created")

ALL_ISSUES=$(echo "$UPDATED_ISSUES" "$CREATED_ISSUES" | jq -s '.[0] + .[1] | unique_by(.issueKey)')
ISSUE_COUNT=$(echo "$ALL_ISSUES" | jq 'length')
echo "=== 対象issue: ${ISSUE_COUNT}件 ==="

if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo "対象issueが0件のため終了します。"
  exit 0
fi

# --- Step 4 & 5: 各issue詳細取得 → カテゴリー別ファイル書き出し ---
declare -A PARENT_CACHE

fetch_parent_info() {
  local parent_id="$1"
  if [ -n "${PARENT_CACHE[$parent_id]+x}" ]; then
    echo "${PARENT_CACHE[$parent_id]}"
    return
  fi
  local parent_json
  parent_json=$(bee api "/api/v2/issues/${parent_id}" --json 2>/dev/null) || parent_json="{}"
  local parent_key parent_summary
  parent_key=$(echo "$parent_json" | jq -r '.issueKey // "不明"')
  parent_summary=$(echo "$parent_json" | jq -r '.summary // "取得失敗"')
  PARENT_CACHE[$parent_id]="${parent_key}: ${parent_summary}"
  echo "${parent_key}: ${parent_summary}"
}

for i in $(seq 0 $((ISSUE_COUNT - 1))); do
  issue=$(echo "$ALL_ISSUES" | jq ".[$i]")

  issue_key=$(echo "$issue" | jq -r '.issueKey')
  summary=$(echo "$issue" | jq -r '.summary')
  status=$(echo "$issue" | jq -r '.status.name')
  assignee=$(echo "$issue" | jq -r '.assignee.name // "未割り当て"')
  parent_id=$(echo "$issue" | jq -r '.parentIssueId // empty')
  category=$(echo "$issue" | jq -r 'if (.category | length) > 0 then .category[0].name else "未分類" end')
  issue_type=$(echo "$issue" | jq -r '.issueType.name // ""')
  priority=$(echo "$issue" | jq -r '.priority.name // ""')
  due_date=$(echo "$issue" | jq -r '.dueDate // empty')
  created_date=$(echo "$issue" | jq -r '.created // empty')
  updated_date=$(echo "$issue" | jq -r '.updated // empty')

  # カテゴリーファイルパス（ファイル名不正文字を置換）
  safe_category=$(echo "$category" | tr '/' '_')
  cat_file="${OUTPUT_DIR}/${safe_category}.txt"

  # 親課題情報
  parent_info=""
  if [ -n "$parent_id" ]; then
    parent_info=$(fetch_parent_info "$parent_id")
  fi

  # コメント・変更履歴取得（期間内のみフィルタ）
  all_comments=$(bee api "/api/v2/issues/${issue_key}/comments" \
    -f count=100 -f order=asc --json 2>/dev/null) || all_comments="[]"

  comments=$(echo "$all_comments" | jq --arg s "$START_DATE" --arg e "$DATE" '
    [.[] | select(.content != null and .content != "") |
     select(.created >= ($s + "T00:00:00Z") and .created <= ($e + "T23:59:59Z")) |
     { author: .createdUser.name, content: .content, created: .created }]')

  changes=$(echo "$all_comments" | jq --arg s "$START_DATE" --arg e "$DATE" '
    [.[] | select(.changeLog | length > 0) |
     select(.created >= ($s + "T00:00:00Z") and .created <= ($e + "T23:59:59Z")) |
     { author: .createdUser.name, created: .created,
       changes: [.changeLog[] | select(.field != "notification") |
         { field: .field, from: .originalValue, to: .newValue }] } |
     select(.changes | length > 0)]')

  # ファイルに追記
  {
    echo "================================================================"
    echo "課題: ${issue_key}"
    echo "タイトル: ${summary}"
    echo "種別: ${issue_type}"
    echo "ステータス: ${status}"
    echo "優先度: ${priority}"
    echo "担当者: ${assignee}"
    [ -n "$due_date" ] && echo "期限日: ${due_date}"
    [ -n "$parent_info" ] && echo "親課題: ${parent_info}"
    echo "作成日: ${created_date}"
    echo "最終更新: ${updated_date}"
    echo ""

    change_count=$(echo "$changes" | jq 'length')
    if [ "$change_count" -gt 0 ]; then
      echo "--- この期間の変更履歴 (${change_count}件) ---"
      echo "$changes" | jq -r '.[] | "[\(.created)] \(.author):" + (.changes | map("  \(.field): \(.from // "なし") → \(.to // "なし")") | join("\n"))'
      echo ""
    fi

    comment_count=$(echo "$comments" | jq 'length')
    if [ "$comment_count" -gt 0 ]; then
      echo "--- この期間のコメント (${comment_count}件) ---"
      echo "$comments" | jq -r '.[] | "[\(.created)] \(.author):\n\(.content)\n"'
    fi

    if [ "$change_count" -eq 0 ] && [ "$comment_count" -eq 0 ]; then
      echo "--- この期間の変更・コメント: なし ---"
    fi
    echo ""
  } >> "$cat_file"

  echo "  [${i}/${ISSUE_COUNT}] ${issue_key} → ${safe_category}"
  sleep 0.3
done

# --- Step 6: カテゴリーごとに claude -p でニュースレター生成 ---
echo ""
echo "=== ニュースレター生成中 ==="

SPACE_NAME="${BACKLOG_SPACE_NAME:-}"
if [ -z "$SPACE_NAME" ]; then
  echo "警告: BACKLOG_SPACE_NAME が .env に設定されていません。課題リンクが生成できません。" >&2
fi

# 追加情報があればプロンプトに含める
additional_prompt=""
if [ -f "$ADDITIONAL_FILE" ]; then
  additional_prompt="

## 追加情報（Backlog以外）
$(cat "$ADDITIONAL_FILE")"
fi

space_prompt=""
if [ -n "$SPACE_NAME" ]; then
  space_prompt="SPACE_NAMEは「${SPACE_NAME}」です。"
fi

PERIOD_LABEL="$DATE"
if [ "$START_DATE" != "$DATE" ]; then
  PERIOD_LABEL="${START_DATE} ~ ${DATE}"
fi

for txt in "${OUTPUT_DIR}"/*.txt; do
  [ -f "$txt" ] || continue
  cat_name=$(basename "$txt" .txt)
  news_file="${NEWS_DIR}/${cat_name}news.md"

  echo "  生成中: ${cat_name}news.md ..."
  cat "$txt" | claude -p \
    "以下の${cat_name}のBacklog課題情報から、${PERIOD_LABEL}のニュースレターを生成してください。${space_prompt}${additional_prompt}" \
    > "$news_file"
done

# --- Step 7: 全体サマリ生成（3段階） ---
OVERVIEW_DIR="${OUTPUT_DIR}/overview"
mkdir -p "$OVERVIEW_DIR"
SUMMARY_FILE="${NEWS_DIR}/news.md"

# Step 7-1: 全backlogデータからドラフトサマリを overview に生成
echo ""
echo "=== 全体サマリ生成中 ==="
echo "  Step 7-1: 主要イベントのピックアップ ..."
cat "${OUTPUT_DIR}"/*.txt | claude -p \
  "以下は${PERIOD_LABEL}の全カテゴリーのBacklog課題情報です。着手・リリース済（完了・処理済み）・新規起票など大きなイベントをピックアップし、全体サマリテンプレートに沿ってnews.mdを作成してください。${space_prompt}${additional_prompt}" \
  > "${OVERVIEW_DIR}/news.md"

# Step 7-2: サマリで言及されたチケットの詳細情報を overview に取得
echo "  Step 7-2: ピックアップチケットの詳細取得 ..."
picked_keys=$(grep -oP '[A-Z][A-Z0-9_]+-\d+' "${OVERVIEW_DIR}/news.md" | sort -u)

for key in $picked_keys; do
  detail_file="${OVERVIEW_DIR}/${key}.md"
  [ -f "$detail_file" ] && continue

  issue_json=$(bee api "/api/v2/issues/${key}" --json 2>/dev/null) || continue

  # 全コメント・変更履歴を取得
  all_comments=$(bee api "/api/v2/issues/${key}/comments" \
    -f count=100 -f order=asc --json 2>/dev/null) || all_comments="[]"

  {
    echo "# ${key}: $(echo "$issue_json" | jq -r '.summary')"
    echo ""
    echo "- 種別: $(echo "$issue_json" | jq -r '.issueType.name // ""')"
    echo "- ステータス: $(echo "$issue_json" | jq -r '.status.name')"
    echo "- 優先度: $(echo "$issue_json" | jq -r '.priority.name // ""')"
    echo "- 担当者: $(echo "$issue_json" | jq -r '.assignee.name // "未割り当て"')"
    echo "- 期限日: $(echo "$issue_json" | jq -r '.dueDate // "なし"')"
    echo "- 作成日: $(echo "$issue_json" | jq -r '.created')"
    echo "- 最終更新: $(echo "$issue_json" | jq -r '.updated')"
    parent_id=$(echo "$issue_json" | jq -r '.parentIssueId // empty')
    if [ -n "$parent_id" ]; then
      echo "- 親課題: $(fetch_parent_info "$parent_id")"
    fi
    echo ""

    desc=$(echo "$issue_json" | jq -r '.description // ""')
    if [ -n "$desc" ]; then
      echo "## 説明"
      echo "$desc"
      echo ""
    fi

    echo "## 変更履歴"
    echo "$all_comments" | jq -r '
      [.[] | select(.changeLog | length > 0) |
       { author: .createdUser.name, created: .created,
         changes: [.changeLog[] | select(.field != "notification") |
           { field: .field, from: .originalValue, to: .newValue }] } |
       select(.changes | length > 0)] |
      if length == 0 then "なし"
      else .[] | "[\(.created)] \(.author)\n" +
        (.changes | map("  \(.field): \(.from // "なし") → \(.to // "なし")") | join("\n"))
      end'
    echo ""

    echo "## コメント"
    echo "$all_comments" | jq -r '
      [.[] | select(.content != null and .content != "")] |
      if length == 0 then "なし"
      else .[] | "[\(.created)] \(.createdUser.name):\n\(.content)\n"
      end'
  } > "$detail_file"

  echo "    取得: ${key}"
  sleep 0.3
done

# Step 7-3: overview内の全ファイルをまとめて最終版 news.md を一発生成
echo "  Step 7-3: 最終版 news.md 生成 ..."
cat "${OVERVIEW_DIR}"/*.md | claude -p \
  "以下はドラフトサマリとピックアップチケットの詳細情報です。これらを基に、全体サマリテンプレートに沿って最終版のnews.mdを生成してください。リリース済み（完了・処理済み）のチケットには、ビジネス価値・期待できるKPIや顧客満足度向上ポイントを3行程度で追記してください。${space_prompt}" \
  > "$SUMMARY_FILE"

echo ""
echo "=== 完了 ==="
echo "Backlogデータ: ${OUTPUT_DIR}/"
for f in "${NEWS_DIR}"/*news.md "${SUMMARY_FILE}"; do
  [ -f "$f" ] && echo "ニュースレター: $f"
done
