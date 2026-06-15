// remediate-findings — plan, implement, review, validate, integrate & document
// fixes for the docs/findings audit of this devcontainer repo.
//
// SAVE-ONLY ARTIFACT. This script is not meant to be run as part of authoring it.
// To run later, from the repo root: Workflow({ name: 'remediate-findings' }).
// Optional scope override: Workflow({ name: 'remediate-findings',
//   args: { severities: ['critical','high'] } }).
//
// WARNING: running this performs OUTWARD-FACING, hard-to-reverse actions — it
// pushes branches and MERGES pull requests into the public `main`. The merge is
// gated on per-batch validation + review; out-of-scope severities are skipped.
//
// What it does, in order:
//   1. Plan      — load in-scope findings from findings.jsonl; cluster them into
//                  themed, file-disjoint fix-batches.
//   2..5 (per batch, STRICTLY SEQUENTIAL — shared .git + single main lineage):
//      Implement — git worktree under .claude/worktrees/<slug> off origin/main;
//                  apply the cluster's fixes.
//      Review    — diff the fixes; flag regressions; return NEW refactoring findings.
//      Validate  — run static gates on changed files (shellcheck/bash -n/hadolint/
//                  compose config/yamllint) if present. No build, no boot.
//      Integrate — commit + push + open PR; MERGE only if validation + review pass,
//                  else leave the PR open; then clean up the worktree.
//   6. Document  — write ONE docs/findings/REMEDIATION.md summarizing updates +
//                  the surfaced refactoring findings; commit ONLY that file.
//
// The script itself has no filesystem/git access — every git/gh/file operation
// runs inside a spawned agent.

export const meta = {
  name: 'remediate-findings',
  description:
    'Plan, fix, review, validate, integrate (worktree PRs) and document the docs/findings audit',
  phases: [
    { title: 'Plan' },
    { title: 'Implement' },
    { title: 'Review' },
    { title: 'Validate' },
    { title: 'Integrate' },
    { title: 'Document' },
  ],
};

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const SEVERITY_ENUM = ['critical', 'high', 'medium', 'low', 'nit'];
const KIND_ENUM = [
  'bug',
  'security',
  'portability',
  'perf',
  'maintainability',
  'docs',
  'test-gap',
];

// Reused for the review-surfaced refactoring findings (matches the audit schema).
const FINDING_ITEM = {
  type: 'object',
  additionalProperties: false,
  required: [
    'area',
    'title',
    'severity',
    'kind',
    'file',
    'line',
    'evidence',
    'explanation',
    'recommendation',
  ],
  properties: {
    area: { type: 'string', description: 'Subsystem or lens this belongs to.' },
    title: { type: 'string', description: 'Concise, specific issue title.' },
    severity: { type: 'string', enum: SEVERITY_ENUM },
    kind: { type: 'string', enum: KIND_ENUM },
    file: { type: 'string', description: 'Repo-relative path.' },
    line: { type: 'integer', description: 'Line number, or 0 if file-wide.' },
    evidence: { type: 'string', description: 'Exact snippet or fact supporting the claim.' },
    explanation: { type: 'string', description: 'Why it is a problem / what breaks.' },
    recommendation: { type: 'string', description: 'Concrete fix.' },
  },
};

// Compact projection of a loaded finding (drops verbose evidence/explanation).
const COMPACT_ITEM = {
  type: 'object',
  additionalProperties: false,
  required: ['seq', 'severity', 'kind', 'area', 'file', 'line', 'title', 'recommendation'],
  properties: {
    seq: { type: 'integer' },
    severity: { type: 'string', enum: SEVERITY_ENUM },
    kind: { type: 'string' },
    area: { type: 'string' },
    file: { type: 'string' },
    line: { type: 'integer' },
    title: { type: 'string' },
    recommendation: { type: 'string' },
  },
};

const LOADED_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: { type: 'array', items: COMPACT_ITEM },
  },
};

const CLUSTERS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clusters'],
  properties: {
    clusters: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['key', 'title', 'rationale', 'findingSeqs', 'files', 'approach'],
        properties: {
          key: { type: 'string', description: 'Short kebab-case batch key.' },
          title: { type: 'string', description: 'Human-readable batch title.' },
          rationale: { type: 'string', description: 'Why these findings group together.' },
          findingSeqs: { type: 'array', items: { type: 'integer' } },
          files: { type: 'array', items: { type: 'string' } },
          approach: { type: 'string', description: 'How to fix the batch.' },
        },
      },
    },
  },
};

const FIXRESULT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['filesChanged', 'summary', 'perFinding'],
  properties: {
    filesChanged: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    perFinding: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['seq', 'status', 'note'],
        properties: {
          seq: { type: 'integer' },
          status: { type: 'string', enum: ['fixed', 'partial', 'skipped'] },
          note: { type: 'string' },
        },
      },
    },
  },
};

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['ok', 'blocking', 'newFindings'],
  properties: {
    ok: { type: 'boolean', description: 'True if fixes are correct with no blocking regressions.' },
    blocking: { type: 'array', items: { type: 'string' } },
    newFindings: { type: 'array', items: FINDING_ITEM },
  },
};

const VALIDATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['passed', 'gates', 'blocking'],
  properties: {
    passed: { type: 'boolean' },
    gates: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['tool', 'ran', 'ok', 'output'],
        properties: {
          tool: { type: 'string' },
          ran: { type: 'boolean' },
          ok: { type: 'boolean' },
          output: { type: 'string' },
        },
      },
    },
    blocking: { type: 'array', items: { type: 'string' } },
  },
};

const INTEGRATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['merged'],
  properties: {
    merged: { type: 'boolean' },
    prUrl: { type: 'string' },
    branch: { type: 'string' },
    mergedSha: { type: 'string' },
    reason: { type: 'string' },
  },
};

const DOCRESULT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['path'],
  properties: {
    path: { type: 'string' },
    prUrl: { type: 'string' },
    merged: { type: 'boolean' },
    note: { type: 'string' },
  },
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const REPO = '/Users/chris/Projects/devcontainer';
const FINDINGS_REL = 'docs/findings/findings.jsonl';
const WORKTREE_REL = '.claude/worktrees';
const BASE_BRANCH = 'main';
const SUMMARY_DOC_REL = 'docs/findings/REMEDIATION.md';
const DEFAULT_SCOPE = ['critical', 'high', 'medium'];

const COAUTHOR_TRAILER =
  'Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>';
const PR_FOOTER = 'Generated with Claude Code (https://claude.com/claude-code)';

const SEV_RANK = { critical: 5, high: 4, medium: 3, low: 2, nit: 1 };

// Scope is overridable via args.severities; guard against malformed input.
const SCOPE =
  args && args.severities && Array.isArray(args.severities) && args.severities.length
    ? args.severities.filter((s) => SEV_RANK[s])
    : DEFAULT_SCOPE;

const PREAMBLE = [
  'You are remediating a prior security/quality audit of a sandboxed devcontainer',
  'repo at ' + REPO + '. It is container definition + config (shell / Dockerfile /',
  'compose / JSONC), NOT an app. The audit lives in ' + REPO + '/docs/findings/.',
  'The project CLAUDE.md at ' + REPO + '/CLAUDE.md documents load-bearing invariants',
  'you MUST preserve — read it before changing any firewall/cron/build script.',
].join('\n');

// ---------------------------------------------------------------------------
// Helpers (plain code — no agents)
// ---------------------------------------------------------------------------

function slug(s) {
  const out = String(s || 'batch')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return out || 'batch';
}

function shorten(s) {
  const t = String(s || '').replace(/\s+/g, ' ').trim();
  return t.length > 48 ? t.slice(0, 45) + '...' : t;
}

function clusterSeverityRank(cluster) {
  let max = 0;
  for (const f of cluster.findings || []) {
    const r = SEV_RANK[f.severity] || 0;
    if (r > max) {
      max = r;
    }
  }
  return max;
}

function absWorktree(s) {
  return REPO + '/' + WORKTREE_REL + '/' + s;
}

// ---------------------------------------------------------------------------
// Prompt builders (string concatenation; no backticks / no ${} in prose)
// ---------------------------------------------------------------------------

function loadPrompt() {
  return (
    PREAMBLE +
    '\n\nTASK: Read the file ' +
    REPO +
    '/' +
    FINDINGS_REL +
    ' (JSON Lines — one JSON object per line). Parse every line. Keep ONLY records' +
    ' whose "severity" is one of: ' +
    SCOPE.join(', ') +
    '. For each kept record return a COMPACT projection with exactly these fields:' +
    ' seq, severity, kind, area, file, line, title, recommendation (drop evidence,' +
    ' explanation, source, votes, realVotes, ts). Do not invent or merge records.' +
    ' Return via the schema. If the file is missing or has zero in-scope records,' +
    ' return an empty findings array.'
  );
}

function clusterPrompt(findings) {
  const json = JSON.stringify(findings, null, 2);
  return (
    PREAMBLE +
    '\n\nTASK: Group the in-scope findings below into THEMED fix-batches ("clusters")' +
    ' suitable for one pull request each. Optimize for:\n' +
    '- Coherence: each cluster is one theme (e.g. "firewall egress hardening",' +
    ' "supply-chain pinning", "db lifecycle + cron env").\n' +
    '- File-disjointness: minimize the number of clusters that touch the SAME file,' +
    ' because clusters are merged sequentially and overlap causes merge conflicts.' +
    ' If two findings touch the same file, prefer putting them in the SAME cluster.\n' +
    '- Size: aim for roughly 6 to 10 clusters total; every in-scope finding must' +
    ' belong to exactly one cluster (no duplicates, no omissions).\n\n' +
    'For each cluster return: key (short kebab-case), title, rationale, findingSeqs' +
    ' (the seq numbers it covers), files (repo-relative paths it will touch), and' +
    ' approach (how to implement the fixes safely without breaking CLAUDE.md' +
    ' invariants). Return via the schema.\n\nIN-SCOPE FINDINGS:\n' +
    json
  );
}

function implementPrompt(cluster) {
  const wt = absWorktree(cluster.slug);
  const json = JSON.stringify(cluster.findings, null, 2);
  return (
    PREAMBLE +
    '\n\nTASK: Implement the fixes for the "' +
    cluster.title +
    '" batch in a DEDICATED git worktree. Do NOT commit — a later step commits.\n\n' +
    'STEP 1 — create the worktree (run these from ' +
    REPO +
    '):\n' +
    '  git -C ' +
    REPO +
    ' fetch origin\n' +
    '  # remove any stale worktree/dir from a previous run (ignore errors):\n' +
    '  git -C ' +
    REPO +
    ' worktree remove --force ' +
    wt +
    ' 2>/dev/null || true\n' +
    '  git -C ' +
    REPO +
    ' worktree prune\n' +
    '  rm -rf ' +
    wt +
    '\n' +
    '  git -C ' +
    REPO +
    ' worktree add -B ' +
    cluster.branch +
    ' ' +
    wt +
    ' origin/' +
    BASE_BRANCH +
    '\n\n' +
    'STEP 2 — apply the fixes INSIDE the worktree at ' +
    wt +
    ' (edit files there, using absolute paths under that directory). Read each' +
    ' target file first; the line numbers in the findings are from the audit and' +
    ' may have shifted, so locate the real code. Apply each finding\'s' +
    ' recommendation faithfully and MINIMALLY; do not make unrelated changes.' +
    ' Preserve every CLAUDE.md invariant (firewall fail-closed, LF endings,' +
    ' volume-shadowing, sudo env handling, etc.). For shell scripts keep' +
    ' "set -euo pipefail" and non-fatal resolver behavior.\n\n' +
    'STEP 3 — return FIXRESULT: filesChanged (repo-relative paths you edited, as' +
    ' they appear relative to the worktree root), a short summary, and perFinding' +
    ' (one entry per seq below with status fixed | partial | skipped and a note).' +
    ' If you make NO changes at all, return an empty filesChanged array and remove' +
    ' the worktree you created (git -C ' +
    REPO +
    ' worktree remove --force ' +
    wt +
    ' ; git -C ' +
    REPO +
    ' worktree prune).\n\nFINDINGS IN THIS BATCH:\n' +
    json
  );
}

function reviewPrompt(cluster) {
  const wt = absWorktree(cluster.slug);
  const json = JSON.stringify(cluster.findings, null, 2);
  return (
    PREAMBLE +
    '\n\nTASK: Critically REVIEW the uncommitted fixes in the worktree at ' +
    wt +
    ' for the "' +
    cluster.title +
    '" batch. Inspect the diff:\n' +
    '  git -C ' +
    wt +
    ' diff origin/' +
    BASE_BRANCH +
    '\n\nAssess: (a) does each fix correctly address its finding, (b) does it' +
    ' introduce a regression or break a CLAUDE.md invariant, (c) is it incomplete.' +
    ' Set ok=false and list specifics in blocking[] if there is ANY regression,' +
    ' invariant break, or syntactically broken change — this gates the merge.\n\n' +
    'Also RETURN NEW FINDINGS for future refactoring: issues the fix revealed or' +
    ' introduced that are out of scope for this batch (newFindings[], using the' +
    ' finding schema — area/title/severity/kind/file/line/evidence/explanation/' +
    ' recommendation). These are NOT fixed now; they are recorded for a later pass.' +
    ' Return via the schema.\n\nFINDINGS THIS BATCH CLAIMED TO FIX:\n' +
    json
  );
}

function validatePrompt(cluster, fix) {
  const wt = absWorktree(cluster.slug);
  const files = JSON.stringify((fix && fix.filesChanged) || []);
  return (
    PREAMBLE +
    '\n\nTASK: VALIDATE the uncommitted changes in the worktree at ' +
    wt +
    ' with cheap static gates. Do NOT build the image or boot a container.\n\n' +
    'Changed files: ' +
    files +
    '\n\nFor the changed files, run whichever of these tools are installed' +
    ' (check with "command -v <tool>"; a MISSING tool is NOT a failure — record' +
    ' ran=false):\n' +
    '  - shell scripts: "bash -n <file>" AND "shellcheck <file>"\n' +
    '  - .devcontainer/Dockerfile (if changed): "hadolint <file>"\n' +
    '  - compose.yaml (if changed): "docker compose -f ' +
    wt +
    '/.devcontainer/compose.yaml config -q"\n' +
    '  - any .yml/.yaml (if changed): "yamllint <file>"\n\n' +
    'Run each tool against the file INSIDE the worktree (' +
    wt +
    '). Record per-gate tool/ran/ok/output (trim long output). Set passed=false' +
    ' and populate blocking[] if any gate that RAN reported an error. Return via' +
    ' the schema.'
  );
}

function integratePrompt(cluster, fix, gateOk) {
  const wt = absWorktree(cluster.slug);
  const seqs = (cluster.findingSeqs || []).join(', ');
  const files = ((fix && fix.filesChanged) || []).join(' ');
  const subject = 'fix: ' + cluster.title;
  const mergeLine = gateOk
    ? 'The gate PASSED — after creating the PR, MERGE it:\n' +
      '  gh pr merge <pr-url> --squash --delete-branch\n'
    : 'The gate FAILED (validation or review did not pass) — DO NOT merge. Leave' +
      ' the PR open for a human and set merged=false with a reason.\n';
  return (
    PREAMBLE +
    '\n\nTASK: Integrate the "' +
    cluster.title +
    '" batch from the worktree at ' +
    wt +
    '. Run git/gh commands; capture outputs; never crash — on any failure, return' +
    ' merged=false with a clear reason and still attempt cleanup.\n\n' +
    'STEP 1 — commit ONLY the changed files (explicit paths; never "git add -A"):\n' +
    '  git -C ' +
    wt +
    ' add -- ' +
    files +
    '\n  git -C ' +
    wt +
    ' commit -m "' +
    subject +
    '" -m "Addresses audit findings: ' +
    seqs +
    '." -m "' +
    COAUTHOR_TRAILER +
    '"\n\n' +
    'STEP 2 — push and open a PR:\n' +
    '  git -C ' +
    wt +
    ' push -u origin ' +
    cluster.branch +
    '\n  gh pr create --repo ChrisSc/claude-devcontainer --base ' +
    BASE_BRANCH +
    ' --head ' +
    cluster.branch +
    ' --title "' +
    subject +
    '" --body "<summary of the fixes; list addressed findings ' +
    seqs +
    '; end with the line: ' +
    PR_FOOTER +
    '>"\n  # capture the printed PR url.\n\n' +
    'STEP 3 — ' +
    mergeLine +
    '\n' +
    'STEP 4 — ALWAYS clean up (even on failure):\n' +
    '  git -C ' +
    REPO +
    ' worktree remove --force ' +
    wt +
    ' 2>/dev/null || true\n' +
    '  git -C ' +
    REPO +
    ' worktree prune\n' +
    '  git -C ' +
    REPO +
    ' branch -D ' +
    cluster.branch +
    ' 2>/dev/null || true\n' +
    '  git -C ' +
    REPO +
    ' fetch origin\n\n' +
    'Return INTEGRATE: merged (true only if the PR was actually merged), prUrl,' +
    ' branch (' +
    cluster.branch +
    '), mergedSha (the squash commit on ' +
    BASE_BRANCH +
    ' if merged, else empty), and reason. Return via the schema.'
  );
}

function cleanupPrompt(cluster) {
  const wt = absWorktree(cluster.slug);
  return (
    'Best-effort cleanup for an aborted batch. Working dir ' +
    REPO +
    '. Run (ignore all errors):\n' +
    '  git -C ' +
    REPO +
    ' worktree remove --force ' +
    wt +
    ' 2>/dev/null || true\n' +
    '  git -C ' +
    REPO +
    ' worktree prune\n' +
    '  rm -rf ' +
    wt +
    '\n  git -C ' +
    REPO +
    ' branch -D ' +
    cluster.branch +
    ' 2>/dev/null || true\n\nReturn a one-line confirmation.'
  );
}

function documentPrompt(resultsForDoc, newFindings) {
  const results = JSON.stringify(resultsForDoc, null, 2);
  const refac = JSON.stringify(newFindings, null, 2);
  const wt = absWorktree('remediation-summary');
  const docInWt = wt + '/' + SUMMARY_DOC_REL;
  return (
    PREAMBLE +
    '\n\nTASK: Write ONE remediation summary document and commit ONLY that file on' +
    ' its own branch off origin/' +
    BASE_BRANCH +
    ', then merge it.\n\n' +
    'STEP 1 — create a dedicated worktree off freshly-fetched origin/' +
    BASE_BRANCH +
    ' (the file MUST be written INSIDE this worktree so the committed path exists on' +
    ' the branch — do NOT write it into the main checkout):\n' +
    '  git -C ' +
    REPO +
    ' fetch origin\n' +
    '  git -C ' +
    REPO +
    ' worktree remove --force ' +
    wt +
    ' 2>/dev/null || true\n' +
    '  git -C ' +
    REPO +
    ' worktree prune\n' +
    '  rm -rf ' +
    wt +
    '\n' +
    '  git -C ' +
    REPO +
    ' worktree add -B docs/remediation-summary ' +
    wt +
    ' origin/' +
    BASE_BRANCH +
    '\n\n' +
    'STEP 2 — write the summary file at ' +
    docInWt +
    ' (run "mkdir -p ' +
    wt +
    '/docs/findings" first). Structure:\n' +
    '  # Devcontainer remediation — updates made\n' +
    '  - An intro paragraph: what was remediated, the scope (' +
    SCOPE.join(', ') +
    '), and that batches were merged only when validation + review passed.\n' +
    '  - A "Batches" table: batch title | branch | PR | status (merged / open) |' +
    ' addressed finding seqs | validation | review.\n' +
    '  - A per-batch section detailing the per-finding status (fixed / partial /' +
    ' skipped) and notes.\n' +
    '  - A "New findings surfaced for future refactoring" section listing the' +
    ' refactoring findings (these were NOT fixed in this run).\n' +
    '  - Compute a single ISO-8601 UTC timestamp via "date -u +%Y-%m-%dT%H:%M:%SZ"' +
    ' and record it as the run time.\n' +
    'Write faithfully from the JSON below; do not invent results.\n\n' +
    'STEP 3 — commit ONLY this one file (explicit path; never "git add -A"), then' +
    ' push and merge. The raw audit (the other files in docs/findings/) is' +
    ' intentionally LEFT UNTRACKED — do not add it.\n' +
    '  git -C ' +
    wt +
    ' add -- ' +
    SUMMARY_DOC_REL +
    '\n  git -C ' +
    wt +
    ' commit -m "docs: add devcontainer remediation summary" -m "' +
    COAUTHOR_TRAILER +
    '"\n  git -C ' +
    wt +
    ' push -u origin docs/remediation-summary\n' +
    '  gh pr create --repo ChrisSc/claude-devcontainer --base ' +
    BASE_BRANCH +
    ' --head docs/remediation-summary --title "docs: devcontainer remediation' +
    ' summary" --body "Summary of audit remediation. ' +
    PR_FOOTER +
    '"\n  gh pr merge <pr-url> --squash --delete-branch\n\n' +
    'STEP 4 — ALWAYS clean up (even on failure):\n' +
    '  git -C ' +
    REPO +
    ' worktree remove --force ' +
    wt +
    ' 2>/dev/null || true\n' +
    '  git -C ' +
    REPO +
    ' worktree prune\n' +
    '  git -C ' +
    REPO +
    ' branch -D docs/remediation-summary 2>/dev/null || true\n' +
    '  git -C ' +
    REPO +
    ' fetch origin\n\n' +
    'Run git/gh commands; capture outputs; never crash — on any failure, still' +
    ' return the path you wrote and merged=false with the reason. The committed path' +
    ' on the branch is ' +
    SUMMARY_DOC_REL +
    '. Return the path, prUrl, merged, and a note.\n\n' +
    'RESULTS JSON:\n' +
    results +
    '\n\nREFACTORING FINDINGS JSON:\n' +
    refac
  );
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

log('Starting findings remediation. Scope: ' + SCOPE.join(', ') + '.');

// 1. Plan --------------------------------------------------------------------
phase('Plan');
const loaded = await agent(loadPrompt(), {
  label: 'load-findings',
  phase: 'Plan',
  schema: LOADED_SCHEMA,
  agentType: 'general-purpose',
});
const inScope = ((loaded && loaded.findings) || []).filter((f) => SCOPE.indexOf(f.severity) !== -1);
if (!inScope.length) {
  log('No in-scope findings found at ' + FINDINGS_REL + '; nothing to remediate.');
  return { clusters: 0, merged: 0, openPrs: [], findingsAddressed: 0, newRefactorFindings: 0 };
}
log('Loaded ' + inScope.length + ' in-scope findings.');

const bySeq = new Map();
for (const f of inScope) {
  bySeq.set(f.seq, f);
}

const clusterResp = await agent(clusterPrompt(inScope), {
  label: 'cluster',
  phase: 'Plan',
  schema: CLUSTERS_SCHEMA,
});
let clusters = (clusterResp && clusterResp.clusters) || [];
if (!clusters.length) {
  log('Clusterer returned no clusters; treating every finding as its own batch.');
  clusters = inScope.map((f) => ({
    key: 'seq-' + f.seq,
    title: f.title,
    rationale: 'single finding',
    findingSeqs: [f.seq],
    files: [f.file],
    approach: f.recommendation,
  }));
}

// Resolve seqs -> loaded findings; assign deterministic unique slugs/branches.
const usedSlugs = new Set();
clusters.forEach((c, i) => {
  c.findings = (c.findingSeqs || []).map((s) => bySeq.get(s)).filter(Boolean);
  let s = slug(c.key || c.title || 'batch-' + (i + 1));
  if (usedSlugs.has(s)) {
    s = s + '-' + (i + 1);
  }
  usedSlugs.add(s);
  c.slug = s;
  c.branch = 'fix/' + s;
});

// Coverage check — log any in-scope seq not covered by a cluster (no silent drop).
const covered = new Set();
for (const c of clusters) {
  for (const s of c.findingSeqs || []) {
    covered.add(s);
  }
}
const uncovered = inScope.map((f) => f.seq).filter((s) => !covered.has(s));
if (uncovered.length) {
  log('WARNING: ' + uncovered.length + ' in-scope finding(s) not covered by any cluster: ' + uncovered.join(', '));
}

// Most-severe batches first, so the important fixes land first under sequential merge.
clusters.sort((a, b) => clusterSeverityRank(b) - clusterSeverityRank(a));
log('Planned ' + clusters.length + ' fix-batches.');

// 2..5. Per-batch lifecycle (STRICTLY SEQUENTIAL) ----------------------------
const results = [];
const newRefactorFindings = [];
for (const cluster of clusters) {
  if (!cluster.findings.length) {
    log('Batch ' + cluster.slug + ': no resolvable findings; skipping.');
    results.push({ cluster, status: 'skipped', reason: 'no resolvable findings' });
    continue;
  }

  phase('Implement');
  const fix = await agent(implementPrompt(cluster), {
    label: 'implement:' + cluster.slug,
    phase: 'Implement',
    schema: FIXRESULT_SCHEMA,
    agentType: 'general-purpose',
  });
  if (!fix || !fix.filesChanged || !fix.filesChanged.length) {
    log('Batch ' + cluster.slug + ': implementer made no changes; skipping (no PR).');
    await agent(cleanupPrompt(cluster), {
      label: 'cleanup:' + cluster.slug,
      phase: 'Implement',
      agentType: 'general-purpose',
    });
    results.push({ cluster, status: 'skipped', reason: 'no changes', fix });
    continue;
  }

  phase('Review');
  const review = await agent(reviewPrompt(cluster), {
    label: 'review:' + cluster.slug,
    phase: 'Review',
    schema: REVIEW_SCHEMA,
    agentType: 'general-purpose',
  });
  if (review && review.newFindings && review.newFindings.length) {
    newRefactorFindings.push(...review.newFindings);
  }

  phase('Validate');
  const validation = await agent(validatePrompt(cluster, fix), {
    label: 'validate:' + cluster.slug,
    phase: 'Validate',
    schema: VALIDATE_SCHEMA,
    agentType: 'general-purpose',
  });

  phase('Integrate');
  const gateOk = Boolean(validation && validation.passed) && Boolean(review && review.ok);
  if (!gateOk) {
    log(
      'Batch ' +
        cluster.slug +
        ': gate FAILED (validation.passed=' +
        Boolean(validation && validation.passed) +
        ', review.ok=' +
        Boolean(review && review.ok) +
        ') — opening PR without merging.'
    );
  }
  const integ = await agent(integratePrompt(cluster, fix, gateOk), {
    label: 'integrate:' + cluster.slug,
    phase: 'Integrate',
    schema: INTEGRATE_SCHEMA,
    agentType: 'general-purpose',
  });

  const merged = Boolean(integ && integ.merged);
  results.push({
    cluster,
    status: merged ? 'merged' : 'open',
    fix,
    review,
    validation,
    integ,
    gateOk,
  });
  log('Batch ' + cluster.slug + ': ' + (merged ? 'MERGED' : 'PR open') + (integ && integ.prUrl ? ' (' + integ.prUrl + ')' : '') + '.');
}

// 6. Document ----------------------------------------------------------------
phase('Document');
const resultsForDoc = results.map((r) => ({
  slug: r.cluster.slug,
  title: r.cluster.title,
  branch: r.cluster.branch,
  status: r.status,
  reason: r.reason || (r.integ && r.integ.reason) || '',
  prUrl: (r.integ && r.integ.prUrl) || '',
  merged: Boolean(r.integ && r.integ.merged),
  addressedSeqs: r.cluster.findingSeqs || [],
  perFinding: (r.fix && r.fix.perFinding) || [],
  validationPassed: Boolean(r.validation && r.validation.passed),
  reviewOk: Boolean(r.review && r.review.ok),
}));

const docResult = await agent(documentPrompt(resultsForDoc, newRefactorFindings), {
  label: 'document',
  phase: 'Document',
  schema: DOCRESULT_SCHEMA,
  agentType: 'general-purpose',
});

const mergedCount = results.filter((r) => r.status === 'merged').length;
const openPrs = results
  .filter((r) => r.status === 'open' && r.integ && r.integ.prUrl)
  .map((r) => r.integ.prUrl);
const findingsAddressed = results
  .filter((r) => r.status === 'merged' || r.status === 'open')
  .reduce((n, r) => n + (r.cluster.findingSeqs ? r.cluster.findingSeqs.length : 0), 0);

log(
  'Remediation complete: ' +
    mergedCount +
    ' merged, ' +
    openPrs.length +
    ' PR(s) left open, ' +
    newRefactorFindings.length +
    ' new refactoring finding(s) recorded.'
);

return {
  scope: SCOPE,
  clusters: clusters.length,
  merged: mergedCount,
  openPrs,
  findingsAddressed,
  newRefactorFindings: newRefactorFindings.length,
  summaryDoc: docResult && docResult.path,
  summaryPrUrl: docResult && docResult.prUrl,
};
