#!/usr/bin/env python3
"""
Audit `verify(mock, never()).m(...)` assertions for the two ways they go blind.

CHECK A -- UNREACHABLE TARGET (the "vacuous" check).
  The never()-ed method is one the class under test never calls on ANY path, so the assertion is
  satisfied by every implementation and is unprovable by mutation (no operator ADDS a call).
  Triage before acting -- three very different situations hide here:
    (1) NOISE: wrong layer/collaborator, guards nothing. -> real finding; delete or retarget.
    (2) DOMINATED BUT HARMLESS: an old sibling variant kept after a migration, where a PAIRED
        POSITIVE assertion in the same test already fails on the revert. -> not a finding, leave it.
    (3) UNPROVABLE BUT NON-REDUNDANT: a real hazard nothing else covers. -> judgement call.
  Check for a paired positive assertion before calling anything a defect.

CHECK B -- NULL-BLIND MATCHERS (added after SBDEV-3102 batch 1; check A is blind to this).
  Mockito's type-specific matchers EXCLUDE nulls: anyString(), anyList(), and -- easy to miss --
  any(Foo.class) too, which has been null-excluding since Mockito 2. Only bare any() and
  nullable(...) match null. So a never() written with type-specific matchers cannot observe an
  invocation that passes null in that position, and passes while the guard it is named after is
  fully reverted.

  Measured instance: StockChangeNotificationServiceUnitTest asserted
      verify(oms, never()).sendAfterCommit(anyString(), anyString(), anyString())
  Reverting the catch/return guard let the call through with a NULL payload. anyString() could not
  match it, so never() stayed satisfied and the class stayed GREEN. Widening to any() kills it.

  KEY ASYMMETRY: for a never(), widening matchers is ALWAYS strictly stronger -- never() means "no
  invocation matching this", so enlarging the match set can only make it stricter. There is no
  trade-off, unlike a positive verify() where a wide matcher loses precision. Hence: in a never(),
  prefer bare any(). A type-specific matcher there is a latent blind spot with no upside.

  !! TWO EXCEPTIONS, both measured on 2026-08-28 by widening all 328 flagged sites on develop and
  running the suite (5680 tests). Bare any() is NOT a universal replacement:

  B1. PRIMITIVE PARAMETERS ARE NOT A BLIND SPOT AND MUST NOT BE WIDENED.
      anyInt/anyLong/anyBoolean/anyDouble/anyFloat/anyShort/anyByte/anyChar match BOTH the
      primitive and the boxed form. Where the parameter is the PRIMITIVE (long, boolean, ...) a
      null can never be passed, so there is nothing to be blind to -- and bare any() returns null,
      which NPEs at the unboxing site:
          NullPointerException: Cannot invoke "java.lang.Long.longValue()" because the return
          value of "org.mockito.ArgumentMatchers.any()" is null
      Measured: widening these produced 42 NPEs plus 100 cascade errors (InvalidUseOfMatchers /
      UnfinishedVerification from the matcher left on the stack) across 58 classes. These matchers
      are reported separately below as [B?] -- resolve the parameter's declared type first. Widen
      ONLY if it is the boxed type; leave it alone if it is primitive.

  B2. OVERLOADED METHODS NEED nullable(X.class), NOT any().
      Bare any() erases the type that Java's overload resolution needs. Measured: exactly 1 site in
      328, ParcelMonitorViewServiceUnitTest:674 on UnitloadService.createUnitload, which has two
      5-arg overloads -> "reference to createUnitload is ambiguous". nullable(X.class) matches null
      AND keeps the type, so it is the correct widening wherever any() will not compile.

  Also note: 9 of the 78 flagged classes import anyString/anyLong but NOT bare any, so a textual
  widen does not compile until `import static org.mockito.ArgumentMatchers.any;` is added.

KNOWN REMAINING BLIND SPOTS (measured 2026-08-28; benign on develop today, but do not claim
full coverage without checking these by hand):
  * fully-qualified `org.mockito.Mockito.never()` -- the pattern below wants a bare `never()`.
    Live examples: PutawayConfigServiceUnitTest:394,396,423,434 (their matchers are already
    nullable(...)/no-arg, so nothing is hidden there today).
  * `MockedStatic.verify(lambda, never())` -- a different call shape entirely, not mock.method(...).
    Live examples: OmsNotificationServiceUnitTest:314,339 (already bare any()). 21 files use
    MockedStatic, so this shape recurs and will need its own pass if it ever carries a matcher.
Confirmed ABSENT repo-wide, so not handled on purpose: BDDMockito `should(never())`, `times(0)`,
`atMost(0)`, and non-identifier mock references.

Usage: never-audit.py <TestFile.java> [<ClassUnderTest.java>]
       (omit the second arg to run CHECK B only)
Exit 1 if anything is flagged.
"""
import re, sys

# Always a reference type -> null is genuinely possible -> genuinely blind -> safe to widen.
REF_BLIND = re.compile(r'\b(any(String|List|Set|Map|Collection|Iterable)\(\)|any\([A-Za-z_][\w.]*\.class\))')
# Matches primitive OR boxed. Blind only if the declared parameter is the BOXED type; if it is the
# primitive, there is no null hazard and bare any() NPEs at unboxing. Needs the signature to decide.
PRIM_CAPABLE = re.compile(r'\bany(Int|Long|Double|Float|Short|Byte|Char|Boolean)\(\)')


def strip_comment(l):
    st = l.strip()
    return None if st.startswith('//') or st.startswith('*') or st.startswith('/*') else l


MOCK_DECL = [
    r'(?:@Mock|@MockBean|@Spy)[^;]*?\b([A-Z]\w*)(?:<[^;]*?>)?\s+%s\s*[;=]',
    r'\b([A-Z]\w*)(?:<[^>]*>)?\s+%s\s*=\s*mock\(',
    r'\b([A-Z]\w*)(?:<[^>]*>)?\s+%s\s*;',
]


def _strip_java_comments(src):
    """Remove // and /* */ comments, preserving string literals.

    CHECK A's probes must never see comment text. Measured 2026-08-29: running the ownership gate
    against raw source made FOUR live guards look like unreachable targets, because the
    collaborator's type name appeared ONLY in a javadoc or a `//` note -- e.g. FileExportService is
    named in CycleCountController exclusively in two comments, while the real call path runs
    CycleCountController -> cyclecountService.exportCycleCounts -> CyclecountService. That is
    verbatim the false positive this gate exists to prevent.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"' or c == "'":
            q = c
            out.append(c)
            i += 1
            while i < n and src[i] != q:
                if src[i] == '\\':
                    out.append(src[i]); i += 1
                    if i < n: out.append(src[i]); i += 1
                    continue
                out.append(src[i]); i += 1
            if i < n: out.append(src[i]); i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n': i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'): i += 1
            i += 2
            continue
        out.append(c); i += 1
    return ''.join(out)


def _mock_type(test_text, mock):
    """Declared type of a mock variable, or None. Handles @Mock fields and `T x = mock(T.class)`."""
    for pat in MOCK_DECL:
        m = re.search(pat % re.escape(mock), test_text, re.S)
        if m:
            return m.group(1)
    return None


def _span_end(text, open_paren):
    """Index just past the ')' balancing the '(' at open_paren. -1 if unbalanced."""
    depth = 0
    i = open_paren
    while i < len(text):
        ch = text[i]
        if ch == '"':                       # skip string literals
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def main():
    test = sys.argv[1]
    svc = _strip_java_comments(open(sys.argv[2]).read()) if len(sys.argv) > 2 else None
    text = open(test).read()
    test_text = text
    a_hits, b_hits, q_hits, unpaired = [], [], [], set()
    # Scan the WHOLE FILE, not line by line. A per-line regex cannot see a never() whose `.method(`
    # wraps onto the line after `never())` -- the match simply fails, so the site is invisible to
    # CHECK A, CHECK B and [B?] alike. Measured 2026-08-28 on develop: a line-anchored scan saw 796
    # sites; the real total is 824, so 28 were audited by nothing. (The earlier "46 of 796 wrap"
    # figure was itself computed against that blind denominator.) `\s*` already spans newlines, so
    # the same pattern works on the full text; the argument list is then bounded by paren balance
    # rather than by a `);` search, which a nested call like eq(f(x)) would otherwise cut short.
    for m in re.finditer(r'verify\(\s*(\w+)\s*,\s*never\(\)\s*\)\s*\.\s*(\w+)\(', text):
        mock, meth = m.group(1), m.group(2)
        i = text.count('\n', 0, m.start()) + 1
        line_start = text.rfind('\n', 0, m.start()) + 1
        if strip_comment(text[line_start:m.start()] + 'x') is None:
            continue
        end = _span_end(text, m.end() - 1)
        if end < 0:
            continue
        args = text[m.end():end]
        # CHECK A is only sound when the paired class actually OWNS this collaborator. Name-based
        # test->production pairing is too crude for delegation chains: CycleCountControllerUnitTest
        # pairs to CycleCountController, but asserts never() on fileExportService.getExcelFile, which
        # CyclecountService calls -- the controller never does, so a naive check called it VACUOUS. It
        # is not; the pairing was wrong. Measured: that class of false positive dominated the first
        # sweep, so require the collaborator to appear in the paired class before trusting CHECK A.
        if svc is not None:
            # Resolve the mock to its declared TYPE, then ask whether the class under test calls
            # <meth> on ANY field of that type. Matching the test's mock VARIABLE NAME against the
            # production source (the previous rule) assumes the two names agree, and they need not:
            # measured 2026-08-29, IdempotencyFilterUnitTest mocks `RestIdempotencyService service`
            # while IdempotencyFilter calls it through a field named `idempotencyService`, so three
            # live, killable guards were reported as unreachable targets. A chained call is missed
            # the same way -- KeycloakService reaches delete() via `getUsersResource().delete(...)`,
            # never through a field at all. Four false [A] out of 95 came from these two shapes.
            mtype = _mock_type(test_text, mock)
            if mtype is None:
                unpaired.add(mock)         # cannot resolve the type -> A unknown, do not guess
            elif not re.search(r'\b' + re.escape(mtype) + r'\b', svc):
                unpaired.add(mock)         # collaborator not owned by the paired class -> A unknown
            else:
                fields = set(re.findall(r'\b' + re.escape(mtype) + r'(?:<[^>]*>)?\s+(\w+)\s*[;,)=]', svc))
                # A call site is `field.meth(` OR a method reference `field::meth` / `Type::meth`.
                # Measured 2026-08-29: SkuPutawayQueryService reaches findById only as
                # `.flatMap(clientRepository::findById)`, so a paren-only probe called a live guard
                # unreachable. Stripping comments exposed this -- a javadoc had been masking it.
                calls = any(re.search(r'\b' + re.escape(f) + r'\s*(?:\.\s*' + re.escape(meth)
                                      + r'\s*\(|::\s*' + re.escape(meth) + r'\b)', svc)
                            for f in fields)
                calls = calls or bool(re.search(r'\b' + re.escape(mtype) + r'\s*::\s*'
                                                + re.escape(meth) + r'\b', svc))
                # `).meth(` -- reached through a chain such as getUsersResource().delete(...)
                chained = re.search(r'\)\s*\.\s*' + re.escape(meth) + r'\s*\(', svc)
                if not calls and not chained:
                    a_hits.append((i, mock, meth))
                    continue               # unreachable target dominates; B is moot
        ref = sorted({b[0] for b in REF_BLIND.findall(args)})
        prim = sorted({'any%s()' % b for b in PRIM_CAPABLE.findall(args)})
        if ref:
            b_hits.append((i, mock, meth, ref))
        if prim:
            q_hits.append((i, mock, meth, prim))
    name = test.split('/')[-1]
    if a_hits:
        print(f"  [A] UNREACHABLE TARGET  ({name})")
        for i, mock, meth in a_hits:
            print(f"      :{i:<6} {mock}.{meth}  -- class under test never calls {meth}")
    if b_hits:
        print(f"  [B] NULL-BLIND MATCHERS in never()  ({name})")
        for i, mock, meth, bl in b_hits:
            print(f"      :{i:<6} {mock}.{meth}  -- {', '.join(bl)} cannot match null; "
                  f"widen to any() (nullable(X.class) if the method is overloaded)")
    if q_hits:
        print(f"  [B?] PRIMITIVE-CAPABLE MATCHERS in never() -- CHECK THE SIGNATURE  ({name})")
        for i, mock, meth, bl in q_hits:
            print(f"      :{i:<6} {mock}.{meth}  -- {', '.join(bl)}: blind ONLY if the parameter is "
                  f"boxed. If it is primitive there is no null hazard and any() will NPE. Do not widen blind.")
    if unpaired:
        print(f"  [?] CHECK A SKIPPED for collaborators the paired class does not own ({name}): "
              + ", ".join(sorted(unpaired)))
    if not a_hits and not b_hits and not q_hits:
        print(f"  clean: {name}")
    return 1 if (a_hits or b_hits or q_hits) else 0


sys.exit(main())
