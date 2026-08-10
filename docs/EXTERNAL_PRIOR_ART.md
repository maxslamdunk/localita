# External prior art

Techniques from outside this project — papers, other inference runtimes, vendor documentation — assessed against TurboFieldfare's binding constraint.

Stub. Nothing recorded yet.

The filter for everything here: **does it reduce bytes read per token on a memory-constrained device?** A technique that improves compute throughput, or that assumes the weights are already resident, does not apply and should be recorded as not applicable rather than left out — knowing something was considered and rejected saves the next session from rediscovering it.

## How to add an entry

One section per technique, newest last. Include:

- **Technique and source** — name, and a link or citation.
- **What it claims** — the mechanism and the reported effect.
- **Applicability here** — does it move bytes/token given SSD-streamed routed experts, a 16-slot cache, and the memory ceiling? Be explicit when the answer is no.
- **What adopting it would cost** — format changes, kernel work, iOS portability.
- **Status** — `not evaluated` / `rejected` / `candidate` / `adopted`. Adopted techniques get an entry in `PRIOR_ART.md` with real measurements.

Related: `PRIOR_ART.md` (what this project tried), `MEASUREMENTS.md` (run log).
