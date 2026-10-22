head: a8b8307

# SBDEV-3873 PR-W — re-review 5 (scoped: a8b8307 vs b9c870d)

Scope: `git show a8b8307`. The diff touches 1 file, `test/store/noSdrPatchOnAdviceCyclecount.spec.js` (+7/-3): the docstring, the `targetPath` key regex (line 148) and one new control (line 301). The worktree is clean.

## L-G — fixed
- Line 148: `\burl` was changed to `(?<![.\w$])url`. Both regexes were measured on the same inputs (node):
  - Control `wmsRequest('PATCH', '/client/' + obj.url, body)`: the old regex matched `.url` as a shorthand, so it keyed `<dynamic>`. The new regex finds no match, so the call keys `/client/`. This mutant is therefore killed: dropping the lookbehind turns the control red.
  - `a?.url` is now excluded (correct).
  - `url: x` is unchanged.
  - The shorthand `{ method:1, url }` is unchanged.
  - `baseurl: 1, url: '/c/'` still picks `url:`.
  - A `url:` with its value on the next line is unchanged.
  - `$url:` no longer matches. That is correct, because it is a different key.
- The control's justification holds. For the `$patch(` form, `targetPath` gets only the first argument, which has no trailing `,`/`}`, so the shorthand lookahead never fires there. Only the verb-form path passes the whole call text, and that path is where the regression was. `wmsRequest('PATCH', …)` is a form that VERB_PATCH already covers.

## L-H — fixed
- The docstring now scopes "nested url loses" to the options-object form. It also states the positional-call mislabel ("still counted, only mislabelled") and the key-vs-member rule. This matches the measured behaviour: in a positional call, the body's `url:` is the only key, so it wins. There is no code change.

## Other checks
- Spec: 56/56 pass (`npx jest test/store/noSdrPatchOnAdviceCyclecount.spec.js`).
- Real-tree census: the expected census set is not touched by the diff, and the census test passes. The census is therefore unchanged (`/client/`, `/customerorder/`).
- The diff makes no other changes. The SDR scan, VERB_PATCH and the comment stripping are untouched.
- Quoted keys (`'url':`) are matched by neither the old regex nor the new one. This is pre-existing and not in scope.

## Verdict
**APPROVE.** Counts: CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 0.
