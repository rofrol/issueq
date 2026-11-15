# issueq

The owner's work queue for a git repository, as a Lean 4 library and an
executable: `issues/ORDER` with one `issues/ID.md` per item, changed only
under one lock and committed at once. It was taken out of rr2
(https://github.com/rofrol/rr2), whose `rr2 issue` has the same contract.

```
issueq add [--section next|proposed|needs | --after ID] [--top] [-F MSG] FILE|-
issueq move ID (--section next|proposed|needs [--top] | --top | --after ID) [-F MSG]
issueq edit ID [-F MSG] FILE|-
issueq finish ID [--proposals DIR] [-F MSG]
```

`issueq` acts on the main checkout (the repository's main worktree) of the
current directory's repository. It prints what it did: `add` the new id and
the commit, `move` the commit or `ID is already there`, `edit` the commit,
`finish` the ids of the proposals it added and the commit. `-F MSG` names a
file whose text becomes the commit message's body. On failure it says why on
stderr after `issueq: ` and exits 1.

## The contract

These are shared with rr2, `rr2-view`, AgentDeck's `ad todo` and the owner's
hooks; changing any of them is a coordinated change of every one of those.

- **Format.** `issues/ORDER` holds sections `## NAME`, each followed by an
  empty line and its `ID TITLE` lines, an empty line between sections; the
  sections are `Next, in order`, `Proposed` and `Needs a decision`. An id is
  six characters of a-z and 2-7. An item's file `issues/ID.md` starts with
  its title, which ORDER repeats. `Issueq/Format.lean` (pure) parses,
  renders and checks it.
- **Lock.** Every change holds an exclusive `flock` of `rr2-queue.lock` in
  the repository's git common dir, shared by its main checkout and all its
  worktrees. The name is rr2's, kept so that rr2 and issueq exclude each
  other. A second changer waits for it and says so on stderr (`issueq:
  waiting for the queue lock ...`). The kernel lets go of it when its holder
  ends, however it ends.
- **Inheritance by git children.** Every git a change starts under the lock
  gets the lock's descriptor and holds the lock too until it exits, so a git
  that outlives a killed holder still excludes the next change. No other
  descriptor of the caller reaches git.
- **Commits.** Each change checks that `issues/` has no uncommitted change,
  reads and checks the queue, writes the new files (each by a rename),
  checks them again and commits exactly the paths it changed, by path, with
  the trailer `Queue-change: rr2`, which marks queue commits for rr2's
  integration. A failure before the commit puts `issues/` back as `HEAD` has
  it.
- **Not atomic across files.** A holder killed while it writes the files may
  leave `issues/` changed but not committed; the next change refuses it
  until the owner restores or commits it.
- **Ambiguous outcome.** A change may commit and then fail to print; read
  the log before running an `add` or `finish` again.

## rr2's integrations

rr2 settles, under the lock and before each queue change, the integrations a
killed rr2 left (`refs/rr2/integrating/ID`). The library takes that step as
`cli`'s `before`; the executable `issueq` runs nothing there. A queue commit
made while such an integration is pending is kept: rr2's settling either
finds the prepared commit in `main` and cleans up, or rolls back only the
run's worktree and its refs, never `main` (rr2's `Rr2/Integrate.lean`,
`settle` and `rollBack`).

## Library

| Module | What it holds |
| --- | --- |
| `Issueq/Format.lean` | the format, purely: `parse`, `render`, `check`, `insert`, `remove`, `locate`, `titleOf`, ids |
| `Issueq/Git.lean` | git as the queue runs it (`gitAs`, `gitOk`, `mainCheckout`) and the lock (`withLock`, `Locked`) |
| `Issueq.lean` | the changes (`addIn`, `moveIn`, `editIn`, `finishIn`), each under a `Locked`, and the command line (`cli`) |

Consumers pin it by commit; each pinned commit carries a tag `pin/<sha12>`.

## Building

Lean 4 (`lean-toolchain`), macOS (lean-posix). `lake build`, `lake test`.
