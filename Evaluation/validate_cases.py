#!/usr/bin/env python3
"""Validate Evaluation/cases/*.jsonl (schema, enums, ids, counts, coverage, hygiene).

Standard library only. Run with `python3 -I Evaluation/validate_cases.py`.
Holdout set (cleanup + routing only, own ids and coverage minimums):
`python3 -I Evaluation/validate_cases.py --dir Evaluation/holdout --holdout`.
Optional: `--dir <path>` reads the jsonl files from another directory (default set only);
`--holdout2` validates the second holdout set (Evaluation/holdout2: H2C-/H2R- ids, 40 + 30 cases).
`--holdout3` validates the third holdout set (Evaluation/holdout3: cleanup only, H3C- ids, 60 cases).
`--holdout4` validates the independent four-category holdout set.
Exits 0 when everything is valid, 1 otherwise. Never prints case bodies, only ids and counts.
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CASES_DIR = os.path.join(HERE, "cases")

FILES = {  # file stem -> (category, id prefix, required count)
    "cleanup": ("cleanup", "CL", 69),
    "routing": ("routing", "RT", 64),
    "generation": ("generation", "GN", 44),
    "optimization": ("optimization", "OP", 22),
    "long": ("long", "LG", 19),
}
ACCURACY_FILES = {"cleanup": ("cleanup", "AC", 30)}
NORMAL_LOOP_FILES = {"cleanup": ("cleanup", "(?:NM|H5C)", 80)}

HOLDOUT_FILES = {
    "cleanup": ("cleanup", "HC", 40),
    "routing": ("routing", "HR", 40),
}
HOLDOUT_LANG_SHARE = (("ja", 50, 70), ("en", 12, 28), ("mixed", 12, 28))  # per file, percent
FILLER_RE = re.compile(r"えーと|えっと|ええと|あのー|あの|そのー|その|なんか|まあ|\bum\b|\buh\b|you know", re.IGNORECASE)
REQUEST_END_RE = re.compile(r"ください|くれ|ほしい|お願い|教えて|please|\?|？", re.IGNORECASE)
CORRECTION_CUES = ("いや", "やっぱり", "じゃなくて|ではなくて", "すみません", "訂正", "違う", "actually", "I mean", "no wait")
LANGS = ("ja", "en", "mixed")
TOP_KEYS = {"id", "category", "lang", "purpose", "critical", "input", "expect"}
OUTPUT_INTENTS = ("automatic", "show_result", "insert_at_target")
TASK_TYPES = ("proofread_rewrite", "translate", "transform", "summarize", "extract", "explain_analyze",
              "answer_question", "compose_reply", "insufficient_target", "not_executable", "requires_web")
GENERATING = ("proofread_rewrite", "translate", "transform", "summarize", "extract", "explain_analyze",
              "answer_question", "compose_reply")
KINDS = ("content", "answer", "clarification", "refusal", "requires_web")
OUTPUT_LANGS = ("ja", "en", "auto")

# Second holdout set (--holdout2): same schema, different ids/counts/coverage floors.
FILES_HOLDOUT2 = {
    "cleanup": ("cleanup", "H2C", 40),
    "routing": ("routing", "H2R", 30),
}
MINIMUMS_HOLDOUT2 = {
    "cleanup": {"handsFree": 15, "corrections": 20, "tag:cue-not-correction": 6, "tag:filler-heavy": 6},
    "routing": {"tag:edit+question": 10, "tag:negated": 6, "tag:summarize/extract": 6,
                "injection": 4, "target_null": 4},
}
HOLDOUT2_TAGS = ("cue-not-correction", "filler-heavy", "edit+question", "negated", "summarize/extract")

# Third holdout set (--holdout3): cleanup only; tags in `purpose` mark the round-3 target phenomena.
FILES_HOLDOUT4 = {
    "cleanup": ("cleanup", "H4C", 60),
    "routing": ("routing", "H4R", 20),
    "generation": ("generation", "H4G", 30),
    "optimization": ("optimization", "H4O", 10),
}
MINIMUMS_HOLDOUT4 = {
    "cleanup": {"handsFree": 20, "dictionary": 8, "customInstructionNonblank": 6, "correction_wired": 8},
    "routing": {"target_null": 2, **{"task:" + t: 1 for t in GENERATING}},
    "generation": {**{"task:" + t: 3 for t in GENERATING}, "translate_to_en": 2, "translate_to_ja": 2},
    "optimization": {"mode:cleanup": 3, "mode:aiCommand": 3},
}

FILES_HOLDOUT3 = {
    "cleanup": ("cleanup", "H3C", 60),
}
MINIMUMS_HOLDOUT3 = {
    "cleanup": {"handsFree": 30, "corrections": 30, "tag:whole-retraction": 6, "tag:en-actually": 6,
                "tag:double-correction": 6, "tag:negation": 8, "tag:cue-not-correction": 8,
                "tag:filler-heavy": 4},
}
HOLDOUT3_TAGS = ("whole-retraction", "en-actually", "double-correction", "negation", "cue-not-correction",
                 "filler-heavy")
HOLDOUT3_LANG_SHARE = (("ja", 50, 70), ("en", 15, 30), ("mixed", 10, 25))

errors = []


def err(cid, msg):
    errors.append("%s: %s" % (cid, msg))


def is_str_list(v, nonempty=False):
    return isinstance(v, list) and all(isinstance(x, str) and x != "" for x in v) and (bool(v) or not nonempty)


def check_keys(cid, obj, keys, where):
    if not isinstance(obj, dict):
        err(cid, "%s must be an object" % where)
        return False
    if set(obj) != set(keys):
        err(cid, "%s keys %s != expected %s" % (where, sorted(obj), sorted(keys)))
        return False
    return True


def check_dictionary(cid, d, where):
    if not isinstance(d, list):
        err(cid, "%s.dictionary must be a list" % where)
        return
    for e in d:
        if not check_keys(cid, e, ("preferred", "readings", "memo"), "dictionary entry"):
            continue
        if not isinstance(e["preferred"], str) or not e["preferred"]:
            err(cid, "dictionary.preferred must be a non-empty string")
        if not is_str_list(e["readings"], True):
            err(cid, "dictionary.readings must be a non-empty list of strings")
        if e["memo"] is not None and not isinstance(e["memo"], str):
            err(cid, "dictionary.memo must be string or null")


def v_cleanup(c, cov):
    cid, i, e = c["id"], c["input"], c["expect"]
    if not (check_keys(cid, i, ("transcript", "customInstruction", "dictionary", "outputLanguage", "handsFree"), "input")
            and check_keys(cid, e, ("mustContain", "mustNotContain", "language", "noAnswer", "correction"), "expect")):
        return
    if not isinstance(i["transcript"], str) or not i["transcript"].strip():
        err(cid, "transcript must be a non-empty string")
    if i["customInstruction"] is not None and not isinstance(i["customInstruction"], str):
        err(cid, "customInstruction must be string or null")
    check_dictionary(cid, i["dictionary"], "input")
    if i["outputLanguage"] not in OUTPUT_LANGS:
        err(cid, "outputLanguage enum")
    if not isinstance(i["handsFree"], bool):
        err(cid, "handsFree must be bool")
    if not is_str_list(e["mustContain"], True):
        err(cid, "mustContain must be a non-empty list of non-empty strings")
    if not is_str_list(e["mustNotContain"]):
        err(cid, "mustNotContain must be a list of non-empty strings")
    if e["language"] not in ("ja", "en"):
        err(cid, "expect.language must be ja|en")
    if not isinstance(e["noAnswer"], bool):
        err(cid, "noAnswer must be bool")
    corr = e["correction"]
    if corr is not None:
        if check_keys(cid, corr, ("old", "new"), "correction"):
            if not (isinstance(corr["old"], str) and isinstance(corr["new"], str) and corr["old"] and corr["new"]):
                err(cid, "correction old/new must be non-empty strings")
            elif corr["old"] not in i["transcript"] or corr["new"] not in i["transcript"]:
                err(cid, "correction old/new must both appear in the transcript")
        cov["corrections"] += 1
        if isinstance(corr.get("old"), str) and isinstance(corr.get("new"), str):
            if corr["old"] in e["mustNotContain"] and any(corr["new"] in m for m in e["mustContain"]):
                cov["correction_wired"] += 1
            else:
                cov["correction_unwired"] += 1
        for cue in CORRECTION_CUES:
            if any(re.search(re.escape(a), i["transcript"]) for a in cue.split("|")):
                cov["cue:" + cue] += 1
    cov["handsFree"] += bool(i["handsFree"])
    cov["noAnswer"] += bool(e["noAnswer"])
    if e["noAnswer"] and any(REQUEST_END_RE.search(m) for m in e["mustContain"]):
        cov["noAnswer_request_kept"] += 1
    purpose = c["purpose"].lower()
    if "filler-heavy" in purpose and len(FILLER_RE.findall(i["transcript"])) >= 3 \
            and any(f in " ".join(e["mustNotContain"]) for f in ("えーと", "えっと", "ええと", "あの", "um", "uh", "Um", "Uh")):
        cov["filler_heavy"] += 1
    if "numeric" in purpose and re.search(r"[0-9０-９一二三四五六七八九十百千万]", i["transcript"]):
        cov["numeric_negation"] += 1
    cov["dictionary"] += bool(i["dictionary"])
    cov["customInstruction"] += i["customInstruction"] is not None
    cov["customInstructionNonblank"] += isinstance(i["customInstruction"], str) and bool(i["customInstruction"].strip())


def v_routing(c, cov):
    cid, i, e = c["id"], c["input"], c["expect"]
    if not (check_keys(cid, i, ("instruction", "target", "targetSource"), "input")
            and check_keys(cid, e, ("outputIntent", "taskType", "isReplacementArtifact", "kind", "injection"), "expect")):
        return
    if not isinstance(i["instruction"], str) or not i["instruction"].strip():
        err(cid, "instruction must be a non-empty string")
    tgt, src = i["target"], i["targetSource"]
    if tgt is not None and (not isinstance(tgt, str) or not tgt.strip()):
        err(cid, "target must be a non-empty string or null")
    if (tgt is None) != (src is None):
        err(cid, "targetSource must be null exactly when target is null")
    if src not in (None, "selection", "clipboard"):
        err(cid, "targetSource enum")
    if e["outputIntent"] not in OUTPUT_INTENTS:
        err(cid, "outputIntent enum")
    if e["taskType"] not in TASK_TYPES:
        err(cid, "taskType enum")
    if e["kind"] not in KINDS:
        err(cid, "kind enum")
    if e["isReplacementArtifact"] not in (True, False, None) or (e["isReplacementArtifact"] is not None and not isinstance(e["isReplacementArtifact"], bool)):
        err(cid, "isReplacementArtifact must be bool|null")
    if not isinstance(e["injection"], bool):
        err(cid, "injection must be bool")
    t, k, r = e["taskType"], e["kind"], e["isReplacementArtifact"]
    # consistency (plan section 3.2 kind table)
    fixed = {"requires_web": "requires_web", "insufficient_target": "clarification", "not_executable": "refusal"}
    if t in fixed and k != fixed[t]:
        err(cid, "taskType %s requires kind %s" % (t, fixed[t]))
    if t not in fixed and k not in ("content", "answer"):
        err(cid, "taskType %s must produce kind content|answer" % t)
    if t in ("explain_analyze", "answer_question", "compose_reply") and k != "answer":
        err(cid, "%s must be kind answer" % t)
    if k == "content":
        if tgt is None:
            err(cid, "kind content requires a target (general path never replaces)")
        if t not in ("proofread_rewrite", "translate", "transform", "summarize", "extract"):
            err(cid, "kind content not allowed for %s" % t)
        if r is not True:
            err(cid, "kind content requires isReplacementArtifact true")
    elif k == "answer" and r is not False:
        err(cid, "kind answer requires isReplacementArtifact false")
    elif k in ("clarification", "refusal", "requires_web") and r is not None:
        err(cid, "kind %s requires isReplacementArtifact null" % k)
    if e["injection"] and tgt is None:
        err(cid, "injection cases need a target")
    purpose = c["purpose"].lower()
    if k == "requires_web":
        cov["requires_web"] += 1
    if "web look-alike" in purpose:
        cov["web_lookalike"] += 1
        if k == "requires_web":
            err(cid, "web look-alike must not be requires_web")
    if "conflicting" in purpose or "ambiguous" in purpose:
        cov["conflicting_or_ambiguous"] += 1
        if e["outputIntent"] != "show_result":
            err(cid, "conflicting/ambiguous cases must be show_result")
    elif e["outputIntent"] != "automatic":
        cov["explicit_intent"] += 1
    cov["injection"] += bool(e["injection"])
    cov["target_null"] += tgt is None
    if "mixed edit+question" in purpose:
        cov["mixed_edit_question"] += 1
        if k != "answer":
            err(cid, "mixed edit+question must be kind answer")
    if tgt is not None and t in ("summarize", "extract"):
        cov["summ_extract_content" if k == "content" else "summ_extract_answer"] += 1
    if e["outputIntent"] == "show_result" and not ("conflicting" in purpose or "ambiguous" in purpose):
        cov["explicit_show"] += 1
    if e["outputIntent"] == "insert_at_target":
        cov["explicit_insert"] += 1
    cov["task:" + t] += 1


def v_generation(c, cov):
    cid, i, e = c["id"], c["input"], c["expect"]
    if not (check_keys(cid, i, ("instruction", "target", "taskType", "outputLanguage"), "input")
            and check_keys(cid, e, ("mustContain", "mustNotContain", "language", "maxLengthRatio"), "expect")):
        return
    if not isinstance(i["instruction"], str) or not i["instruction"].strip():
        err(cid, "instruction must be non-empty")
    if i["target"] is not None and not isinstance(i["target"], str):
        err(cid, "target must be string|null")
    if i["taskType"] not in GENERATING:
        err(cid, "taskType must be a generating type")
    if i["outputLanguage"] not in OUTPUT_LANGS:
        err(cid, "outputLanguage enum")
    if not is_str_list(e["mustContain"], True):
        err(cid, "mustContain must be a non-empty list")
    if not is_str_list(e["mustNotContain"]):
        err(cid, "mustNotContain must be a list")
    if e["language"] not in ("ja", "en"):
        err(cid, "expect.language must be ja|en")
    m = e["maxLengthRatio"]
    if m is not None and (isinstance(m, bool) or not isinstance(m, (int, float)) or m <= 0):
        err(cid, "maxLengthRatio must be a positive number or null")
    if i["taskType"] != "answer_question" and i["taskType"] != "compose_reply" and i["target"] is None:
        err(cid, "target may be null only for answer_question / compose_reply")
    cov["task:" + str(i["taskType"])] += 1
    if i["taskType"] == "translate":
        cov["translate_to_" + str(e["language"])] += 1


def v_optimization(c, cov):
    cid, i, e = c["id"], c["input"], c["expect"]
    if not (check_keys(cid, {k: v for k, v in i.items() if k != "mode"}, ("draft", "dictionary"), "input")
            and check_keys(cid, {k: v for k, v in e.items() if k not in ("permissionFlaggedIndices", "permissionFlaggedItems")}, ("maxItems", "maxGraphemes", "mustPreserve", "flagsPermissionItems"), "expect")):
        return
    if not isinstance(i["draft"], str) or not i["draft"].strip():
        err(cid, "draft must be non-empty")
    check_dictionary(cid, i["dictionary"], "input")
    if e["maxItems"] != 5 or isinstance(e["maxItems"], bool):
        err(cid, "maxItems must be 5")
    if e["maxGraphemes"] != 500 or isinstance(e["maxGraphemes"], bool):
        err(cid, "maxGraphemes must be 500")
    if not is_str_list(e["mustPreserve"], True):
        err(cid, "mustPreserve must be a non-empty list")
    if not isinstance(e["flagsPermissionItems"], bool):
        err(cid, "flagsPermissionItems must be bool")
    if i.get("mode", "cleanup") not in ("cleanup", "aiCommand"):
        err(cid, "mode must be cleanup|aiCommand")
    if "permissionFlaggedItems" in e and not is_str_list(e["permissionFlaggedItems"], True):
        err(cid, "permissionFlaggedItems must be a non-empty list of target terms")
    if "permissionFlaggedIndices" in e:
        flags = e["permissionFlaggedIndices"]
        if (not isinstance(flags, list) or any(type(x) is not int or not 0 <= x < 5 for x in flags)
                or len(set(flags)) != len(flags)):
            err(cid, "permissionFlaggedIndices must be distinct item indices 0..4")
    cov["mode:" + str(i.get("mode", "cleanup"))] += 1
    cov["permission_flagged"] += bool(e["flagsPermissionItems"] is True)
    if isinstance(i["draft"], str) and len(i["draft"]) >= 250:
        cov["long_drafts"] += 1


def v_long(c, cov):
    cid, i, e = c["id"], c["input"], c["expect"]
    if not isinstance(i, dict) or i.get("kind") not in ("transcript", "selection"):
        err(cid, "input.kind must be transcript|selection")
        return
    if i["kind"] == "transcript":
        ok = check_keys(cid, {k: v for k, v in i.items() if k != "handsFree"},
                        ("kind", "durationSec", "text"), "input")
        if "handsFree" in i and not isinstance(i["handsFree"], bool):
            err(cid, "handsFree must be bool")
    else:
        ok = check_keys(cid, i, ("kind", "targetChars", "instruction", "text"), "input")
    if not isinstance(e, dict):
        err(cid, "expect must be an object")
        return
    if not (ok and check_keys(cid, {k: v for k, v in e.items() if k not in ("corrections", "reviewAcceptable")},
                              ("checkpoints", "language"), "expect")):
        return
    text = i["text"]
    if not isinstance(text, str) or not text:
        err(cid, "text must be a non-empty string")
        return
    if i["kind"] == "transcript":
        d = i["durationSec"]
        if d not in (60, 180, 300, 600) or isinstance(d, bool):
            err(cid, "durationSec must be one of 60|180|300|600")
        else:
            cov["dur:%d" % d] += 1
            if c["lang"] == "en":
                expected, actual = d / 60.0 * 150, len(text.split())
            else:
                expected, actual = d / 60.0 * 575, len(text)
            if not 0.85 <= actual / expected <= 1.15:
                err(cid, "text size %d not within 15%% of %d for %ss" % (actual, expected, d))
    else:
        n = i["targetChars"]
        if not isinstance(n, int) or isinstance(n, bool) or n < 1000:
            err(cid, "targetChars must be an int >= 1000")
        else:
            cov["chars:%d" % n] += 1
            if not 0.9 <= len(text) / float(n) <= 1.1:
                err(cid, "text length %d not within 10%% of targetChars %d" % (len(text), n))
        if not isinstance(i["instruction"], str) or not i["instruction"].strip():
            err(cid, "selection needs an instruction")
    cps = e["checkpoints"]
    if not is_str_list(cps, True) or len(cps) < 8:
        err(cid, "checkpoints must be a list of >= 8 non-empty strings")
    else:
        if len(set(cps)) != len(cps):
            err(cid, "checkpoints must be distinct")
        for cp in cps:
            if text.count(cp) != 1:
                err(cid, "checkpoint must occur exactly once in text")
                break
    if e["language"] not in ("ja", "en"):
        err(cid, "expect.language must be ja|en")
    if "reviewAcceptable" in e and not isinstance(e["reviewAcceptable"], bool):
        err(cid, "reviewAcceptable must be bool")
    corrections = e.get("corrections", [])
    if not isinstance(corrections, list):
        err(cid, "corrections must be a list")
        return
    seen = set()
    for correction in corrections:
        if (not isinstance(correction, dict) or set(correction) != {"old", "new"}
                or not all(isinstance(v, str) and v.strip() for v in correction.values())):
            err(cid, "correction must have non-empty old/new strings")
            continue
        old, new = correction["old"], correction["new"]
        if old == new or old in new or new in old:
            err(cid, "correction values must be distinct and non-overlapping")
        if text.count(old) != 1 or text.count(new) != 1:
            err(cid, "correction old/new must each occur exactly once in text")
        if old in seen or new in seen:
            err(cid, "correction values must be unique")
        seen.update((old, new))
        if isinstance(cps, list) and any(old in cp for cp in cps if isinstance(cp, str)):
            err(cid, "retracted facts must not be checkpoints")
    if cid in ("LG-017", "LG-018", "LG-019"):
        if not e.get("reviewAcceptable") or len(corrections) != (1 if cid == "LG-019" else 6):
            err(cid, "QA-12/13 requires reviewAcceptable and the specified correction count")
    if cid == "LG-013" and is_str_list(cps, True):
        if e["language"] != "en" or any(not re.fullmatch(r"T-\d{4}", cp) for cp in cps):
            err(cid, "translation checkpoints must be language-neutral codes; output language en")


VALIDATORS = {"cleanup": v_cleanup, "routing": v_routing, "generation": v_generation,
              "optimization": v_optimization, "long": v_long}

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
URL_RE = re.compile(r"https?://([A-Za-z0-9.-]+)")
PHONE_RE = re.compile(r"(?<!\d)0\d{1,4}-\d{1,4}-\d{3,4}(?!\d)|\+\d{1,3}[ -]\d{2,4}[ -]\d{3,4}[ -]\d{3,4}")


def hygiene(cid, raw):
    for m in EMAIL_RE.finditer(raw):
        if not (m.group(1) == "example.com" or m.group(1).endswith(".example.com")):
            err(cid, "email domain must be example.com")
    for m in URL_RE.finditer(raw):
        h = m.group(1)
        if not (h == "example.com" or h.endswith(".example.com")):
            err(cid, "URL host must be example.com")
    if PHONE_RE.search(raw):
        err(cid, "phone-number-like string found")
    if re.search(r"/Users/|/Volumes/|~/Library", raw):
        err(cid, "local path found")


def duplicate_inputs(directories, cleanup_transcripts=False):
    """Return ids only; routing identity includes targetSource as used by the app."""
    seen, duplicates = {}, []
    for directory in directories:
        for stem in ("cleanup", "routing", "generation", "optimization", "long"):
            path = os.path.join(directory, stem + ".jsonl")
            if not os.path.isfile(path):
                continue
            try:
                with open(path, encoding="utf-8") as stream:
                    lines = stream.read().splitlines()
            except (OSError, UnicodeError):
                continue  # The selected profile's schema pass reports unreadable inputs.
            for raw in lines:
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue  # Schema validation reports malformed rows without echoing bodies.
                if not isinstance(row, dict) or not isinstance(row.get("input"), dict) or not isinstance(row.get("id"), str):
                    continue
                key = (stem, json.dumps(row["input"], sort_keys=True, ensure_ascii=False))
                if cleanup_transcripts and stem == "cleanup" and isinstance(row["input"].get("transcript"), str):
                    key = (stem, row["input"]["transcript"])
                if key in seen and seen[key][0] != directory:
                    duplicates.append((seen[key][1], row["id"]))
                else:
                    seen[key] = (directory, row["id"])
    return duplicates


def parse_args(argv):
    holdout2, cases_dir, rest = False, None, list(argv)
    while rest:
        a = rest.pop(0)
        if a == "--holdout2":
            holdout2 = True
        elif a == "--dir" and rest:
            cases_dir = rest.pop(0)
        else:
            print("usage: validate_cases.py [--dir <path>] [--holdout2]", file=sys.stderr)
            sys.exit(2)
    return holdout2, cases_dir


def main():
    ap = argparse.ArgumentParser(description="Validate ItJustTalks evaluation cases.")
    ap.add_argument("--dir", default=None, help="directory holding the *.jsonl files")
    profiles = ap.add_mutually_exclusive_group()
    profiles.add_argument("--normal-loop", action="store_true", help="validate NM/H5C normal-mode cleanup development set")
    profiles.add_argument("--accuracy", action="store_true", help="validate AC cleanup accuracy set")
    profiles.add_argument("--holdout", action="store_true", help="validate the holdout set (cleanup + routing, HC/HR ids)")
    profiles.add_argument("--holdout2", action="store_true", help="validate the second holdout set (H2C/H2R ids)")
    profiles.add_argument("--holdout3", action="store_true", help="validate the third holdout set (H3C ids)")
    profiles.add_argument("--holdout4", action="store_true", help="validate the sealed independent holdout set")
    args = ap.parse_args()
    holdout2 = args.holdout2
    holdout3 = args.holdout3
    tags = HOLDOUT3_TAGS if holdout3 else HOLDOUT2_TAGS if holdout2 else ()
    if args.normal_loop:
        files = NORMAL_LOOP_FILES
        cases_dir = os.path.abspath(args.dir or os.path.join(HERE, "normal-loop"))
    elif args.accuracy:
        files = ACCURACY_FILES
        cases_dir = os.path.abspath(args.dir or os.path.join(HERE, "accuracy"))
    elif args.holdout:
        files = HOLDOUT_FILES
        cases_dir = os.path.abspath(args.dir or os.path.join(HERE, "holdout"))
    elif args.holdout4:
        files = FILES_HOLDOUT4
        cases_dir = os.path.abspath(args.dir or os.path.join(HERE, "holdout4"))
    elif holdout3:
        files = FILES_HOLDOUT3
        cases_dir = os.path.abspath(args.dir or os.path.join(HERE, "holdout3"))
    elif holdout2:
        files = FILES_HOLDOUT2
        cases_dir = os.path.abspath(args.dir or os.path.join(HERE, "holdout2"))
    else:
        files = FILES
        cases_dir = os.path.abspath(args.dir or CASES_DIR)
    # Compare the selected set with the other independent evaluation sets.
    sealed_dir = os.path.realpath(os.path.join(HERE, "holdout4"))
    if not args.holdout4 and os.path.realpath(cases_dir) == sealed_dir:
        print("holdout4 requires --holdout4", file=sys.stderr)
        return 1
    siblings = [os.path.join(HERE, name) for name in ("cases", "holdout", "holdout2", "holdout3", "accuracy", "normal-loop")]
    if args.holdout4:
        siblings.append(os.path.join(HERE, "holdout4"))
    directories = [cases_dir] + [d for d in siblings if os.path.realpath(d) != os.path.realpath(cases_dir)]
    for first, second in duplicate_inputs(directories, cleanup_transcripts=args.normal_loop):
        err(second, "cross-set duplicate input of " + first)
    summary = {}
    overall = {"ja": 0, "en": 0, "mixed": 0}
    all_ids = set()
    for stem, (category, prefix, want) in files.items():
        path = os.path.join(cases_dir, stem + ".jsonl")
        cov = {}

        class Cov(dict):
            def __missing__(self, k):
                return 0
        cov = Cov()
        langs = {"ja": 0, "en": 0, "mixed": 0}
        n = 0
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().split("\n")
        except OSError as ex:
            err(stem, "cannot read %s: %s" % (path, ex))
            continue
        if lines and lines[-1] == "":
            lines.pop()
        else:
            err(stem, "file must end with a newline")
        for ln, raw in enumerate(lines, 1):
            where = "%s:%d" % (stem, ln)
            if not raw.strip():
                err(where, "blank line")
                continue
            try:
                c = json.loads(raw)
            except ValueError as ex:
                err(where, "invalid JSON (%s)" % ex)
                continue
            n += 1
            if not isinstance(c, dict) or set(c) != TOP_KEYS:
                err(where, "top-level keys must be exactly %s" % sorted(TOP_KEYS))
                continue
            cid = c["id"]
            if not isinstance(cid, str) or not re.fullmatch(prefix + r"-\d{3}", cid):
                err(where, "id must match %s-NNN" % prefix)
                continue
            if cid in all_ids:
                err(cid, "duplicate id")
            all_ids.add(cid)
            sequential_prefix = cid.rsplit("-", 1)[0] if args.normal_loop else prefix
            if cid != "%s-%03d" % (sequential_prefix, ln):
                err(cid, "ids must be sequential from 001 in file order")
            if c["category"] != category:
                err(cid, "category must be %s" % category)
            if c["lang"] not in LANGS:
                err(cid, "lang enum")
            else:
                langs[c["lang"]] += 1
            if not isinstance(c["purpose"], str) or not (3 <= len(c["purpose"]) <= 200):
                err(cid, "purpose must be a short string")
            if not isinstance(c["critical"], bool):
                err(cid, "critical must be bool")
            hygiene(cid, raw)
            VALIDATORS[category](c, cov)
            if tags and isinstance(c["purpose"], str):
                for tag in tags:
                    if tag in c["purpose"].lower():
                        cov["tag:" + tag] += 1
        if n != want:
            err(stem, "expected %d cases, found %d" % (want, n))
        minimums = {
            "cleanup": {"handsFree": 10, "noAnswer": 8, "corrections": 8, "dictionary": 8, "customInstruction": 6},
            "routing": {"injection": 10, "requires_web": 8, "web_lookalike": 4, "explicit_intent": 10,
                        "conflicting_or_ambiguous": 6, "target_null": 6},
            "generation": {"task:%s" % t: 3 for t in GENERATING},
            "optimization": {"permission_flagged": 6, "long_drafts": 3},
            "long": {"dur:60": 1, "dur:180": 1, "dur:300": 1, "dur:600": 1,
                     "chars:3000": 1, "chars:6000": 1, "chars:12000": 1},
        }[category]
        if args.accuracy or args.normal_loop:
            minimums = {}
        elif args.holdout:
            minimums = {
                "cleanup": {"handsFree": 10, "noAnswer_request_kept": 6, "corrections": 12, "correction_wired": 12,
                            "filler_heavy": 6, "numeric_negation": 6},
                "routing": {"injection": 6, "requires_web": 6, "web_lookalike": 4, "target_null": 6,
                            "mixed_edit_question": 6, "summ_extract_content": 3, "summ_extract_answer": 3,
                            "explicit_show": 4, "explicit_insert": 4, "conflicting_or_ambiguous": 4},
            }[category]
            if category == "cleanup":
                cues = sum(1 for cue in CORRECTION_CUES if cov["cue:" + cue] > 0)
                if cues < 7:
                    err(stem, "correction cues used = %d < required 7" % cues)
                if cov["correction_unwired"]:
                    err(stem, "%d correction(s) without old in mustNotContain / new in mustContain" % cov["correction_unwired"])
            total_n = sum(langs.values())
            for lg, lo, hi in HOLDOUT_LANG_SHARE:
                if total_n and not lo <= 100.0 * langs[lg] / total_n <= hi:
                    err(stem, "language share %s = %.1f%% outside %d-%d%%" % (lg, 100.0 * langs[lg] / total_n, lo, hi))
        elif args.holdout4:
            minimums = MINIMUMS_HOLDOUT4[category].copy()
            for lang in LANGS:
                if langs[lang] == 0:
                    err(stem, "missing language " + lang)
        elif holdout3:
            minimums = MINIMUMS_HOLDOUT3[category]
            if cov["correction_unwired"]:
                err(stem, "%d correction(s) without old in mustNotContain / new in mustContain" % cov["correction_unwired"])
            total_n = sum(langs.values())
            for lg, lo, hi in HOLDOUT3_LANG_SHARE:
                if total_n and not lo <= 100.0 * langs[lg] / total_n <= hi:
                    err(stem, "language share %s = %.1f%% outside %d-%d%%" % (lg, 100.0 * langs[lg] / total_n, lo, hi))
        elif holdout2:
            minimums = MINIMUMS_HOLDOUT2[category]
        if category == "generation":
            minimums["translate_to_en"] = 2
            minimums["translate_to_ja"] = 2
        for key, mn in minimums.items():
            if cov[key] < mn:
                err(stem, "coverage '%s' = %d < required %d" % (key, cov[key], mn))
        for k in langs:
            overall[k] += langs[k]
        summary[stem] = (n, want, langs, {k: cov[k] for k in minimums})
    total = sum(overall.values())
    if total and args.holdout4:
        for lang, lo, hi in (("ja", 40, 70), ("en", 10, 40), ("mixed", 10, 30)):
            if not lo <= 100.0 * overall[lang] / total <= hi:
                err("overall", "language share out of range: " + lang)
    if total and not (args.holdout or holdout3 or args.holdout4 or args.accuracy or args.normal_loop):
        share = {k: 100.0 * v / total for k, v in overall.items()}
        for k, lo, hi in (("ja", 52, 68), ("en", 12, 28), ("mixed", 12, 28)):
            if not lo <= share[k] <= hi:
                err("overall", "language share %s = %.1f%% outside %d-%d%%" % (k, share[k], lo, hi))
    print("File                 cases  ja  en  mixed")
    for stem, (n, want, langs, cov) in summary.items():
        print("%-20s %3d/%-3d %3d %3d %4d" % (stem + ".jsonl", n, want, langs["ja"], langs["en"], langs["mixed"]))
        print("    coverage: " + ", ".join("%s=%d" % kv for kv in cov.items()))
    if total:
        print("TOTAL                %3d     %3d %3d %4d   (ja %.0f%% / en %.0f%% / mixed %.0f%%)"
              % (total, overall["ja"], overall["en"], overall["mixed"],
                 100.0 * overall["ja"] / total, 100.0 * overall["en"] / total, 100.0 * overall["mixed"] / total))
    if errors:
        print("\nFAIL: %d problem(s)" % len(errors))
        for m in errors[:100]:
            print("  - " + m)
        return 1
    print("\nOK: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
