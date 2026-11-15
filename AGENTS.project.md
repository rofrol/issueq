# issueq's own rules for agents

- Everything is Lean: the library, the executable, its tests and any helper
  a test needs. No shell, bash, perl or Python files in this repository.
- The queue is `issues/ORDER` with one `issues/ID.md` per item, in the
  format `README.md` states. It changes only through `issueq
  add|move|edit|finish` (`lake exe issueq ...` here) or `rr2 issue`, which
  take the queue's lock and commit each change at once; never by hand or
  with `ad todo`.
- The contract in `README.md` (format, lock name, inheritance by git
  children, trailer) is shared with rr2, rr2-view, AgentDeck and the
  owner's hooks: a change to it needs the owner's approval and is made in
  every consumer together.
- The one dependency is lean-posix (https://github.com/rofrol/lean-posix,
  the owner's own POSIX bindings), pinned by commit in `lakefile.lean`; a
  new pin carries a `pin/<sha12>` tag there (AGENTS.md, Rule 6).
- Consumers pin this repository by commit; every pinned commit carries a
  pushed tag `pin/<sha12>` here, never moved or deleted.

## Architecture map

- The core is the format, `Issueq/Format.lean`: pure, imports nothing; every
  reader of the queue depends on it.
- `Issueq/Git.lean` (imports lean-posix): git started by `Posix.trySpawn`
  with only 0, 1, 2 and, under the lock, the lock's descriptor; the lock
  (`withLock` is the only way to a `Locked`).
- `Issueq.lean` (imports both): reads and changes `issues/` under a
  `Locked`, commits by path with the trailer; `cli` is the command line,
  with the caller's `before` step and message prefix.
- `Main.lean`: the executable `issueq`, `cli` with no `before`.

## Trust, effects and privileged operations

- It writes only `issues/` of the main checkout and commits there; it starts
  only git, with arguments it builds (ids are checked against the id format
  before use; file paths go after `--`). It reads item texts from files or
  stdin the caller names. No network, no secrets.

## Consumers

- rr2 (https://github.com/rofrol/rr2) is to pin it (its item bhkg5f) and
  make `rr2 issue` and its integration use the library.
- AgentDeck's `ad issue` is to delegate to the executable.

## Checks

- `lake build`; `lake test` (the tests of `Tests/Main.lean`: the format, each
  change through the executable, the lock with two writers and a killed
  holder).
