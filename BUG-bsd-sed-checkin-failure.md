# BUG: BSD sed compatibility breaks checkin on macOS

## Summary

`git dispatch checkin` fails on macOS due to BSD sed incompatibility on line 813 of `git-dispatch.sh`. The trailing-newline-stripping sed expression uses GNU sed syntax that BSD sed cannot parse.

## Error

```
sed: 2: "/^\n*$/{$d;N;ba;}
": unexpected EOF (pending }'s)
Error: Cherry-pick into cyril/poc/purchase-order-transaction-registration failed on 5b8264752cf3a7e575e4363ea2e178b3f32c4ae3
```

## Root Cause

Line 813:
```bash
sed -e :a -e '/^\n*$/{$d;N;ba;}'
```

BSD sed (macOS default) does not support:
- `\n` in bracket expressions (character classes). BSD sed treats `\n` literally as backslash + n, not newline.
- Multi-statement blocks via `-e` chaining with labels. BSD sed requires explicit newlines or semicolons differently than GNU sed.

The expression is meant to strip trailing blank lines from the commit message. It works on Linux (GNU sed) but fails on macOS (BSD sed).

## Affected Code Path

`git-dispatch.sh:810-813` - the `_cp_msg` construction used during `checkin` (and likely `apply` when `strip_cp_meta=true`):

```bash
_cp_msg=$(git log -1 --format="%B" "$hash" | \
    sed '/^(cherry picked from commit /d' | \
    sed '/^# Conflicts:$/,/^[^#]/{/^#/d;}' | \
    sed -e :a -e '/^\n*$/{$d;N;ba;}')
```

Lines 811-812 also use sed but with simpler patterns that work on both BSD and GNU sed. Only line 813 breaks.

## Fix Options

**Option A: Use awk instead of sed (recommended)**
```bash
# Strip trailing blank lines - works on both BSD and GNU
awk '/^$/{blank++; next} {for(i=0;i<blank;i++) print ""; blank=0; print}'
```

**Option B: Use perl (available on macOS by default)**
```bash
perl -0pe 's/\n+$/\n/'
```

**Option C: BSD-compatible sed with literal newline**
```bash
sed -e :a -e '/^[[:space:]]*$/{$d;N;ba
}'
```
Note: The literal newline inside the sed script is required for BSD sed to parse the branch command.

## Reproduction

1. macOS with default BSD sed (`/usr/bin/sed`)
2. Set up git-dispatch with source + checkout branch
3. Make commits on checkout branch
4. Run `git dispatch checkin`
5. Fails with `unexpected EOF (pending }'s)`

## Impact

- `checkin` is completely broken on macOS when the code path hits line 813
- `apply` may also be affected if it uses the same `strip_cp_meta=true` path
- Workaround: `git dispatch abort`, switch to source, re-apply changes manually
