"""Score policies on a set of compacted traces.

Usage: run.py <traces-dir> <prefix> <slots> <policy>... [--no-early] [--per-trace]

<prefix> selects traces by file name (train-, val-, test-). Prints each
policy's pooled summary (token-weighted), and per trace with --per-trace.
"""
import sys
import sim
from policies import POLICIES


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    early = "--no-early" not in sys.argv
    per_trace = "--per-trace" in sys.argv
    directory, prefix, slots, names = args[0], args[1], int(args[2]), args[3:]
    traces = sim.load(directory, prefix)
    print("%d traces (%s*), %d scored tokens, %d slots, early read %s" % (
        len(traces), prefix, sum(t.T - sim.WARMUP for t in traces), slots,
        "on" if early else "off"))
    for name in names:
        rows = []
        for tr in traces:
            s = sim.summarize(tr, sim.replay(tr, POLICIES[name], slots, early), early)
            rows.append(s)
            if per_trace:
                print("  %-12s %-28s %s" % (name, tr.name, sim.fmt(s)), flush=True)
        print("%-12s %-28s %s" % (name, "pooled", sim.fmt(sim.pooled(rows))), flush=True)


if __name__ == "__main__":
    main()
