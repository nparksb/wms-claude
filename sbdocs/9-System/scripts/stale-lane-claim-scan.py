#!/usr/bin/env python3
"""Find test-tree comments that assert the Testcontainers / @SpringBootTest lane cannot boot.

SBDEV-3257. SBDEV-3239 made the wms2-api integration lane runnable, and comments across the test
tree went on telling the reader it was broken — many of them as the *stated justification* for using
a weaker unit-level substitute. This script re-derives that population so the next reader measures
instead of guessing.

WHY THIS IS NOT A GREP
----------------------
A line-oriented grep is the WRONG SHAPE for this population and fails silently.

Measured 2026-09-08 on wms2-api @ 0dfcefc6, with the units stated because three different numbers
were quoted for this population before anyone reconciled them:

    grep -rnE '(@SpringBootTest|Testcontainers)[^*]{0,80}(is down|cannot boot)' src/test
        -> 9 matching LINES
    this scanner, same tree
        -> 26 comment BLOCKS across 21 FILES

The raw *sentence* count is higher again (~36), because several blocks state the claim more than
once — so a line count, a block count and a sentence count are three different figures and must
never be compared to each other.

The grep's failure is not just undercounting: its positive control FAILED. It returned nothing for
BaseControllerUnitTest, a claim already read by eye. Cause: javadoc WRAPS the claim across lines, so
the subject sits on one line and the predicate on the next, and no line-oriented pattern can span
them. The 9 looked exactly like a real answer.

So this scanner joins each comment block (a /* */ span, or a run of // lines) into one flat string
before matching, and it REFUSES TO REPORT unless all four controls below pass. A zero from a broken
instrument and a true zero are indistinguishable; the controls are the only thing separating them.

USAGE
    python3 stale-lane-claim-scan.py <repo-root>          # e.g. v2/wms2-api
    python3 stale-lane-claim-scan.py <repo-root> --verbose

EXIT CODES
    0  all four controls passed, no stale claims found
    1  all four controls passed, candidates found (they are printed)
    2  A CONTROL FAILED — the instrument is broken; any count it prints is meaningless

NEGATIVE-TESTING THIS SCRIPT (do it after ANY edit to a pattern or a collector)
    Sabotage each mechanism in a scratch copy and confirm exit 2 every time:
      1. joining:   flat = re.sub(...)  ->  flat = txt
      2. // spans:  the second `spans +=` block  ->  spans += []
      3. claim:     PREDICATE  ->  r"(zzz_never_matches"
      4. TODO:      DEAD_TODO  ->  re.compile(r"zzz_never_matches")
    All four fired when last run (2026-09-08). Assert the anchor is unique before substituting, or
    the negative test is vacuous and proves nothing.

WHAT IT CANNOT SEE (state the blind spots, do not imply a closed set)
    * A claim phrased in words this pattern does not carry. The pattern list below is a sample of
      observed phrasings, NOT a proof that no other phrasing exists.
    * A claim in a @DisplayName, an assertion message, or any Java string rather than a comment —
      only comments are scanned. (SBDEV-3239 found a real one in a @Disabled reason string.)
    * A claim that is TRUE. Several matches are legitimate history ("could not boot when this was
      written"). This tool locates candidates; a human classifies them. It is not a build gate and
      must not become one.
"""
import os
import re
import sys

# Observed phrasings, not an exhaustive set — see "WHAT IT CANNOT SEE" above.
SUBJECT = (r"(@SpringBootTest|SpringBootTest|Testcontainers|IT harness|test harness|PG lane"
           r"|Postgres(ql)? lane|v2 harness|integration lane|context-load lane)")
PREDICATE = (r"(lane is down|is down|cannot boot|can(?:not|'t) boot|does not boot|could not boot"
             r"|is blocked|blocked by|out of action|is broken|not runnable|never boots?)")

CLAIM_FWD = re.compile(SUBJECT + r"[^.]{0,140}?" + PREDICATE, re.I)
CLAIM_REV = re.compile(PREDICATE + r"[^.]{0,140}?" + SUBJECT, re.I)
DEAD_TODO = re.compile(r"TODO\s*\(?\s*SBDEV-(2217|3239)", re.I)
ENABLE_WHEN = re.compile(r"(once|when)[^.]{0,60}SBDEV-2217[^.]{0,40}(lands|boots|restored)", re.I)

# ---------------------------------------------------------------------------------------------
# FOUR CONTROLS. Each one closes a way this scanner can report a plausible number while broken.
# All four must pass or the tool exits 2 and reports nothing. Independent review (SBDEV-3257)
# found controls 2-4 missing after the first version shipped with only control 1.
# ---------------------------------------------------------------------------------------------
#
# CONTROL 1 — javadoc block joining. This phrase sits in BaseControllerUnitTest's javadoc and is
# SPLIT BY A LINE BREAK in the source ("...exercised in this\n * repository."), so it matches only
# if /* */ joining works. A control on a phrase that fits on one line would pass with joining
# broken and prove nothing.
#
# ⚠ Chosen after a first attempt failed BOTH ways. It was `standaloneSetup installs no
# method-security advisor` — which (a) sat entirely on one line, so it tested nothing, and (b) did
# not match anyway, because the source reads `{@code standaloneSetup}` and the closing brace broke
# the `\s+`. L-5: the phrase's line-wrap is now ENFORCED, not just intended — control 1 requires it
# to match the flattened text and NOT the raw text, so a future rewrap that puts it on one line
# fails loudly instead of silently ceasing to test joining.
CONTROL_FILE = "BaseControllerUnitTest.java"
CONTROL_PHRASE = re.compile(r"exercised\s+in\s+this\s+repository", re.I)

# CONTROL 2 — the `//`-run collector. Control 1 exercises only the /* */ collector, so killing the
# `//` collector left the control green while losing 8 real blocks (measured on origin/develop:
# 26 -> 18, control still PASSED). Keyed on the span's ORIGIN, because a phrase-only control failed:
# the phrase first chosen here also appears inside a /* */ block in the same file, so the control
# passed with the // collector dead.
CONTROL_LINE_COMMENT_FILE = "UserControllerUnitTest.java"
# Must STRADDLE a line break inside the // run (…installs no method\n    // security advisor…),
# for the same reason as control 1. The first phrase tried here sat on one line and so tested
# collection but not joining.
CONTROL_LINE_COMMENT_PHRASE = re.compile(r"installs\s+no\s+method\s+security\s+advisor", re.I)

# CONTROL 3/4 — the MATCHERS. Controls 1-2 prove only that text reaches the regexes; they say
# nothing about whether the regexes still match a claim. A typo in SUBJECT or PREDICATE — the two
# strings the docstring actively invites editing — silently converts this tool into
# "0 across 0 files" with exit 0, i.e. a clean bill of health. Same pattern as the control in
# PostgresTestHarnessPinTest ("if it does not, every other file scanning clean is an artefact of a
# broken regex").
MATCHER_CONTROL_CLAIM = "the @SpringBootTest lane is down (SBDEV-2217)"
MATCHER_CONTROL_TODO = "TODO(SBDEV-2217): enable once the v2 IT harness boots"


def tags_for(flat):
    """The detector. Factored out so CONTROL 5 exercises the SAME logic as the real scan —
    a self-test that re-implements the matching would prove nothing about the scan."""
    tags = []
    if CLAIM_FWD.search(flat) or CLAIM_REV.search(flat):
        tags.append("LANE-CLAIM")
    if DEAD_TODO.search(flat):
        tags.append("TODO-SHIPPED-TICKET")
    if ENABLE_WHEN.search(flat):
        tags.append("ENABLE-WHEN-2217")
    return tags


# CONTROL 5 — END-TO-END, on synthetic fixtures, covering what 1-4 together still miss.
#
# ⚠ Why this exists (SBDEV-3257 delta review). Controls 1-4 all passed while the tool reported
# "0 across 0 files, exit 0" — a clean bill of health — on the FULL pre-fix population. The break:
# tighten the subject->predicate gap from [^.]{0,140}? to {0,1}. Controls 3/4 could not see it
# because their control literal ("the @SpringBootTest lane is down (SBDEV-2217)") has subject and
# predicate one space apart, so it still matched. Real claims put 20-100 chars between them.
#
# So these fixtures deliberately use a WIDE gap and a LINE BREAK, and there is one per collector.
SELF_TEST_BLOCK = """/**
 * Preamble that has nothing to do with anything, and then the claim itself: the
 * {@code @SpringBootTest} lane, which nobody has looked at in months, is down (SBDEV-2217).
 */"""

SELF_TEST_LINE = """    // Some prose about why these are direct calls, and then the claim: the Testcontainers
    // harness that would otherwise cover this cannot boot (SBDEV-2217), so we do it cheaply.
    // TODO(SBDEV-2217): enable once the v2 IT harness boots
"""


def self_test():
    """Return a list of failure strings; empty means CONTROL 5 passed.

    Drives the REAL scan() over synthetic files on disk rather than calling the detector
    directly. That matters: a filter applied at the reporting stage (e.g. only recording
    origin == "block") is invisible to a self-test that calls tags_for() itself, and exactly
    that mutant slipped through an earlier version of this control while it reported PASSED.
    """
    import tempfile
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "src", "test")
        os.makedirs(root)
        with open(os.path.join(root, "SelfTestBlock.java"), "w") as fh:
            fh.write(SELF_TEST_BLOCK + "\nclass SelfTestBlock {}\n")
        with open(os.path.join(root, "SelfTestLine.java"), "w") as fh:
            fh.write("class SelfTestLine {\n" + SELF_TEST_LINE + "}\n")
        hits, _ = scan(root)
    for want_origin, want_tag, label in (
        ("block", "LANE-CLAIM", "javadoc fixture"),
        ("line", "LANE-CLAIM", "// fixture"),
        ("line", "TODO-SHIPPED-TICKET", "// fixture's dead TODO"),
    ):
        if not any(o == want_origin and want_tag in t for _r, _l, t, _f, o in hits):
            fails.append(f"{want_tag} not REPORTED for the {label}")
    return fails


def comment_blocks(src):
    """Yield (line_number, flattened_text) for every comment block in a Java source file."""
    spans = [(m.start(), m.group(0), "block") for m in re.finditer(r"/\*.*?\*/", src, re.S)]
    spans += [(m.start(), m.group(0), "line")
              for m in re.finditer(r"(?:^[ \t]*//.*\n?)+", src, re.M)]
    for off, txt, origin in spans:
        # Strip each line's comment marker BEFORE joining. Order matters: an earlier version
        # collapsed the newline first and only then tried to remove `//`, which left the markers
        # embedded mid-sentence ("installs no method // security advisor"). Claim detection mostly
        # survived that (the gap class [^.] matches "/"), but any pattern needing contiguous words
        # across a line break silently could not match — CONTROL 2 caught it.
        cleaned = [re.sub(r"^\s*(?:/\*+|\*/|\*|//)\s*", "", ln) for ln in txt.split("\n")]
        flat = re.sub(r"\s+", " ", " ".join(cleaned)).strip()
        flat = re.sub(r"\s*\*/\s*$", "", flat).strip()
        yield src[:off].count("\n") + 1, flat, txt, origin


def scan(test_root):
    hits = []
    ctl = {"file_seen": False, "joined": False, "line_file_seen": False, "line_joined": False,
           "line_spans": 0}
    for dirpath, _, filenames in os.walk(test_root):
        for filename in sorted(filenames):
            if not filename.endswith(".java"):
                continue
            path = os.path.join(dirpath, filename)
            with open(path, errors="ignore") as handle:
                src = handle.read()
            for line, flat, raw, origin in comment_blocks(src):
                if origin == "line":
                    ctl["line_spans"] += 1
                if filename == CONTROL_FILE:
                    ctl["file_seen"] = True
                    # Must match JOINED text and NOT raw text: that is what proves the phrase
                    # actually spans a line break, so this control keeps testing joining even
                    # after someone rewraps the javadoc (L-5).
                    if CONTROL_PHRASE.search(flat) and not CONTROL_PHRASE.search(raw):
                        ctl["joined"] = True
                # CONTROL 2 must be keyed on the span's ORIGIN, not on where a phrase happens to
                # live: the first attempt used a phrase in UserControllerUnitTest that ALSO appears
                # inside a /* */ block (a javadoc there swallows following // lines), so killing the
                # // collector left the control green — the negative test caught it.
                if filename == CONTROL_LINE_COMMENT_FILE and origin == "line":
                    ctl["line_file_seen"] = True
                    # flat-and-not-raw, same as control 1: proves the // run is actually being
                    # JOINED, not merely collected. Dropping the `+` from the // regex leaves
                    # single-line spans that still satisfy a collected-only check.
                    if (CONTROL_LINE_COMMENT_PHRASE.search(flat)
                            and not CONTROL_LINE_COMMENT_PHRASE.search(raw)):
                        ctl["line_joined"] = True
                tags = tags_for(flat)
                if tags:
                    hits.append((os.path.relpath(path, test_root), line, tags, flat, origin))
    return hits, ctl


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    repo_root = sys.argv[1]
    verbose = "--verbose" in sys.argv
    test_root = os.path.join(repo_root, "src", "test")
    if not os.path.isdir(test_root):
        print(f"FAIL: {test_root} is not a directory. Pass the sub-repo root, e.g. v2/wms2-api.")
        return 2

    # CONTROL 5 first: it needs no filesystem and it is the broadest — collectors, matchers and
    # gap width end to end. If it fails, nothing else is worth running.
    fails = self_test()
    if fails:
        print("CONTROL 5 FAILED (end-to-end self-test). The detector no longer finds a claim in a\n"
              "synthetic fixture that definitely contains one:")
        for f in fails:
            print("  - " + f)
        print("Any count from this run is meaningless. Do NOT read a zero as a clean tree — a\n"
              "narrowed gap quantifier produced exactly that while controls 1-4 stayed green.")
        return 2

    # CONTROLS 3/4: they need no filesystem, and if the matchers are broken every count is
    # meaningless regardless of what the tree looks like.
    if not (CLAIM_FWD.search(MATCHER_CONTROL_CLAIM) or CLAIM_REV.search(MATCHER_CONTROL_CLAIM)):
        print("CONTROL 3 FAILED: CLAIM_FWD/CLAIM_REV no longer match a string known to BE a stale\n"
              f"claim ({MATCHER_CONTROL_CLAIM!r}). A zero from this run would mean the regex is\n"
              "broken, NOT that the tree is clean. Fix SUBJECT/PREDICATE.")
        return 2
    if not DEAD_TODO.search(MATCHER_CONTROL_TODO):
        print("CONTROL 4 FAILED: DEAD_TODO no longer matches a string known to BE a dead TODO\n"
              f"({MATCHER_CONTROL_TODO!r}). Fix the pattern before trusting any count.")
        return 2

    hits, ctl = scan(test_root)

    if not ctl["file_seen"]:
        print(f"CONTROL 1 FAILED: never opened {CONTROL_FILE}. Wrong root, or the file was renamed.\n"
              f"Any count below would be meaningless. Fix the instrument first.")
        return 2
    if not ctl["joined"]:
        print(f"CONTROL 1 FAILED: found {CONTROL_FILE} but could not match a phrase that must span a\n"
              f"line break in its javadoc (matched joined text but not raw, or not at all).\n"
              f"Either /* */ comment-block joining is broken, or the javadoc was rewrapped so the\n"
              f"phrase now sits on one line and no longer tests joining. Either way a low or zero\n"
              f"count here means nothing — this is the exact failure a grep gave silently.")
        return 2
    if ctl["line_spans"] == 0:
        print("CONTROL 2 FAILED: the `//`-run collector produced ZERO spans across the whole tree.\n"
              "It is dead. Killing it alone drops ~8 real blocks while control 1 stays green.")
        return 2
    if not ctl["line_file_seen"]:
        print(f"CONTROL 2 FAILED: no `//`-origin span found in {CONTROL_LINE_COMMENT_FILE}.")
        return 2
    if not ctl["line_joined"]:
        print(f"CONTROL 2 FAILED: the `//`-run collector matched nothing in "
              f"{CONTROL_LINE_COMMENT_FILE}.\nKilling that collector alone drops ~8 real blocks "
              f"while control 1 stays green. Fix it before trusting any count.")
        return 2

    print("controls 1-5: PASSED (end-to-end self-test, javadoc joining, // joining, "
          "claim matcher, TODO matcher)")
    print(f"candidate comment blocks: {len(hits)} across {len({h[0] for h in hits})} files\n")
    for rel, line, tags, flat, _origin in sorted(hits):
        print(f"{rel}:{line}  [{','.join(tags)}]")
        if verbose:
            print(f"    {flat[:220]}")
    print("\nCandidates, NOT verdicts. A match may be legitimate history "
          '("could not boot when this was written") — read each one.')
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
