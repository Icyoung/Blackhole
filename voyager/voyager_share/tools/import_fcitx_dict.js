#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");

function usage(exitCode) {
  const script = path.basename(process.argv[1]);
  console.log(`Usage: ${script} --input <dict|txt> [--base <pinyin_dict.json>] [--out <output.json>]

Options:
  --input, -i   Path to libime .dict or exported .txt file (required)
  --base,  -b   Existing pinyin_dict.json (default: ../assets/pinyin_dict.json)
  --out,   -o   Output JSON (default: same as --base)
  --help,  -h   Show help

Notes:
  - If input is .dict, this script will try to run libime_pinyindict -d.
  - If libime_pinyindict is not installed, export the .dict to .txt first.
  - Expected line format: <word> <pinyin> [frequency]
    Example: WORD pin'yin 0
`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--input" || a === "-i") {
      args.input = argv[++i];
    } else if (a === "--base" || a === "-b") {
      args.base = argv[++i];
    } else if (a === "--out" || a === "-o") {
      args.out = argv[++i];
    } else if (a === "--help" || a === "-h") {
      usage(0);
    } else {
      console.error(`Unknown argument: ${a}`);
      usage(1);
    }
  }
  return args;
}

function normalizePinyin(raw) {
  return raw
    .toLowerCase()
    .replace(/ü/g, "v")
    .replace(/[^a-z]/g, "");
}

function readSyllables(syllablePath, fallbackKeys) {
  try {
    const src = fs.readFileSync(syllablePath, "utf8");
    const matches = src.match(/'([^']+)'/g);
    if (!matches) return new Set(fallbackKeys);
    const set = new Set();
    for (const m of matches) {
      set.add(m.slice(1, -1));
    }
    return set;
  } catch (_) {
    return new Set(fallbackKeys);
  }
}

function loadTextFromDict(dictPath) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pinyin-dict-"));
  const tmpTxt = path.join(tmpDir, "export.txt");
  const res = spawnSync("libime_pinyindict", ["-d", dictPath, tmpTxt], {
    stdio: "inherit",
  });
  if (res.status !== 0) {
    console.error("Failed to export .dict. Install libime (fcitx5) or export to .txt first.");
    process.exit(2);
  }
  return tmpTxt;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.input) {
    console.error("Missing --input");
    usage(1);
  }

  const toolDir = path.dirname(__filename);
  const defaultBase = path.resolve(toolDir, "../assets/pinyin_dict.json");
  const basePath = path.resolve(args.base || defaultBase);
  const outPath = path.resolve(args.out || basePath);

  if (!fs.existsSync(basePath)) {
    console.error(`Base JSON not found: ${basePath}`);
    process.exit(1);
  }

  let inputPath = path.resolve(args.input);
  if (!fs.existsSync(inputPath)) {
    console.error(`Input not found: ${inputPath}`);
    process.exit(1);
  }

  if (inputPath.endsWith(".dict")) {
    inputPath = loadTextFromDict(inputPath);
  }

  const base = JSON.parse(fs.readFileSync(basePath, "utf8"));
  if (!base._phrases) base._phrases = {};

  const syllablePath = path.resolve(toolDir, "../lib/src/widgets/keyboard/pinyin_valid_syllables.dart");
  const syllableSet = readSyllables(syllablePath, Object.keys(base).filter((k) => k !== "_phrases"));

  const phraseIndex = new Map();
  const charIndex = new Map();

  function ensureSet(map, key, initialList) {
    let set = map.get(key);
    if (!set) {
      set = new Set(initialList || []);
      map.set(key, set);
    }
    return set;
  }

  let addedPhrases = 0;
  let addedChars = 0;
  let duplicates = 0;
  let skipped = 0;

  const lines = fs.readFileSync(inputPath, "utf8").split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;
    if (line.startsWith("#") || line.startsWith(";") || line.startsWith("//")) continue;
    if (line.startsWith("[") && line.endsWith("]")) continue;

    const parts = line.split(/\s+/);
    if (parts.length < 2) {
      skipped += 1;
      continue;
    }

    const word = parts[0];
    const pinyinRaw = parts[1];
    const key = normalizePinyin(pinyinRaw);
    if (!key) {
      skipped += 1;
      continue;
    }

    if (word.length === 1 && syllableSet.has(key)) {
      const list = base[key] || [];
      const set = ensureSet(charIndex, key, list);
      if (set.has(word)) {
        duplicates += 1;
      } else {
        set.add(word);
        addedChars += 1;
      }
    } else {
      const list = base._phrases[key] || [];
      const set = ensureSet(phraseIndex, key, list);
      if (set.has(word)) {
        duplicates += 1;
      } else {
        set.add(word);
        addedPhrases += 1;
      }
    }
  }

  for (const [key, set] of charIndex.entries()) {
    base[key] = Array.from(set);
  }
  for (const [key, set] of phraseIndex.entries()) {
    base._phrases[key] = Array.from(set);
  }

  fs.writeFileSync(outPath, JSON.stringify(base, null, 2) + "\n", "utf8");

  console.log(`Done. Added phrases: ${addedPhrases}, added chars: ${addedChars}, duplicates: ${duplicates}, skipped: ${skipped}`);
  console.log(`Wrote: ${outPath}`);
}

main();
