// Claude Agent SDK 呼び出しの共通ラッパー。
// 旧 `claude -p "$prompt"` 相当を programmatic に実行する。
// - CLAUDE.md（編集者ペルソナ + フォーマット仕様）を system prompt 文字列として明示的に渡す。
//   claude_code preset は使わない: preset はエージェント的挙動（検証コメントやコードフェンスの
//   混入）を招き、ニュースレター本文だけを出力したい用途には過剰なため。
// - ニュースレターはテキスト生成のみで、ファイル操作等は不要なので全ツールを無効化する。
// - 認証は Claude Code CLI ログイン（~/.claude）をそのまま継承する。ANTHROPIC_API_KEY は使わない。
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { readFileSync } from 'node:fs';
import { query } from '@anthropic-ai/claude-agent-sdk';

// このファイルは <project>/src/lib/runQuery.mjs。CLAUDE.md 探索の基点はプロジェクトルート。
const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

// 出力を本文のみに固定するための制約。print mode を持たない SDK では
// モデルが前置き（「〜しました」等）を足しがちなため system prompt で明示的に禁止する。
const OUTPUT_CONSTRAINT = `

# 出力に関する厳守事項
- 出力はニュースレターのMarkdown本文のみとすること。
- 前置き・後書き・作業説明・「〜しました」等のメタコメントを一切書かないこと。
- 出力全体を \`\`\` のコードフェンスで囲まないこと。`;

// プロジェクトの CLAUDE.md（ニュースレター編集者の指示 + 出力フォーマット）を system prompt に使う。
function loadSystemPrompt() {
  try {
    return readFileSync(resolve(PROJECT_ROOT, 'CLAUDE.md'), 'utf8') + OUTPUT_CONSTRAINT;
  } catch {
    return OUTPUT_CONSTRAINT.trim(); // CLAUDE.md が無くても本文限定の制約は課す
  }
}

// 出力全体が ```markdown ... ``` のように単一のコードフェンスで囲まれていれば剥がす。
function stripWrappingFence(text) {
  const trimmed = text.trim();
  const fence = trimmed.match(/^```[^\n]*\n([\s\S]*?)\n```$/);
  return fence ? fence[1] : trimmed;
}

// stdin を最後まで読み切って文字列で返す。
export async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

// prompt を渡して最終的な Markdown 本文（文字列）を返す。
// 失敗時（result 未取得 / error サブタイプ）は例外を投げる。
export async function runQuery(prompt) {
  const options = {
    settingSources: [], // 余計なフィルタ設定を読み込まない（system prompt は下で明示指定）
    allowedTools: [],
    permissionMode: 'dontAsk',
    maxTurns: 1,
    cwd: PROJECT_ROOT,
  };
  const systemPrompt = loadSystemPrompt();
  if (systemPrompt) options.systemPrompt = systemPrompt;
  // モデルは既定で CLI デフォルト（現状維持）。上書きしたい場合のみ環境変数で指定。
  if (process.env.NEWSLETTER_MODEL) {
    options.model = process.env.NEWSLETTER_MODEL;
  }

  let result;
  for await (const message of query({ prompt, options })) {
    if (message.type !== 'result') continue;
    if (message.subtype === 'success') {
      result = message.result;
    } else {
      throw new Error(`Claude Agent SDK がエラーを返しました: ${message.subtype}`);
    }
  }

  if (result === undefined) {
    throw new Error('Claude Agent SDK から result メッセージを取得できませんでした');
  }
  return stripWrappingFence(result);
}

// 各アプリ共通の実行フロー: prompt を組み立てる関数を受け取り、
// stdin を読み → runQuery → stdout 出力。失敗時は stderr に理由を出して exit 1。
export async function runApp(buildPrompt) {
  try {
    const input = await readStdin();
    const prompt = buildPrompt(input);
    const output = await runQuery(prompt);
    process.stdout.write(output.endsWith('\n') ? output : output + '\n');
  } catch (err) {
    process.stderr.write(`[newsletter] 生成に失敗しました: ${err?.message ?? err}\n`);
    process.exit(1);
  }
}
