#!/usr/bin/env python3
"""Copy.swift + CopyDNS.swift -> Android values-<lang>/strings.xml (все 17 языков).

Ключи CopyKey camelCase -> snake_case; presetDescriptions -> dns_desc_<id>.
%@ -> %1$s ; {price} остаётся литералом (подстановка в рантайме как в iOS).
Существующие ключи в values/strings.xml сохраняются, новые дописываются.
"""
import re, sys, os
import xml.etree.ElementTree as ET

IPHONE = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/projects/vpnfreeforever/Iphone")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser(
    "~/projects/vpnfreeforever/androidApp/app/src/main/res")

LANGS = {  # swift dict name -> android qualifier
    "english": "en", "spanish": "es", "german": "de", "french": "fr",
    "italian": "it", "portuguese": "pt-rBR", "japanese": "ja", "chinese": "zh-rCN",
    "korean": "ko", "arabic": "ar", "hindi": "hi", "thai": "th",
    "turkish": "tr", "polish": "pl", "dutch": "nl", "vietnamese": "vi",
    "russian": "ru",
}

def snake(name: str) -> str:
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower()
    s = re.sub(r"[^a-z0-9_]", "_", s)
    return s or "unnamed"

def esc(v: str) -> str:
    v = v.replace("\\", "\\\\").replace("'", "\\'").replace('"', '\\"')
    v = v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    v = re.sub(r"%@", "%1$s", v)
    return v

def parse_dicts(text: str):
    """Возвращает {lang: {key: value}} для `private let <lang>: [CopyKey: String]`."""
    out, problems = {}, []
    for m in re.finditer(r"private let (\w+): \[CopyKey: String\] = \[(.*?)\n    \]", text, re.S):
        lang, body = m.group(1), m.group(2)
        pairs = {}
        # entries: .key: "value",  (value без неэкранированных кавычек внутри)
        for em in re.finditer(r'\.(\w+): "((?:[^"\\]|\\.)*)",?', body):
            k, v = em.group(1), em.group(2)
            v = v.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
            pairs[k] = v
        out[lang] = pairs
    return out, problems

def parse_preset_desc(text: str):
    """[.english: ["id": "text", ...], ...] -> {lang: {dns_desc_id: text}}"""
    out = {}
    m = re.search(r"presetDescriptions: \[AppLanguage: \[String: String\]\] = \[(.*)\n    \]", text, re.S)
    if not m:
        return out
    for lm in re.finditer(r"\.(\w+): \[(.*?)\n        \]", m.group(1), re.S):
        lang = lm.group(1)
        pairs = {}
        for em in re.finditer(r'"([\w\-\.]+)": "((?:[^"\\]|\\.)*)",?', lm.group(2)):
            pid, v = em.group(1), em.group(2)
            v = v.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
            pairs["dns_desc_" + pid.replace("-", "_")] = v
        out[lang] = pairs
    return out

def load_existing(path):
    if not os.path.exists(path):
        return []
    try:
        root = ET.parse(path).getroot()
        return [(e.get("name"), (e.text or "")) for e in root.findall("string")]
    except Exception as ex:
        print("WARN: cannot parse", path, ex)
        return []

def main():
    copy = open(os.path.join(IPHONE, "App/Copy.swift"), encoding="utf-8").read()
    dns = open(os.path.join(IPHONE, "App/CopyDNS.swift"), encoding="utf-8").read()
    dicts, _ = parse_dicts(copy)
    d2, _ = parse_dicts(dns)
    for lang, pairs in d2.items():
        dicts.setdefault(lang, {}).update(pairs)
    descs = parse_preset_desc(dns)
    for lang, pairs in descs.items():
        dicts.setdefault(lang, {}).update(pairs)

    en_keys = set(dicts.get("english", {}))
    print("english keys:", len(en_keys))
    for lang in sorted(dicts):
        if lang == "english":
            continue
        missing = en_keys - set(dicts[lang])
        if missing:
            print(f"  {lang}: missing {len(missing)} (fallback to en at runtime):",
                  sorted(missing)[:8])

    for lang, qual in LANGS.items():
        pairs = dicts.get(lang, {})
        d = os.path.join(OUT, "values" if qual == "en" else f"values-{qual}")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "strings.xml")
        existing = load_existing(path) if qual == "en" else []
        have = {n for n, _ in existing}
        items = list(existing)
        added = 0
        for k in sorted(en_keys):
            sk = snake(k)
            if sk in have:
                continue
            v = pairs.get(k)
            if v is None:
                continue  # нет перевода — Android возьмёт values/ сам
            items.append((sk, v))
            added += 1
        # нестандартные ключи языка (на случай рассинхрона)
        for k, v in sorted(pairs.items()):
            sk = snake(k)
            if sk not in have and sk not in {n for n, _ in items}:
                items.append((sk, v))
                added += 1
        with open(path, "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n')
            for n, v in items:
                f.write(f'    <string name="{n}">{esc(v)}</string>\n')
            f.write('</resources>\n')
        print(f"{qual}: {len(items)} strings ({added} new)")

if __name__ == "__main__":
    main()
