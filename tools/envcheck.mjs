// Port of LBEnv.m's line regex + quoting rules, checked against the real dotenv
// parser that Vite's loadEnv uses. Run: node envcheck.mjs <path-to-.env>
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const dotenv = require('dotenv');

const envSource = readFileSync(new URL('../src/LBEnv.m', import.meta.url), 'utf8');
// Use the regex literal from the shipped Objective-C source, not a second copy.
const encodedRegex = envSource.match(/regularExpressionWithPattern:\s*@("(?:\\.|[^"\\])*")/)[1];
const LINE = new RegExp(JSON.parse(encodedRegex));
const unsupportedMultiline = text => text.split('\n').some(raw => {
  const m = LINE.exec(raw);
  const value = (m?.[2] || '').trim();
  return value && ['"', "'", '`'].includes(value[0]) && (value.length < 2 || value.at(-1) !== value[0]);
});
const decode = raw => {
  let v = raw.trim();
  if (v.length >= 2 && ['"', "'", '`'].includes(v[0]) && v.at(-1) === v[0]) {
    const q = v[0]; v = v.slice(1, -1);
    if (q === '"') v = v.replaceAll('\\n', '\n').replaceAll('\\r', '\r');
  }
  return v;
};
const parse = text => text.split('\n').map(raw => {
  const t = raw.trim();
  if (!t || t.startsWith('#')) return { raw };
  const m = LINE.exec(raw);
  return m ? { raw, key: m[1], value: m[2] === undefined ? '' : decode(m[2]) } : { raw };
});
const quote = v => {
  if (/[\r\n]/.test(v) || v.includes('$') || v.includes('\\n') || v.includes('\\r')) return null;
  if (!v.includes('"')) return `"${v}"`;
  if (!v.includes("'")) return `'${v}'`;
  if (!v.includes('`')) return `\`${v}\``;
  return null;
};
const values = lines => Object.fromEntries(lines.filter(l => l.key).map(l => [l.key, l.value]));

const original = readFileSync(process.argv[2], 'utf8');
const lines = parse(original);
let fail = 0;
const check = (name, ok) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}`); if (!ok) fail++; };
check('round-trip is byte-identical', lines.map(l => l.raw).join('\n') === original);
const ours = values(lines), theirs = dotenv.parse(original);
check(`same keys as dotenv (${Object.keys(theirs).length})`, JSON.stringify(Object.keys(ours).sort()) === JSON.stringify(Object.keys(theirs).sort()));
const diffs = Object.keys(theirs).filter(k => ours[k] !== theirs[k]);
check(`same values as dotenv${diffs.length ? ' — differs: ' + diffs.join(',') : ''}`, diffs.length === 0);

const samples = ['普通文字', 'a # not a comment', `He said "hi"`, `it's "quoted"`, `mix 'a' "b"`, '  leading and trailing  ', '', 'https://x.test/?a=1&b=2', '中文，标点；“全角引号”', 'emoji 🎉✨', 'back\\slash', 'tab\tinside'];
for (const s of samples) {
  const q = quote(s);
  const got = dotenv.parse(`K=${q}\n`).K;
  check(`quote ${JSON.stringify(s)} -> ${q}`, got === s && decode(q) === s);
}
for (const bad of ['a\nb', 'cost $5', 'x\\ny', `a"b'c\`d`]) check(`reject ${JSON.stringify(bad)}`, quote(bad) === null);

// Editing one value must change exactly one line.
const edited = lines.map(l => l.key === 'PUBLIC_SITE_DESCRIPTION' ? { ...l, raw: `PUBLIC_SITE_DESCRIPTION=${quote('新的 # 描述 "测试"')}` } : l);
const text2 = edited.map(l => l.raw).join('\n');
const changed = original.split('\n').filter((l, i) => l !== text2.split('\n')[i]).length;
check('single edit changes one line', changed === 1);
const v2 = dotenv.parse(text2);
check('edited value parsed by dotenv', v2.PUBLIC_SITE_DESCRIPTION === '新的 # 描述 "测试"');
check('other values untouched', Object.keys(theirs).every(k => k === 'PUBLIC_SITE_DESCRIPTION' || v2[k] === theirs[k]));
for (const q of ['"', "'", '`']) check(`reject multiline ${q}`, unsupportedMultiline(`PUBLIC_SITE_DESCRIPTION=${q}first\nSECRET=not a separate field\nlast${q}`));
check('current config is single-line safe', !unsupportedMultiline(original));
check('native editor rejects private fields', envSource.includes('if (![key hasPrefix:@"PUBLIC_"])'));
process.exit(fail ? 1 : 0);
