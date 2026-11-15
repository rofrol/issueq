# Decisions

## The repository (2026-11-15)

The owner approved taking rr2's queue (format and locked mutation) into a
repository of its own, with an executable having `rr2 issue`'s contract
(lock, its inheritance by git children, trailer, format), its own tests and
queue, published under the owner's GitHub account with a `pin/<sha12>` tag,
and approved rr2's dependency on it (rr2 items aaesbo and bhkg5f). The name
`issueq` was chosen in consult round 20261115-203515-b8cc over `lean-queue`,
which suggests a general FIFO library.
