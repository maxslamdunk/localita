"""Print the footer lines of each harness log in logs/, plus derived figures."""
import glob, os, re

here = os.path.dirname(os.path.abspath(__file__))
for path in sorted(glob.glob(os.path.join(here, "logs", "decode-*.log"))):
    lines = open(path).read().splitlines()
    pick = {}
    for line in lines:
        m = re.match(r"(?:\d+, )+(done|expert-io|phase-time|gpu-time|read-latency|generated), (.*)", line)
        if m:
            pick[m.group(1)] = m.group(2)
    print("==", os.path.basename(path))
    for key in ("done", "expert-io", "phase-time", "gpu-time", "read-latency", "generated"):
        if key in pick:
            text = pick[key]
            if key == "generated":
                text = text[text.index("sha256="):]
            else:
                text = text[text.index("["):] if "[" in text else text
            print("  ", text)
    try:
        num = lambda key, name: float(re.search(r"\b%s=([\d.]+)" % name, pick[key]).group(1))
        wait, gcb1 = num("phase-time", "cb1-wait"), num("gpu-time", "cb1")
        routed = num("gpu-time", "routed")
        io, wall, busy = num("phase-time", "io"), num("phase-time", "wall"), num("gpu-time", "busy")
        shared, hit = num("gpu-time", "shared"), num("gpu-time", "hit-experts")
        print("   derived: attention+router %.0f%% of cb1-wait; uncovered %.2f ms/token "
              "(cb1-wait - cb1 - routed*29/30, routed share an approximation); busy %.0f%% of wall; "
              "GPU idle within io ~%.0f ms (io - shared - hit, assumes both run inside io)"
              % (100 * gcb1 / wait, wait - gcb1 - routed * 29 / 30, 100 * busy / wall,
                 io - shared - hit))
    except (KeyError, AttributeError):
        pass
