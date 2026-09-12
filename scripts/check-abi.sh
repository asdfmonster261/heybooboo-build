#!/usr/bin/env bash
# Compare a kernel_aarch64_abi_diff report against the approved breaks,
# and fail only on something new.
#
#   check-abi.sh check  <abi.report.small>   compare against abi-allowed-breaks.report
#   check-abi.sh accept <abi.report.small>   record the current report as approved
#
# Our report is never empty and never will be: bbrv3 grows rate_sample and tcp_bbr_info,
# upstream ships no BBRv3 to inherit the growth from, and rate_sample has no reserved
# padding to hide it in. So "exit 0 from stgdiff" is not a reachable goal and gating on it
# would just be permanently red. Google has the same problem and answers it the same way,
# in gki/aarch64/abi.stg.allowed_breaks, except their approval tooling is internal and the
# file is inert in this build.
#
# Feed it abi.report.small. abi.report.short elides ("... 5 omitted; 8 symbols have only
# CRC changes"), which would hide the identity of a newly affected symbol. abi.report.flat
# is the transitive closure, 86k lines of every symbol whose type graph reaches a change.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
BASELINE=${BASELINE:-$HERE/abi-allowed-breaks.report}
MODE=${1:-}
REPORT=${2:-}

[ -n "$MODE" ] && [ -n "$REPORT" ] || { sed -n '3,6p' "$0" | sed 's/^# \?//'; exit 2; }
[ -f "$REPORT" ] || { echo "no such report: $REPORT" >&2; exit 2; }

if [ "$MODE" = accept ]; then
  { echo "# Approved ABI breaks for the heybooboo kernel."
    echo "# Regenerate with: scripts/check-abi.sh accept <abi.report.small>"
    echo "# Every stanza here is a difference against ACK's abi.stg that have been reviewed"
    echo "# and accepted. Anything NOT here is new and fails the check."
    echo "#"
    echo "# recorded $(date -u '+%Y-%m-%d')"
    echo
    cat "$REPORT"
  } > "$BASELINE"
  echo "recorded $(grep -c "^[^ #]" "$BASELINE" || true) approved stanzas in $BASELINE"
  exit 0
fi

[ "$MODE" = check ] || { echo "unknown mode: $MODE" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "no baseline at $BASELINE; run: check-abi.sh accept <report>" >&2; exit 2; }

python3 - "$REPORT" "$BASELINE" <<'PY'
import re, sys

def stanzas(path):
    """Split a stgdiff report into col-0-headed blocks, keyed by header."""
    out, cur = {}, None
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            cur = line
            out.setdefault(cur, [])
        elif cur is not None:
            out[cur].append(line)
    # CRC hex churns whenever ACK moves abi.stg, which is not the question being asked;
    # the question is which symbols and types are affected, and how.
    norm = lambda s: re.sub(r"0x[0-9a-f]+", "0xHEX", s)
    return {norm(h): [norm(b) for b in body] for h, body in out.items()}

live, base = stanzas(sys.argv[1]), stanzas(sys.argv[2])

new     = [h for h in live if h not in base]
gone    = [h for h in base if h not in live]
changed = [h for h in live if h in base and live[h] != base[h]]

for h in sorted(new):
    print("NEW      %s" % h)
    for b in live[h]: print("         %s" % b.strip())
for h in sorted(changed):
    print("CHANGED  %s" % h)
    for b in sorted(set(live[h]) - set(base[h])): print("    +    %s" % b.strip())
    for b in sorted(set(base[h]) - set(live[h])): print("    -    %s" % b.strip())
for h in sorted(gone):
    print("GONE     %s" % h)

print()
print("approved %d, live %d: %d new, %d changed, %d resolved"
      % (len(base), len(live), len(new), len(changed), len(gone)))
if new or changed:
    print("FAIL: unapproved ABI difference. Review it, then re-run with 'accept' if intended.")
    sys.exit(1)
if gone:
    print("OK (drift reduced; re-run 'accept' to drop the resolved entries)")
else:
    print("OK: the ABI differs from ACK only in approved ways")
PY
