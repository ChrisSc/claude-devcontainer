// analyze-devcontainer — adversarial, top-to-bottom audit of this devcontainer repo.
//
// SAVE-ONLY ARTIFACT. This script is not meant to be run as part of authoring it.
// To run later, from the repo root: Workflow({ name: 'analyze-devcontainer' }).
//
// What it does, in order:
//   1. Inventory  — map every file into subsystem groups (data-drives later phases).
//   2. Review     — adversarial per-subsystem + per-lens reviewers (multi-modal sweep).
//   3. Verify     — severity-scaled skeptic verifiers refute each finding; keep majority-real.
//   4. Validate   — trace each lifecycle flow end-to-end, check CLAUDE.md invariants
//                   bidirectionally, run cheap static tools (shellcheck/bash -n/hadolint/
//                   docker compose config) if present. No image build, no boot.
//   5. Improve    — improvement lenses; each candidate gets a feasibility check.
//   6. Critic     — completeness critic surfaces what was missed; verified too.
//   7. Consolidate (plain code) — dedupe, sequence, group by area.
//   8. Write      — delegated agents create docs/findings/<NN-area>.md + README.md +
//                   findings.jsonl (the script itself has no filesystem access).

export const meta = {
  name: 'analyze-devcontainer',
  description:
    'Adversarial top-to-bottom audit of the devcontainer; writes findings to docs/findings/',
  phases: [
    { title: 'Inventory' },
    { title: 'Review' },
    { title: 'Verify' },
    { title: 'Validate' },
    { title: 'Improve' },
    { title: 'Critic' },
    { title: 'Write' },
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

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: { type: 'array', items: FINDING_ITEM },
  },
};

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['real', 'confidence', 'reasoning'],
  properties: {
    real: { type: 'boolean', description: 'True only if the claim genuinely holds.' },
    confidence: { type: 'number', description: '0..1.' },
    reasoning: { type: 'string', description: 'Justification with path:line.' },
    severityAdjustment: { type: 'string', enum: SEVERITY_ENUM },
  },
};

const MANIFEST_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['groups'],
  properties: {
    groups: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'role', 'files'],
        properties: {
          name: { type: 'string' },
          role: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
        },
      },
    },
  },
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const REPO = '/Users/chris/Projects/devcontainer';

const PREAMBLE = [
  'You are auditing a security-sandboxed devcontainer repo at ' + REPO + '.',
  'It is container definition + config (shell / Dockerfile / compose / JSONC), NOT an app.',
  'Read files with your tools. Cite every claim as path:line. Be concrete and adversarial.',
  'The project CLAUDE.md at ' + REPO + '/CLAUDE.md documents load-bearing invariants —',
  'treat it as a spec to check the code against.',
].join('\n');

// Fallback subsystem groups if the inventory agent returns nothing usable.
const FALLBACK_GROUPS = [
  {
    name: 'firewall',
    role: 'Default-deny egress firewall',
    files: [
      '.devcontainer/init-firewall.sh',
      '.devcontainer/config/extra-allowlist.txt.example',
    ],
  },
  {
    name: 'build',
    role: 'Image build + CLI toolbelt',
    files: ['.devcontainer/Dockerfile', '.devcontainer/install-tools.sh'],
  },
  {
    name: 'startup',
    role: 'Boot orchestration + ~/.claude seeding',
    files: ['.devcontainer/entrypoint.sh', '.devcontainer/seed-claude.sh'],
  },
  {
    name: 'cron',
    role: 'Scheduled Claude agents',
    files: [
      '.devcontainer/init-cron.sh',
      '.devcontainer/crontab-edit',
      '.devcontainer/crontab-reload',
      '.devcontainer/seed/crontab',
    ],
  },
  {
    name: 'db',
    role: 'Optional Postgres + pgvector sidecar',
    files: [
      '.devcontainer/compose.yaml',
      '.devcontainer/gen-env.sh',
      '.devcontainer/db-init/10-pgvector.sql',
      '.devcontainer/.env.example',
    ],
  },
  {
    name: 'shell',
    role: 'Interactive dotfiles',
    files: [
      '.devcontainer/home/.zshrc',
      '.devcontainer/home/.config/zsh/aliases.zsh',
      '.devcontainer/home/.config/starship.toml',
    ],
  },
  {
    name: 'config',
    role: 'Compose, preflight + devcontainer wiring',
    files: [
      '.devcontainer/compose.yaml',
      '.devcontainer/devcontainer.json',
      '.devcontainer/gen-allowlist.sh',
      '.gitattributes',
      'Makefile',
    ],
  },
  {
    name: 'docs',
    role: 'Human + agent documentation',
    files: [
      'README.md',
      'CHANGELOG.md',
      'SECURITY.md',
      'CLAUDE.md',
      '.devcontainer/seed/CLAUDE.md',
    ],
  },
];

// Cross-cutting lens reviewers (whole-repo, single angle).
const LENSES = [
  {
    key: 'security',
    focus:
      'Egress firewall correctness and bypass paths, secret handling (.env, generated ' +
      'passwords, openssl usage), sudo / sudoers env_reset, Linux capabilities ' +
      '(NET_ADMIN / NET_RAW), file permissions and umask, and supply-chain trust of every ' +
      'build-time download (are versions pinned? checksums or signatures verified? TLS?).',
  },
  {
    key: 'portability',
    focus:
      'arm64 vs amd64 arch gating, LF/CRLF enforcement, the Docker Desktop macOS ' +
      'inode-pin bind-mount, WSL2 vs Hyper-V firewall backend, path / case sensitivity, ' +
      'and BSD-vs-GNU tool assumptions inside the Linux container.',
  },
  {
    key: 'supply-chain',
    focus:
      'Every artifact fetched at build time: cargo-binstall tools, Go release binaries ' +
      '(yq / lazygit), the AWS CLI bundle, Node and Claude installers. Are versions pinned? ' +
      'Is integrity verified? Is any install fetch-latest in a way that breaks reproducible ' +
      'builds or admits a tampered artifact?',
  },
  {
    key: 'idempotency',
    focus:
      'Re-run safety of every script that runs on each boot or can be re-invoked ' +
      '(init-firewall.sh, seed-claude.sh, init-cron.sh, entrypoint.sh, gen-*.sh). Does a ' +
      'second run corrupt state, double-start daemons, clobber user edits, or inherit stale ' +
      'firewall policy / mode?',
  },
  {
    key: 'maintainability',
    focus:
      'Duplication across scripts, magic constants, brittle parsing (sed / grep / awk of ' +
      'structured output), missing error context, and testability — places where a future ' +
      'change is likely to silently break a documented invariant.',
  },
];

// Lifecycle flows for top-to-bottom validation.
const LIFECYCLE_FLOWS = [
  {
    key: 'build',
    focus:
      'Dockerfile + install-tools.sh: multi-stage ordering, layer caching, COPY / chmod / ' +
      '--chown correctness, the volume-shadowing rule (baked files must live OUTSIDE volume ' +
      'paths), the CRLF strip, the node->claude user rename, "uv python install --default" ' +
      'shims, and the pg client major matching the server. Run hadolint + bash -n if present.',
  },
  {
    key: 'boot-order',
    focus:
      'entrypoint.sh sequence (firewall -> seed -> claude update -> cron -> exec command). ' +
      'Is the documented ordering load-bearing and correct? Are non-fatal stages truly ' +
      'non-fatal and the firewall appropriately fatal / retried? Does it exec as PID 1?',
  },
  {
    key: 'firewall',
    focus:
      'init-firewall.sh across strict / permissive / dev. Verify the documented invariants: ' +
      'OUTPUT policy reset-to-ACCEPT then clamp-to-DROP; api.github.com/meta NOT covering ' +
      'github.com / codeload / objects (explicit pins); the @aws-ip-ranges directive; ' +
      'mode-file stickiness; real container subnet (not a guessed /24); non-fatal per-domain ' +
      'resolution; and degrade-not-brick preflight. Run shellcheck + bash -n.',
  },
  {
    key: 'cron',
    focus:
      'init-cron.sh: the persisted ~/.claude/cron/crontab re-installed via "crontab <file>" ' +
      '(a real file, NOT a symlink), cron.env regenerated with %q quoting, BASH_ENV wiring, ' +
      'the pgrep-guarded daemon start, and the crontab-edit / crontab-reload round-trip. ' +
      'Run shellcheck + bash -n.',
  },
  {
    key: 'db',
    focus:
      '.env generation (gen-env.sh) -> compose env_file injection into BOTH services -> ' +
      'first-init keying of the claude-pgdata volume -> the PGDATA subdir -> PGHOST empty on ' +
      'the server -> client/server pg major match -> the db profile gating. Run ' +
      '"docker compose -f .devcontainer/compose.yaml config -q" if docker is present.',
  },
  {
    key: 'cross-platform',
    focus:
      'The cross-platform invariants end to end: .gitattributes LF + the Dockerfile sed ' +
      'CRLF strip, arch gating in install-tools.sh, the inode-pin restart caveat for ' +
      'extra-allowlist.txt, the FIREWALL_MODE explicit sudo assignment (sudoers env_reset), ' +
      'and TZ baked in three places that must agree.',
  },
];

// Improvement lenses (enhancements, not necessarily bugs).
const IMPROVEMENT_LENSES = [
  {
    key: 'test-ci',
    focus:
      'Absence of automated validation: no shellcheck / hadolint / yamllint config, no CI ' +
      '(.github/workflows), no smoke test that builds or boots. Propose concrete, minimal ' +
      'additions that would catch regressions.',
  },
  {
    key: 'maintainability',
    focus:
      'Refactors that reduce risk: shared helper sourcing, constant extraction, replacing ' +
      'brittle parsing, and consolidating duplicated firewall / cron logic.',
  },
  {
    key: 'perf-build',
    focus:
      'Build speed and image size: layer ordering for cache hits, combining RUN layers, ' +
      'apt cache cleanup, reducing re-fetches, and a .dockerignore.',
  },
  {
    key: 'docs-accuracy',
    focus:
      'Drift between README / CHANGELOG / SECURITY / CLAUDE.md / seed/CLAUDE.md and the ' +
      'actual code or behavior. Propose specific, surgical doc fixes.',
  },
  {
    key: 'security-hardening',
    focus:
      'Defense-in-depth: pinning download versions + checksums, dropping unneeded ' +
      'capabilities, tighter sudoers, read-only mounts, and minimizing the allowlist.',
  },
  {
    key: 'observability',
    focus:
      'Per the org observability standard: structured, greppable logging in the boot ' +
      'scripts, a boot-events JSONL trail, and event-completeness checks for the lifecycle — ' +
      'adapted sensibly to shell, not forced where it does not fit.',
  },
];

// Area ordering for stable per-file numbering and sequencing.
const AREA_ORDER = [
  'firewall',
  'build',
  'startup',
  'cron',
  'db',
  'shell',
  'config',
  'docs',
  'security',
  'portability',
  'supply-chain',
  'idempotency',
  'maintainability',
  'boot-order',
  'cross-platform',
  'test-ci',
  'perf-build',
  'docs-accuracy',
  'security-hardening',
  'observability',
];

const SEV_RANK = { critical: 5, high: 4, medium: 3, low: 2, nit: 1 };
const VERIFY_LENSES = ['correctness', 'security-impact', 'reachability'];

// ---------------------------------------------------------------------------
// Helpers (plain code — no agents)
// ---------------------------------------------------------------------------

function severityVotes(sev) {
  if (sev === 'critical' || sev === 'high') {
    return 3;
  }
  if (sev === 'medium') {
    return 2;
  }
  return 1;
}

function shorten(s) {
  const t = String(s || '').replace(/\s+/g, ' ').trim();
  return t.length > 48 ? t.slice(0, 45) + '...' : t;
}

function normalizeTitle(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function slug(s) {
  const out = String(s || 'misc')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return out || 'misc';
}

function findingKey(f) {
  const file = f.file || '?';
  const line = f.line || 0;
  return file + ':' + line + ':' + normalizeTitle(f.title);
}

function dedupe(findings) {
  const byKey = new Map();
  for (const f of findings) {
    const k = findingKey(f);
    const existing = byKey.get(k);
    const rank = SEV_RANK[f.severity] || 0;
    if (!existing || rank > (SEV_RANK[existing.severity] || 0)) {
      byKey.set(k, f);
    }
  }
  return Array.from(byKey.values());
}

function areaRank(area) {
  const idx = AREA_ORDER.indexOf(area);
  return idx === -1 ? AREA_ORDER.length : idx;
}

function countBySeverity(findings) {
  const out = {};
  for (const s of SEVERITY_ENUM) {
    out[s] = 0;
  }
  for (const f of findings) {
    if (out[f.severity] === undefined) {
      out[f.severity] = 0;
    }
    out[f.severity] += 1;
  }
  return out;
}

// Spawn severity-scaled skeptic verifiers for each finding; keep majority-real.
async function verifyFindings(findings, sourceKey) {
  const list = (findings || []).filter(Boolean);
  if (!list.length) {
    return [];
  }
  const judged = await parallel(
    list.map((f) => () => {
      const votes = severityVotes(f.severity);
      return parallel(
        Array.from({ length: votes }, (_unused, i) => () =>
          agent(verifyPrompt(f, VERIFY_LENSES[i % VERIFY_LENSES.length]), {
            label: 'verify:' + f.area + ':' + shorten(f.title),
            phase: 'Verify',
            schema: VERDICT_SCHEMA,
          })
        )
      ).then((rawVotes) => {
        const valid = rawVotes.filter(Boolean);
        if (!valid.length) {
          return null;
        }
        const realCount = valid.filter((v) => v.real).length;
        const needed = Math.ceil(votes / 2);
        if (realCount < needed) {
          return null;
        }
        return Object.assign({}, f, {
          source: sourceKey,
          votes: valid.length,
          realVotes: realCount,
        });
      });
    })
  );
  return judged.filter(Boolean);
}

// ---------------------------------------------------------------------------
// Prompt builders
// ---------------------------------------------------------------------------

function inventoryPrompt() {
  return (
    PREAMBLE +
    '\n\nTASK: Produce a structural inventory (no critique). List every file under ' +
    '.devcontainer/ plus the root docs and config (README.md, CHANGELOG.md, SECURITY.md, ' +
    'CLAUDE.md, Makefile, .gitattributes, .gitignore). Group them into these subsystems: ' +
    'build, firewall, startup, cron, db, shell, config, docs. For each group give a name, ' +
    'a one-line role, and the list of repo-relative file paths. Return via the schema.'
  );
}

function subsystemPrompt(group) {
  const files = group.files.map((f) => '  - ' + f).join('\n');
  return (
    PREAMBLE +
    '\n\nTASK: Adversarially review the "' +
    group.name +
    '" subsystem (' +
    group.role +
    ').\nFiles in scope (read all of them, plus anything they reference):\n' +
    files +
    '\n\nAssume the code is buggy and try to break it. Hunt for:\n' +
    '- correctness bugs, race conditions, non-idempotent re-runs, ordering hazards\n' +
    '- shell pitfalls: missing "set -euo pipefail", unquoted expansions, word-splitting,\n' +
    '  set -e swallowed by pipelines / subshells, exit-code masking, heredoc / quoting bugs\n' +
    '- security holes: firewall bypass, secret leakage, sudo / env_reset, capability misuse,\n' +
    '  world-writable paths, supply-chain (unpinned or unverified downloads)\n' +
    '- volume-shadowing, symlink-vs-file persistence, inode-pin, CRLF/LF, arch gating\n' +
    '- mismatches between this code and what CLAUDE.md claims is true\n\n' +
    'Report ONLY real, evidenced issues (skip pure style nits unless they cause a bug). ' +
    'For each: area="' +
    group.name +
    '", a precise title, severity, kind, file, line, the exact evidence snippet, why it is ' +
    'a problem, and a concrete recommendation. An empty findings array is fine if truly clean.'
  );
}

function lensPrompt(lens) {
  return (
    PREAMBLE +
    '\n\nTASK: Review the ENTIRE repo through a single lens: ' +
    lens.key +
    '.\n' +
    lens.focus +
    '\n\nRead across all of .devcontainer/ and the root config. Find systemic, cross-cutting ' +
    'issues a per-file review would miss. Report only real, evidenced problems. Set area="' +
    lens.key +
    '" and use path:line evidence. Return via the schema.'
  );
}

function verifyPrompt(f, lens) {
  return (
    PREAMBLE +
    '\n\nYou are a SKEPTIC. A reviewer claims the issue below. Your job is to REFUTE it by ' +
    'reading the actual code. Default to real=false unless the evidence clearly holds. ' +
    'Judge through the "' +
    lens +
    '" lens.\n\nCLAIM:\n' +
    '  area: ' +
    f.area +
    '\n  title: ' +
    f.title +
    '\n  severity: ' +
    f.severity +
    '   kind: ' +
    f.kind +
    '\n  location: ' +
    f.file +
    ':' +
    f.line +
    '\n  evidence: ' +
    f.evidence +
    '\n  explanation: ' +
    f.explanation +
    '\n\nOpen ' +
    f.file +
    ' (and related files) and verify. Consider: is the cited line / behavior real? Is it ' +
    'actually reachable at runtime (not dead or guarded)? Does an existing guard, comment, or ' +
    'CLAUDE.md invariant already handle it? Is the severity right?\n\n' +
    'Return real=true only if the issue genuinely exists and matters. If the severity is ' +
    'wrong, set severityAdjustment. Reason with path:line.'
  );
}

function flowPrompt(flow) {
  return (
    PREAMBLE +
    '\n\nTASK: Validate the "' +
    flow.key +
    '" lifecycle flow TOP TO BOTTOM.\n' +
    flow.focus +
    '\n\nDo two things:\n' +
    '1) Trace the flow end-to-end through the actual code and confirm each step wires to the ' +
    'next. Check the relevant CLAUDE.md invariants BIDIRECTIONALLY: does the code honor every ' +
    'documented invariant, AND does every documented invariant still match the code (stale ' +
    'docs are findings too)?\n' +
    '2) Run cheap static validators if available (do NOT build the image or boot a container):\n' +
    '   - "command -v shellcheck" then run shellcheck on the shell files in scope\n' +
    '   - "bash -n <script>" syntax check\n' +
    '   - "command -v hadolint" then "hadolint .devcontainer/Dockerfile" (build flow)\n' +
    '   - "docker compose -f .devcontainer/compose.yaml config -q" if docker is present\n' +
    '   - "command -v yamllint" then yamllint on compose.yaml\n' +
    '   Report real tool output. A missing tool is NOT a finding; tool-reported problems are.\n\n' +
    'Report findings with area="' +
    flow.key +
    '", path:line evidence, severity, kind, and a recommendation. Return via the schema.'
  );
}

function improvePrompt(lens) {
  return (
    PREAMBLE +
    '\n\nTASK: Identify concrete, actionable IMPROVEMENTS for this repo through the "' +
    lens.key +
    '" lens.\n' +
    lens.focus +
    '\n\nThese are enhancements, not necessarily bugs — but each must be genuine and not ' +
    'already present. Verify the current state before proposing (do not suggest a tool that ' +
    'is already installed, or a check that already exists). Set area="' +
    lens.key +
    '", an appropriate kind (test-gap / maintainability / perf / docs / security), a ' +
    'realistic severity (usually low or medium), and a specific recommendation naming the ' +
    'file(s) it touches. Return via the schema.'
  );
}

function feasibilityPrompt(f) {
  return (
    PREAMBLE +
    '\n\nA reviewer proposes the IMPROVEMENT below. Verify it is genuine and NOT already ' +
    'done. Default real=false if it already exists or is infeasible / irrelevant here.\n\n' +
    'PROPOSAL:\n' +
    '  area: ' +
    f.area +
    '   kind: ' +
    f.kind +
    '\n  title: ' +
    f.title +
    '\n  location: ' +
    f.file +
    ':' +
    f.line +
    '\n  recommendation: ' +
    f.recommendation +
    '\n\nCheck the current repo state. Return real=true only if it is a real, actionable ' +
    'improvement that is not already implemented. Reason with path:line.'
  );
}

function criticPrompt(found, manifest) {
  const summary = found
    .slice(0, 200)
    .map(
      (f) =>
        '- [' + f.severity + '] ' + f.area + ': ' + f.title + ' (' + f.file + ':' + f.line + ')'
    )
    .join('\n');
  const groups = (manifest.groups || []).map((g) => g.name).join(', ');
  const shown = found.length > 200 ? ', first 200 shown' : '';
  return (
    PREAMBLE +
    '\n\nTASK: Completeness critic. Below is what the audit has found so far across ' +
    'subsystems [' +
    groups +
    ']. Identify what is MISSING: a file never reviewed, an invariant never verified, a ' +
    'failure mode nobody considered, or an interaction between subsystems not examined. Then ' +
    'surface NEW, evidenced findings only — do not repeat the ones listed.\n\n' +
    'FOUND SO FAR (' +
    found.length +
    ' total' +
    shown +
    '):\n' +
    (summary || '(none)') +
    '\n\nReturn new findings via the schema, with area set to the relevant subsystem and ' +
    'path:line evidence.'
  );
}

function writeAreaPrompt(filename, area, items) {
  const json = JSON.stringify(items, null, 2);
  return (
    'You are writing one audit findings document. Working directory is ' +
    REPO +
    '.\nFirst ensure the output dir exists: run "mkdir -p docs/findings" (idempotent).\n' +
    'Then create the file "docs/findings/' +
    filename +
    '" using the Write tool.\n\n' +
    'The file documents the "' +
    area +
    '" findings below. Use this structure:\n' +
    '  # ' +
    area +
    ' — audit findings\n' +
    '  A one-paragraph summary of the area overall health.\n' +
    '  Then one "##" section per finding, ordered by severity (critical first), each with:\n' +
    '    - Severity / kind\n' +
    '    - Location (path:line, written as a clickable reference)\n' +
    '    - Evidence (quote the snippet)\n' +
    '    - Why it matters\n' +
    '    - Recommendation\n\n' +
    'Write faithfully from this JSON — do not invent findings or drop any. If the array is ' +
    'empty, still write the file with a summary stating the area is clean.\n\n' +
    'FINDINGS JSON:\n' +
    json +
    '\n\nReturn a one-line confirmation of the path you wrote.'
  );
}

function writeIndexPrompt(all, areaFiles) {
  const json = JSON.stringify(all, null, 2);
  const fileList = areaFiles
    .map((a) => '  - docs/findings/' + a.file + ' (' + a.area + ', ' + a.count + ' findings)')
    .join('\n');
  return (
    'You are finalizing an audit. Working directory is ' +
    REPO +
    '. Ensure docs/findings/ exists (run "mkdir -p docs/findings").\n\n' +
    'Produce TWO files.\n\n' +
    '1) "docs/findings/README.md" — the index:\n' +
    '   - Title plus a one-paragraph executive summary of the devcontainer overall health.\n' +
    '   - A severity-count table (Critical / High / Medium / Low / Nit -> counts).\n' +
    '   - A "Top risks" short list (the highest-severity confirmed findings).\n' +
    '   - A table of contents linking to each per-area file:\n' +
    fileList +
    '\n   - A note that findings.jsonl is the machine-readable source of truth.\n\n' +
    '2) "docs/findings/findings.jsonl" — one compact JSON object per line, one per finding, ' +
    'in ascending "seq" order. Each line MUST include every field of the finding object PLUS ' +
    'a "ts" field. Compute ONE ISO-8601 UTC timestamp via "date -u +%Y-%m-%dT%H:%M:%SZ" and ' +
    'use it as "ts" on every line (the audit emit time). Do not reorder. One object per line, ' +
    'no pretty-printing, no trailing commas.\n\n' +
    'FINDINGS JSON (already deduped, sequence-numbered, ascending by seq):\n' +
    json +
    '\n\nUse the Write tool for README.md. For findings.jsonl, build the content (a Bash ' +
    'heredoc or Write is fine) ensuring exactly one compact JSON object per line. Return a ' +
    'one-line confirmation listing both paths and the finding count.'
  );
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

log('Starting adversarial devcontainer audit.');

// 1. Inventory ---------------------------------------------------------------
phase('Inventory');
let manifest = await agent(inventoryPrompt(), {
  label: 'inventory',
  phase: 'Inventory',
  schema: MANIFEST_SCHEMA,
});
if (!manifest || !manifest.groups || !manifest.groups.length) {
  log('Inventory returned no usable groups; falling back to hardcoded subsystem groups.');
  manifest = { groups: FALLBACK_GROUPS };
}
log('Inventory: ' + manifest.groups.length + ' subsystem groups.');

// 2. Review -> 3. Verify (pipeline, no barrier) ------------------------------
phase('Review');
const reviewItems = [];
for (const g of manifest.groups) {
  reviewItems.push({ kind: 'subsystem', key: g.name, group: g });
}
for (const l of LENSES) {
  reviewItems.push({ kind: 'lens', key: l.key, lens: l });
}

const reviewedConfirmed = await pipeline(
  reviewItems,
  (_prev, item) =>
    agent(item.kind === 'subsystem' ? subsystemPrompt(item.group) : lensPrompt(item.lens), {
      label: 'review:' + item.key,
      phase: 'Review',
      schema: FINDINGS_SCHEMA,
    }),
  (res, item) => verifyFindings(res && res.findings, 'review:' + item.key)
);
const reviewFindings = reviewedConfirmed.filter(Boolean).flat();
log('Review + verify: ' + reviewFindings.length + ' confirmed findings.');

// 4. Validate (pipeline, then verify) ----------------------------------------
phase('Validate');
const validatedConfirmed = await pipeline(
  LIFECYCLE_FLOWS,
  (_prev, flow) =>
    agent(flowPrompt(flow), {
      label: 'validate:' + flow.key,
      phase: 'Validate',
      schema: FINDINGS_SCHEMA,
    }),
  (res, flow) => verifyFindings(res && res.findings, 'flow:' + flow.key)
);
const validateFindings = validatedConfirmed.filter(Boolean).flat();
log('Validate + verify: ' + validateFindings.length + ' confirmed findings.');

// 5. Improve (parallel, then feasibility check) ------------------------------
phase('Improve');
const improveRaw = await parallel(
  IMPROVEMENT_LENSES.map((l) => () =>
    agent(improvePrompt(l), {
      label: 'improve:' + l.key,
      phase: 'Improve',
      schema: FINDINGS_SCHEMA,
    })
  )
);
const improveCandidates = improveRaw
  .filter(Boolean)
  .flatMap((r) => (r && r.findings ? r.findings : []));
const improveConfirmed = (
  await parallel(
    improveCandidates.map((f) => () =>
      agent(feasibilityPrompt(f), {
        label: 'feasibility:' + shorten(f.title),
        phase: 'Improve',
        schema: VERDICT_SCHEMA,
      }).then((v) => (v && v.real ? f : null))
    )
  )
).filter(Boolean);
log(
  'Improvements: ' +
    improveConfirmed.length +
    ' confirmed of ' +
    improveCandidates.length +
    ' proposed.'
);

// 6. Critic (one agent, then verify) -----------------------------------------
phase('Critic');
const foundSoFar = [...reviewFindings, ...validateFindings, ...improveConfirmed];
const criticRaw = await agent(criticPrompt(foundSoFar, manifest), {
  label: 'completeness-critic',
  phase: 'Critic',
  schema: FINDINGS_SCHEMA,
});
const criticConfirmed = await verifyFindings(criticRaw && criticRaw.findings, 'critic');
log('Critic: ' + criticConfirmed.length + ' additional confirmed findings.');

// 7. Consolidate (plain code) ------------------------------------------------
const allConfirmed = dedupe([
  ...reviewFindings,
  ...validateFindings,
  ...improveConfirmed,
  ...criticConfirmed,
]);
allConfirmed.sort((a, b) => {
  const ar = areaRank(a.area) - areaRank(b.area);
  if (ar !== 0) {
    return ar;
  }
  const sr = (SEV_RANK[b.severity] || 0) - (SEV_RANK[a.severity] || 0);
  if (sr !== 0) {
    return sr;
  }
  return normalizeTitle(a.title).localeCompare(normalizeTitle(b.title));
});
allConfirmed.forEach((f, i) => {
  f.seq = i + 1;
});

const areaEntries = [];
const areaMap = new Map();
for (const f of allConfirmed) {
  let entry = areaMap.get(f.area);
  if (!entry) {
    entry = { area: f.area, items: [] };
    areaMap.set(f.area, entry);
    areaEntries.push(entry);
  }
  entry.items.push(f);
}
areaEntries.forEach((entry, i) => {
  const num = String(i + 1).padStart(2, '0');
  entry.num = num;
  entry.file = num + '-' + slug(entry.area) + '.md';
});

log(
  'Consolidated ' +
    allConfirmed.length +
    ' findings across ' +
    areaEntries.length +
    ' areas.'
);

// 8. Write (delegated — script has no filesystem access) ---------------------
phase('Write');
let areaFiles;
if (areaEntries.length) {
  await parallel(
    areaEntries.map((entry) => () =>
      agent(writeAreaPrompt(entry.file, entry.area, entry.items), {
        label: 'write:' + entry.area,
        phase: 'Write',
        agentType: 'general-purpose',
      })
    )
  );
  areaFiles = areaEntries.map((e) => ({ area: e.area, file: e.file, count: e.items.length }));
} else {
  // No findings — still emit a single all-clear area file for the index to link.
  await agent(writeAreaPrompt('01-summary.md', 'summary', []), {
    label: 'write:summary',
    phase: 'Write',
    agentType: 'general-purpose',
  });
  areaFiles = [{ area: 'summary', file: '01-summary.md', count: 0 }];
}

const indexResult = await agent(writeIndexPrompt(allConfirmed, areaFiles), {
  label: 'write:index+jsonl',
  phase: 'Write',
  agentType: 'general-purpose',
});

const bySeverity = countBySeverity(allConfirmed);
log(
  'Audit complete: ' +
    allConfirmed.length +
    ' findings written to docs/findings/ (' +
    SEVERITY_ENUM.map((s) => s + '=' + bySeverity[s]).join(', ') +
    ').'
);

return {
  totalFindings: allConfirmed.length,
  bySeverity,
  areas: areaFiles,
  files: ['docs/findings/README.md', 'docs/findings/findings.jsonl'].concat(
    areaFiles.map((a) => 'docs/findings/' + a.file)
  ),
  indexResult,
};
