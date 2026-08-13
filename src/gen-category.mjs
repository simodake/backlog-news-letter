// カテゴリ別ニュースレター生成アプリ（旧 generate.sh Step 6 の `claude -p` 相当）。
// stdin: カテゴリの Backlog 課題情報（.txt の内容）
// env:   CATEGORY_NAME, PERIOD_LABEL, SPACE_NAME, ADDITIONAL_INFO, SERVICE_CONTEXT, DATA_NOTES
import { runApp } from './lib/runQuery.mjs';
import { buildContextPrompt } from './lib/contextPrompt.mjs';

const categoryName = process.env.CATEGORY_NAME ?? '';
const periodLabel = process.env.PERIOD_LABEL ?? '';
const spaceName = process.env.SPACE_NAME ?? '';
const additionalInfo = process.env.ADDITIONAL_INFO ?? '';

const spacePrompt = spaceName ? `SPACE_NAMEは「${spaceName}」です。` : '';
// Backlogの生データ（コメント・変更履歴）を直接読むフェーズなので DATA_NOTES も注入する
const contextPrompt = buildContextPrompt({ includeDataNotes: true });
const additionalPrompt = additionalInfo
  ? `\n\n## 追加情報（Backlog以外）\n${additionalInfo}`
  : '';

runApp((input) => {
  return `以下の${categoryName}のBacklog課題情報から、${periodLabel}のニュースレターを生成してください。ファイル操作は不要です。Markdown本文だけを出力してください。${spacePrompt}${contextPrompt}${additionalPrompt}

${input}`;
});
