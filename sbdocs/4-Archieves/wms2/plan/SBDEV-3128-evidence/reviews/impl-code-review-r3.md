---
ticket: SBDEV-3128
lane: implementation code review r3 (scoped to the r2-fix commit; read-only, independent)
head: 747b9a39
base: ff4cff9b
date: 2026-11-02
verdict: APPROVE
---

# SBDEV-3128: code review r3 (r2 Low fixes)

**head: 747b9a39**. Scope: `git diff ff4cff9b..HEAD`, 3 files, about 50 lines. Method: read-only (`git diff`, `git show HEAD:<path>`). No mvn, no checkout/restore/stash, main checkout not read. Mutation evidence was sanity-checked by reading, not by running.

## Verdict: APPROVE

0 High, 0 Medium, 2 Low (both optional, test-side), 0 open questions. r2 L-1 and L-2 are fixed as claimed.

## Findings

### L-A Low (test): `fiveDecimals_keepScaleFive` asserts the stripped representation, not the observable invariant
```java
assertThat(min.getValue().scale())
    .as("stripping must not drop a real fifth decimal").isEqualTo(5);
```
Jackson gives Double 0.00005, text `"5.0E-5"`, parsed at scale 6, stripped to `5E-5` at scale 5. The test is meaningful: it goes red if the code rounds or truncates to scale 4 (scale 4, value 0.0001), and it goes red with the strip removed (scale 6). But the exact `== 5` ties it to the strip normalisation. An implementation that passed `5.0E-5` through at scale 6 would still be refused by the service's `scale > 4` check, which is the real invariant, and this test would fail it anyway. It also never asserts the VALUE, so a mutant that stripped to the wrong digits at scale 5 would survive.
Fix (optional):
```java
assertThat(min.getValue()).isEqualByComparingTo("0.00005");
assertThat(min.getValue().scale()).as("still over 4, so the service refuses it").isGreaterThan(4);
```
The display name says "(its scale check refuses it)", but the controller test mocks the service. The refusal itself is covered by `FixLocationAssignmentServiceUnitTest.java:1376` (`"24.00001"` gives "at most 4 decimal places"). That is acceptable; the name only describes intent.

### L-B Low (informational, comment precision): the strip also normalises non-Double Numbers with trailing zeros
The comment says a genuine five-decimal input "is refused". That holds for every Double-derived string. A non-Double Number such as `BigDecimal("100000.00000")` (not what Jackson produces here, since USE_BIG_DECIMAL_FOR_FLOATS is off) has scale 5, strips to `1E+5` (scale -5), and is accepted. This is numerically right (the value is an exact integer) and harmless, so no change is needed. Optionally add "Jackson Double text" to the comment so it does not overclaim.

## Check (a): is the strip correct for every Double-derived string?
Double.toString gives either plain decimal (1e-3 <= |x| < 1e7) or `d.dddE±n`. Plain forms have no trailing zeros except `x.0` (scale 1), so they never reach the `scale > 4` branch. E forms: scale = (digits after point) - exponent.

| Input text | Parsed scale | Branch | Result |
|---|---|---|---|
| `5.0E-4` | 5 | strip | `5E-4`, scale 4, accepted (the L-1 case) |
| `1.0E-4` | 5 | strip | `1E-4`, scale 4, accepted |
| `5.0E-5` | 6 | strip | `5E-5`, scale 5, still refused by the service (correct, genuine 5th decimal) |
| `1.2345E-4` | 8 | strip | no trailing zeros, scale 8, refused (correct) |
| `36.5`, `0.001`, `-0.5` | 1, 3, 1 | not > 4 | unchanged |
| `1.0E10` | -9 | not > 4 | NOT stripped. Negative scale passes the scale check (`-9 <= 4`). Magnitude 1e10 is below 1e13, so it is accepted at the magnitude check |
| `1.0E13`, `1.0E20` | -12, -19 | not > 4 | not stripped. Refused by the `abs() >= 10^13` check, which r2 confirmed has a unit row for `1E+20` |
| `1.23456781234E7` | 4 | not > 4 | unchanged, accepted |
| `1.234567812345E7` | 5 | strip | no trailing zeros, scale 5, refused (correct) |
| `Infinity` | n/a | NFE | "must be a finite number" |

- The strip branch is reached only when scale > 4. For a Double that means a sub-0.001 E form (positive exponent forms of 1e7 and above have scale <= 4 unless they carry a genuine 5th decimal). In that branch the unstripped zero can only be the trailing `.0`, so the strip yields a scale of at least 4 for a real 4-decimal value. It cannot reach a negative scale from a Double, because a value with scale > 4 has a nonzero digit past the 4th decimal, or its only trailing zero is the `.0` of `d.0E-n`. The `1E+10` negative-scale worry therefore arises only on the NOT-stripped path, and only for a non-stripped `1.0E10` text, which is already unaffected by this commit.
- Binding negative-scale values (1E+10 style) into `numeric(17,4)`: this commit does not change that path (it is `scale <= 4`, so unstripped). Hibernate/pgjdbc send the BigDecimal as a numeric parameter and PostgreSQL accepts exponent notation. I could not run it, so I am not claiming runtime proof. It is pre-existing and was already reviewed in r2 under "Regression checks".
- `stripTrailingZeros` on zero: Java 8+ returns `BigDecimal.ZERO` (scale 0). Unreachable for a Double (`0.0` prints at scale 1).

Conclusion: correct for every Double-derived string.

## Check (b): see L-A. The test is meaningful (guards rounding and unstripped mutants) but should assert value plus `scale > 4`, not `== 5`.
`subThousandthFourDecimals_accepted` is solid. It uses the mock stub with `new BigDecimal("0.0005")`, and BigDecimal equals is scale-sensitive, so the strict-stub/verify pair actually checks scale 4. That is why removing the strip makes the stub mismatch (`5.0E-4` vs `0.0005`), as the author reported. The `fiveDecimals` test leaves the service unstubbed, so the mock returns null and `ResponseEntity.ok(null)` is OK; the `isOk()` assertion is valid.

## Check (c): is a distinct assertion lost?
No. The AC-14 diff changes one line (`sysprops("36","60","84")` to `("10","20","30")`). That test never asserted the `default*` values (only `containsKeys`); the SYSTEM-source value assertions live in `fixedAssignmentView_shouldReportSystemSource_whenLocationHasNoDefault` with 30/50/70. The row's 36/60/84 assertions are unchanged. Positions stay distinct (10<20<30, all different from 36/60/84), so a min/hysteresis/max swap is still caught, and the new values no longer equal the row's, so the "default leaks into minAmount" mutant is now detectable (author's 2-vs-1 failing-test count is plausible from the diff: minAmount and its sibling assertion fail).

## Check (d): do comments match the code?
Yes. "Double prints values below 0.001 in E notation", "5.0E-4 parses at scale 5", and "strip only when scale is over 4" all match the code and the table above. The new AC-14 comment ("defaults deliberately differ from the row's 36/60/84") matches `flaRow()`'s stubs. Test display names match their bodies, except the minor "(its scale check refuses it)" note under L-A. See L-B for a precision nit.

## Ruled out
- Strip producing a negative scale from a Double in the `scale > 4` branch (see (a)).
- Genuine 5-decimal Double values being silently accepted via the strip (`5E-5` keeps scale 5; `1.2345E-4` has no zeros to strip).
- Values at or above 10^13 slipping through: the magnitude check is unchanged and runs after the scale check.
- Loss of the 32-character cap, the Infinity mapping, or the Number-only guard: untouched, the strip sits inside the same try block after the cap.
- NumberFormatException handling regressions: `stripTrailingZeros` cannot throw; the catch still wraps only the parse.
- Production behaviour change for integers and for values at or above 0.001: they never reach the strip branch.
- Lost or weakened assertions in `ViewDtoServiceUnitTest` (see (c)).
- Mockito strictness problems in the new controller tests: the first stubs and verifies the identical argument tuple; the second stubs nothing and verifies with `eq(5L)`/`any()`.

## Positive observations
- The fix is the one-line form r2 proposed, with the guard that keeps the scale check authoritative.
- The `fiveDecimals` companion test guards against over-correcting (rounding or always stripping), which is the usual way this kind of fix goes wrong.
- The AC-14 fixture change is a small, targeted strengthening with an explaining comment.

## Recommendation: APPROVE
Safe to push. L-A and L-B are optional; fold L-A in if another commit is being made anyway (house rule: fix Lows).
