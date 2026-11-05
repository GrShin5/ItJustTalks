#!/usr/bin/env python3
"""Deterministic generator for Evaluation/cases/long.jsonl (synthetic long-input cases).

Standard library only. Run with `python3 -I`.

    python3 -I Evaluation/generate_long_cases.py           # (re)write cases/long.jsonl
    python3 -I Evaluation/generate_long_cases.py --check   # fail if the file differs from regeneration

Everything is fictional. Text is composed from the paragraph templates and name pools below
using a tiny self-contained PRNG (xorshift64*), so output does not depend on the Python
version or on the `random` module. Each case's `checkpoints` are distinctive facts
(names, dates, amounts, codes) that appear verbatim exactly once in the generated text.
"""

import json
import os
import sys

MASK = (1 << 64) - 1


class Rng:
    """xorshift64* with a fixed, version-independent algorithm."""

    def __init__(self, seed):
        self.s = ((seed * 0x9E3779B97F4A7C15) + 0x1234567) & MASK or 1

    def next(self):
        x = self.s
        x ^= x >> 12
        x ^= (x << 25) & MASK
        x ^= x >> 27
        self.s = x
        return (x * 0x2545F4914F6CDD1D) & MASK

    def randint(self, a, b):
        return a + self.next() % (b - a + 1)

    def choice(self, seq):
        return seq[self.next() % len(seq)]


def yen(rng):
    return "{:,}".format(rng.randint(12, 98) * 10000 + rng.randint(1, 9) * 1000)


def usd(rng):
    return "{:,}".format(rng.randint(12, 98) * 100 + rng.randint(1, 9) * 10)


def code(rng):
    return "%s-%d" % (rng.choice("KMRTX"), rng.randint(1000, 9999))


# ---------------------------------------------------------------- pools (all fictional)
JA_SURN = ["佐伯", "日向", "真壁", "楠木", "綾瀬", "久保田", "津田", "榊原", "八木沢", "桐谷",
           "篠崎", "宇佐美", "磯貝", "蓮見", "堀江", "三枝", "柏木", "小野寺", "水無瀬", "望月"]
JA_PROJ = ["ミズナラ", "ヒバリ", "カワセミ", "ツバメ", "アカシア", "ヤマブキ", "サザンカ", "ナナカマド", "ホタル", "コハク"]
JA_ROOM = ["第3会議室", "北館2階ラウンジ", "港南センター4号室", "西棟B会議室", "オンライン会議室A", "研修室201"]
JA_VENDOR = ["ミナト運輸", "アサヒナ電機", "ツキノワ印刷", "フジミ機工", "ハナオカ商会", "クロサワ設備"]
JA_CAUSE = ["設定ファイルの読込みの誤り", "通信の再試行の失敗", "日付の丸め処理の誤り", "キャッシュの更新漏れ"]
JA_CITY = ["札幌", "仙台", "金沢", "広島", "福岡", "松山"]
JA_HOTEL = ["ホテルみなと", "旅館さざなみ", "ビジネスホテル青海", "ホテル緑風"]
JA_DEV = ["ルミナ端末", "コトノハスピーカー", "アクア充電器", "ハルカ型センサー"]
JA_FILLER = ["えーと、", "あの、", "そのー、", "えっと、", ""]
JA_PRE = ["", "まず、", "次に、", "また、", "なお、", "それから、", "ところで、", "最後に、"]

EN_SURN = ["Alder", "Brightwell", "Calloway", "Dunmore", "Eastwick", "Fairchild", "Hargrove", "Ingram",
           "Kestrel", "Lindqvist", "Marlowe", "Northcott", "Oakhurst", "Pemberton", "Quill", "Rowntree"]
EN_PROJ = ["Harbor", "Juniper", "Lantern", "Meridian", "Nimbus", "Orchard", "Quartz", "Willow"]
EN_ROOM = ["Room 4B", "the Atrium", "Studio 12", "Conference Room C", "Annex 7", "the Garden Hall"]
EN_VENDOR = ["Northgate Freight", "Bluebird Print", "Copperfield Systems", "Tidewater Supply", "Larkspur Labs"]
EN_CAUSE = ["a misread settings file", "a failed retry loop", "a date rounding mistake", "a stale cache entry"]
EN_CITY = ["Lisbon", "Denver", "Osaka", "Bergen", "Valencia", "Tucson"]
EN_HOTEL = ["Harborview Inn", "The Linden House", "Stonebridge Suites", "Cedar Court Hotel"]
EN_DEV = ["the Lumen tablet", "the Aqua charger", "the Haru sensor", "the Kite speaker"]
EN_FILLER = ["um, ", "uh, ", "you know, ", "so, ", ""]
EN_PRE = ["", "First, ", "Next, ", "Also, ", "Then, ", "By the way, ", "Finally, "]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December"]
HOSTS = ["alpha", "bravo", "cedar", "delta", "ember", "fjord", "glade", "harbor"]


def md(rng):
    return rng.randint(1, 12), rng.randint(1, 28)


# ---------------------------------------------------------------- paragraph templates
# Each returns (text, facts). Facts are substrings that appear verbatim in text.
def ja_paras(rng, lang):
    mixed = lang == "mixed"
    n1, n2 = rng.choice(JA_SURN), rng.choice(JA_SURN)
    proj, room, vendor = rng.choice(JA_PROJ), rng.choice(JA_ROOM), rng.choice(JA_VENDOR)
    m, d = md(rng)
    m2, d2 = md(rng)
    h = rng.randint(9, 17)
    amt, amt2 = yen(rng), yen(rng)
    c = code(rng)
    n, k = rng.randint(3, 40), rng.randint(2, 9)
    pct, ms, ms2 = rng.randint(80, 99), rng.randint(120, 480), rng.randint(60, 110)
    ver = "%d.%d.%d" % (rng.randint(1, 4), rng.randint(0, 9), rng.randint(0, 9))
    host = rng.choice(HOSTS)
    city, hotel, dev = rng.choice(JA_CITY), rng.choice(JA_HOTEL), rng.choice(JA_DEV)
    cause = rng.choice(JA_CAUSE)
    out = []
    out.append(("%s%sさんから連絡があり、%sプロジェクトの定例を%d月%d日の%d時に%sで開くことになりました。"
                % ("", n1, proj, m, d, h, room), ["%sさん" % n1, "%d月%d日" % (m, d), room]))
    out.append(("予算については、今期の追加分として%s円を見込んでいて、そのうち%s円は%sへの支払いです。"
                % (amt, amt2, vendor), [amt + "円", amt2 + "円", vendor]))
    out.append(("案件番号%sの不具合の原因は%sで、%d件のお客様に影響が出ています。"
                % (c, cause, n), [c, cause]))
    out.append(("来月の出張は%sで、%d月%d日から%d泊の予定です。宿は%sを押さえました。"
                % (city, m2, d2, k, hotel), [hotel, "%d月%d日から%d泊" % (m2, d2, k)]))
    out.append(("新しい%sの試験は%d台で行い、合格基準は%dパーセント以上です。"
                % (dev, n, pct), [dev, "%dパーセント" % pct]))
    out.append(("担当は%sさんと%sさんで、%sさんが設計、%sさんが検証を進めます。"
                % (n1, n2, n1, n2), ["%sさんと%sさん" % (n1, n2)]))
    out.append(("締め切りは%d月%d日の%d時で、遅れる場合は前日までに%sさんへ連絡してください。"
                % (m2, d2, h, n2), ["%d月%d日の%d時" % (m2, d2, h)]))
    out.append(("参加者は全部で%d名で、そのうち%d名がオンラインで参加する予定です。"
                % (n + 10, k), ["全部で%d名" % (n + 10)]))
    if mixed:
        out.append(("%sリリースのsprintは%d月%d日に始まり、バージョン%sのdeployは%sさんが担当します。"
                    % (proj, m, d, ver, n1), ["バージョン%s" % ver]))
        out.append(("APIのレスポンスは平均%dミリ秒で、目標の%dミリ秒を大きく上回っているため、%sさんがcacheの見直しを行います。"
                    % (ms, ms2, n2), ["平均%dミリ秒" % ms, "目標の%dミリ秒" % ms2]))
        out.append(("pull requestは%d件で、mainへのmergeは%d月%d日の予定です。確認用のstagingは%s.example.comで動いています。"
                    % (k, m2, d2, host), ["%s.example.com" % host]))
        out.append(("CIの失敗率は%d%%から%d%%に下がり、%sのbuild時間も%d分短くなりました。"
                    % (pct // 3, k, proj, k + 1), ["%d%%から%d%%" % (pct // 3, k)]))
    return out


def en_paras(rng, lang):
    n1, n2 = rng.choice(EN_SURN), rng.choice(EN_SURN)
    proj, room, vendor = rng.choice(EN_PROJ), rng.choice(EN_ROOM), rng.choice(EN_VENDOR)
    m, d = md(rng)
    m2, d2 = md(rng)
    h = rng.randint(9, 17)
    amt, amt2 = usd(rng), usd(rng)
    c = code(rng)
    n, k = rng.randint(3, 40), rng.randint(2, 9)
    pct = rng.randint(80, 99)
    city, hotel, dev = rng.choice(EN_CITY), rng.choice(EN_HOTEL), rng.choice(EN_DEV)
    cause = rng.choice(EN_CAUSE)
    out = []
    out.append(("Ms. %s confirmed that the %s review will take place on %s %d at %d:30 in %s."
                % (n1, proj, MONTHS[m - 1], d, h, room), ["Ms. %s" % n1, "%s %d at %d:30" % (MONTHS[m - 1], d, h), room]))
    out.append(("On the budget side, we expect an extra $%s this quarter, and $%s of that goes to %s."
                % (amt, amt2, vendor), ["$" + amt, "$" + amt2, vendor]))
    out.append(("Ticket %s was traced to %s, and %d customers were affected."
                % (c, cause, n), [c, cause]))
    out.append(("Next month's trip is to %s, leaving on %s %d for %d nights, and we booked %s."
                % (city, MONTHS[m2 - 1], d2, k, hotel), [hotel, "%s %d for %d nights" % (MONTHS[m2 - 1], d2, k)]))
    out.append(("The trial of %s will use %d units, and the pass mark is %d percent or higher."
                % (dev, n, pct), [dev, "%d percent" % pct]))
    out.append(("%s and %s own the work: %s handles the design and %s handles the verification."
                % (n1, n2, n1, n2), ["%s and %s own" % (n1, n2)]))
    out.append(("The deadline is %s %d at %d:00, and anyone running late should tell %s a day earlier."
                % (MONTHS[m2 - 1], d2, h, n2), ["%s %d at %d:00" % (MONTHS[m2 - 1], d2, h)]))
    out.append(("In total %d people will attend, and %d of them will join online."
                % (n + 10, k), ["%d people" % (n + 10)]))
    return out


def build_text(lang, kind, target, seed):
    rng = Rng(seed)
    spoken = kind == "transcript"
    parts, facts, size = [], [], 0
    sep = ("" if lang != "en" else " ") if spoken else "\n\n"
    while True:
        batch = ja_paras(rng, lang) if lang in ("ja", "mixed") else en_paras(rng, lang)
        order = list(range(len(batch)))
        for i in range(len(order) - 1, 0, -1):  # Fisher-Yates with our own PRNG
            j = rng.randint(0, i)
            order[i], order[j] = order[j], order[i]
        for i in order:
            text, fs = batch[i]
            if lang == "en":
                pre = rng.choice(EN_PRE)
                filler = rng.choice(EN_FILLER) if spoken else ""
                text = pre + filler + (text[0].lower() + text[1:] if (pre or filler) else text)
            else:
                pre = rng.choice(JA_PRE)
                filler = rng.choice(JA_FILLER) if spoken else ""
                text = filler + pre + text
            length = len(text.split()) if (lang == "en" and spoken) else len(text)
            if size >= target * 0.92 and size + length > target * 1.03:
                return sep.join(parts), facts
            parts.append(text)
            facts.extend(fs)
            size += length
            if size >= target:
                return sep.join(parts), facts


def pick_checkpoints(text, facts, want):
    uniq = []
    for f in facts:
        if text.count(f) == 1 and f not in uniq:
            uniq.append(f)
    if len(uniq) < want:
        raise SystemExit("not enough unique facts: %d" % len(uniq))
    step = len(uniq) / float(want)
    return [uniq[int(i * step)] for i in range(want)]


# id, lang, kind, size (sec or chars), instruction, language, critical, purpose, seed
SPECS = [
    ("LG-001", "ja", "transcript", 60, None, "ja", False, "60 s Japanese dictation, single-pass baseline", 101),
    ("LG-002", "ja", "transcript", 180, None, "ja", False, "180 s Japanese dictation with many numbers and names", 102),
    ("LG-003", "ja", "transcript", 300, None, "ja", True, "300 s Japanese dictation (default max length), must not drop sentences", 103),
    ("LG-004", "ja", "transcript", 600, None, "ja", True, "600 s Japanese dictation, likely needs segmentation", 104),
    ("LG-005", "en", "transcript", 300, None, "en", False, "300 s English dictation with fillers", 105),
    ("LG-006", "mixed", "transcript", 180, None, "ja", False, "180 s Japanese dictation with English technical terms", 106),
    ("LG-007", "ja", "selection", 3000, "この文章を要約して", "ja", False, "3000-char Japanese selection, summarize (answer; checkpoints are key facts to keep)", 107),
    ("LG-008", "ja", "selection", 6000, "もう少し丁寧な文章に書き換えて", "ja", True, "6000-char Japanese selection, polite rewrite must keep every fact", 108),
    ("LG-009", "mixed", "selection", 12000, "重要な日付と金額を箇条書きで抜き出して", "ja", True, "12000-char clipboard-limit selection with English terms, extraction", 109),
    ("LG-010", "en", "selection", 3000, "Summarize this", "en", False, "3000-char English selection, summarize", 110),
]


def build_cases():
    cases = []
    for cid, lang, kind, size, instr, olang, crit, purpose, seed in SPECS:
        if kind == "transcript":
            per_min = 150 if lang == "en" else 575
            target = size * per_min // 60
        else:
            target = size
        text, facts = build_text(lang, kind, target, seed)
        inp = {"kind": kind}
        if kind == "transcript":
            inp["durationSec"] = size
        else:
            inp["targetChars"] = size
            inp["instruction"] = instr
        inp["text"] = text
        cases.append({
            "id": cid, "category": "long", "lang": lang, "purpose": purpose, "critical": crit,
            "input": inp,
            "expect": {"checkpoints": pick_checkpoints(text, facts, 10), "language": olang},
        })
    # Keep the original ten specs and generation untouched; append independent fixed seeds.
    cases.extend(build_p6_cases())
    return cases


def build_p6_cases():
    specs = [
        (11, "en", "transcript", 600, None, "en", False, "600 s English dictation"),
        (12, "ja", "transcript", 600, None, "ja", True, "600 s Japanese hands-free dictation"),
        (13, "ja", "selection", 12000, "この文章を英語に翻訳して", "en", True, "12000-char translation with language-neutral checkpoints"),
        (14, "ja", "selection", 12000, "この文章を要約して", "ja", False, "12000-char Japanese summary"),
        (15, "ja", "selection", 12000, "もう少し丁寧な文章に書き換えて", "ja", True, "12000-char polite rewrite preserving all facts"),
        (16, "en", "selection", 12000, "Proofread this", "en", True, "12000-char English proofreading"),
        (17, "ja", "transcript", 300, None, "ja", True, "QA-12: six evenly spaced spoken self-corrections, 300 s"),
        (18, "ja", "transcript", 600, None, "ja", True, "QA-12: six evenly spaced spoken self-corrections, 600 s"),
        (19, "ja", "transcript", 600, None, "ja", True, "QA-13: distant correction in last third referring to first third"),
    ]
    cases = []
    for num, lang, kind, size, instruction, output_lang, critical, purpose in specs:
        target = size * (150 if lang == "en" else 575) // 60 if kind == "transcript" else size
        text, facts = build_text(lang, kind, target, 100 + num)
        corrections = []
        if num in (17, 18):
            # Insert only at complete sentence boundaries, evenly across six source regions.
            sentences = text.split("。")
            inserts = {}
            for k in range(6):
                old, new = "%d時%d分" % (k + 1, 41 + k), "%d時%d分" % (k + 13, 51 + k)
                corrections.append({"old": old, "new": new})
                index = min(len(sentences) - 1, (2 * k + 1) * len(sentences) // 12)
                inserts[index] = "架空の第%d会議は%sから、いや、%sからです" % (k + 1, old, new)
            parts = []
            for index, sentence in enumerate(sentences):
                if sentence:
                    parts.append(sentence)
                if index in inserts:
                    parts.append(inserts[index])
            text = "。".join(parts) + "。"
        elif num == 19:
            old = "札幌への架空の出張は11月29日から2泊の予定です"
            new = "札幌への架空の出張は取り消しになりました"
            sentences = text.split("。")
            sentences.insert(len(sentences) // 8, old)
            sentences.insert(len(sentences) * 7 // 8, "最初に話した" + new)
            text = "。".join(sentences)
            corrections = [{"old": old, "new": new}]
        if num == 13:
            # Explicit immutable identifiers, distributed throughout the selection. No translated words.
            rng = Rng(913)
            checkpoints = []
            while len(checkpoints) < 10:
                token = "T-%d" % rng.randint(1000, 9999)
                if token not in text and token not in checkpoints:
                    checkpoints.append(token)
            paragraphs = text.split("\n\n")
            for k, token in enumerate(checkpoints):
                index = k * len(paragraphs) // len(checkpoints)
                paragraphs[index] += " 参照コードは%sです。" % token
            text = "\n\n".join(paragraphs)
        else:
            checkpoints = pick_checkpoints(text, facts, 10)
        inp = {"kind": kind, "text": text}
        if kind == "transcript":
            inp["durationSec"] = size
        else:
            inp.update(targetChars=size, instruction=instruction)
        if num == 12:
            inp["handsFree"] = True
        expect = {"checkpoints": checkpoints, "language": output_lang}
        if corrections:
            expect.update(corrections=corrections, reviewAcceptable=True)
        cases.append({"id": "LG-%03d" % num, "category": "long", "lang": lang,
                      "purpose": purpose, "critical": critical, "input": inp, "expect": expect})
    return cases


def render():
    return "".join(json.dumps(c, ensure_ascii=False) + "\n" for c in build_cases())


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "cases", "long.jsonl")
    data = render()
    if "--check" in argv:
        try:
            with open(path, encoding="utf-8") as f:
                current = f.read()
        except OSError as e:
            print("FAIL: cannot read %s: %s" % (path, e))
            return 1
        if current != data:
            print("FAIL: %s differs from regenerated output" % path)
            return 1
        print("OK: long.jsonl matches deterministic regeneration (%d cases)" % len(build_cases()))
        return 0
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)
    print("wrote %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
