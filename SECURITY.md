# Security policy

## Supported versions

Security fixes go to the latest `main`. Older commits, forks, other branches
and modified model packages are not supported.

## Reporting a vulnerability

Don't open a public issue for a suspected vulnerability. Report it privately
through
[GitHub private vulnerability reporting](https://github.com/maxslamdunk/localita/security/advisories/new).

Include:

- what the vulnerability is;
- the affected commit;
- the steps to reproduce it, or a minimal proof of concept;
- what you expected and what happened;
- the impact you think it has; and
- a fix, if you have one in mind.

Leave out personal data, credentials, access tokens and model weights.

Reports are most useful when they involve:

- **the model download:** a Hugging Face link or checkpoint that gets past
  the app's layout check, or files written outside the app's own storage;
- **the model files:** malformed `.gturbo` data, offsets or sizes that lead to
  out-of-bounds reads or writes;
- **benchmark results:** the Send screen sending more than it shows, or the
  submission Worker ([`server/benchmark-worker/`](server/benchmark-worker/))
  accepting or publishing data it should not;
- **the Mac side:** the loopback server exposed beyond `127.0.0.1`, or
  model-produced tool calls running without the client's approval.

Wrong or poor answers from the model, high memory or battery use, and slow
speed are not security problems. Report them as bugs.

Please give the problem time to be fixed before publishing details. You will be
credited in the advisory unless you'd rather not be.

A vulnerability in the shared engine probably affects upstream as well.
Report it to [TurboFieldfare](https://github.com/drumih/turbo-fieldfare/security/advisories/new)
too, or say in your report that you haven't, and it will be passed on.
