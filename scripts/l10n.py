#!/usr/bin/env python3
"""画面の文字の翻訳を管理する。

ソースには日本語をそのまま書き、L("…") / L(\"\"\"…\"\"\") で包む。訳は l10n/en.json・l10n/zh.json（日本語 → 訳）に置き、
このスクリプトで Swift の表（Sources/JellyfishAI/Localization/Strings+en.swift・+zh.swift）を作る。

  scripts/l10n.py keys [file.swift ...]   ソースの L("…") のキー（実行時の文字列そのもの）を JSON で出す
  scripts/l10n.py missing en|zh           訳が無いキーを JSON で出す（{キー: ""}。訳を埋めて merge に渡せる）
  scripts/l10n.py merge en|zh part.json   part.json の訳を l10n/<lang>.json に足す
  scripts/l10n.py gen                     l10n/*.json から Swift の表を作る（使われていないキーは捨てる）
  scripts/l10n.py check                   訳の抜け・%@ などの数の違い・L() の中の \\( \\) を調べる（CI で使う）
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources", "JellyfishAI")
L10N = os.path.join(ROOT, "l10n")
LANGS = ["en", "zh"]
CALL = re.compile(r'(?<![A-Za-z0-9_.])L\(\s*"')
SPEC = re.compile(r'%(?:\d+\$)?(?:l?d|@|ld|lld|f|\.\d+f)')


def decode_escapes(s, where):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "n": out.append("\n"); i += 2; continue
            if n == "t": out.append("\t"); i += 2; continue
            if n == "r": out.append("\r"); i += 2; continue
            if n == "0": out.append("\0"); i += 2; continue
            if n in "\"'\\": out.append(n); i += 2; continue
            if n == "u":
                m = re.match(r"\\u\{([0-9a-fA-F]+)\}", s[i:])
                if m: out.append(chr(int(m.group(1), 16))); i += len(m.group(0)); continue
            if n == "(":
                raise ValueError(f"{where}: L() の中で \\( \\) は使えません（%@ と引数にする）")
        out.append(c)
        i += 1
    return "".join(out)


def keys_in(path):
    text = open(path, encoding="utf-8").read()
    rel = os.path.relpath(path, ROOT)
    found = []
    for m in CALL.finditer(text):
        start = m.end() - 1  # 最初の "
        line = text.count("\n", 0, start) + 1
        where = f"{rel}:{line}"
        # コメントの中の L("…") は数えない（行の先頭から見て、文字列の外に // がある）
        head = text[text.rfind("\n", 0, m.start()) + 1:m.start()]
        quotes, in_comment = 0, False
        for j, ch in enumerate(head):
            if ch == '"' and (j == 0 or head[j - 1] != "\\"):
                quotes += 1
            elif head.startswith("//", j) and quotes % 2 == 0:
                in_comment = True
                break
        if in_comment:
            continue
        if text.startswith('"""', start):
            # 複数行：次の行から、閉じの """ の行まで。閉じの行の字下げを各行から外す
            nl = text.index("\n", start)
            end = text.index('"""', nl)
            body = text[nl + 1:end]
            lines = body.split("\n")
            indent = lines[-1]  # 閉じの """ の前の空白
            if indent.strip():
                raise ValueError(f"{where}: 閉じの \"\"\" は行の先頭（字下げだけ）に置く")
            content = []
            for ln in lines[:-1]:
                if ln.strip() == "":
                    content.append("")
                elif ln.startswith(indent):
                    content.append(ln[len(indent):])
                else:
                    raise ValueError(f"{where}: 複数行の文字列の字下げがそろっていません")
            raw = "\n".join(content)
            # 行末の \ は改行をつなぐ
            raw = re.sub(r"\\\n", "", raw)
            found.append((decode_escapes(raw, where), where))
        else:
            i = start + 1
            buf = []
            while True:
                c = text[i]
                if c == "\\":
                    buf.append(text[i:i + 2]); i += 2; continue
                if c == '"':
                    break
                if c == "\n":
                    raise ValueError(f"{where}: 文字列が閉じていません")
                buf.append(c); i += 1
            found.append((decode_escapes("".join(buf), where), where))
    return found


def all_keys(files=None):
    if not files:
        files = []
        for d, _, fs in os.walk(SRC):
            files += [os.path.join(d, f) for f in fs if f.endswith(".swift") and not f.startswith("Strings+")]
    keys = {}
    for f in sorted(files):
        for k, where in keys_in(f):
            keys.setdefault(k, where)
    return keys


def load(lang):
    p = os.path.join(L10N, f"{lang}.json")
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}


def save(lang, d):
    os.makedirs(L10N, exist_ok=True)
    with open(os.path.join(L10N, f"{lang}.json"), "w", encoding="utf-8") as f:
        json.dump(dict(sorted(d.items())), f, ensure_ascii=False, indent=1)
        f.write("\n")


def specs(s):
    return sorted(SPEC.findall(s.replace("%%", "")))


def swift_literal(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"'


def gen():
    keys = all_keys()
    names = {"en": "英語", "zh": "简体中文"}
    for lang in LANGS:
        d = load(lang)
        used = {k: v for k, v in d.items() if k in keys and v}
        out = [f"// {names[lang]}の訳。scripts/l10n.py gen が l10n/{lang}.json から作る（手で直さない）",
               "extension L10n {", f"    static let {lang}: [String: String] = ["]
        for k in sorted(used):
            out.append(f"        {swift_literal(k)}: {swift_literal(used[k])},")
        out += ["    ]", "}", ""]
        path = os.path.join(SRC, "Localization", f"Strings+{lang}.swift")
        open(path, "w", encoding="utf-8").write("\n".join(out))
        print(f"{lang}: {len(used)} / {len(keys)}")


def check():
    keys = all_keys()
    bad = 0
    for lang in LANGS:
        d = load(lang)
        miss = [k for k in keys if not d.get(k)]
        for k in miss:
            print(f"missing {lang}: {keys[k]}: {k[:70]!r}")
        bad += len(miss)
        for k, v in d.items():
            if k in keys and v and specs(k) != specs(v):
                print(f"placeholders differ {lang}: {keys[k]}: {specs(k)} vs {specs(v)}: {k[:50]!r}")
                bad += 1
    print(f"{len(keys)} keys, {bad} problems")
    return bad == 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    try:
        if cmd == "keys":
            ks = all_keys(sys.argv[2:])
            print(json.dumps({k: w for k, w in ks.items()}, ensure_ascii=False, indent=1))
        elif cmd == "missing":
            lang = sys.argv[2]
            d = load(lang)
            print(json.dumps({k: "" for k in all_keys() if not d.get(k)}, ensure_ascii=False, indent=1))
        elif cmd == "merge":
            lang, part = sys.argv[2], sys.argv[3]
            d = load(lang)
            new = json.load(open(part, encoding="utf-8"))
            keys = all_keys()
            unknown = [k for k in new if k not in keys]
            for k in unknown:
                print(f"not in sources: {k[:70]!r}", file=sys.stderr)
            d.update({k: v for k, v in new.items() if v})
            save(lang, d)
            print(f"{lang}: merged {len(new) - len(unknown)} (unknown {len(unknown)})")
        elif cmd == "gen":
            gen()
        elif cmd == "check":
            sys.exit(0 if check() else 1)
        else:
            print(__doc__)
            sys.exit(2)
    except ValueError as e:
        print(e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
