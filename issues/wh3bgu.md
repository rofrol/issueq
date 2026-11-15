issueq: bind a `Locked` to its repository so a change cannot run on another repository than the one locked

Found in consult round 20261115-203515-b8cc (sol). `addIn`, `moveIn`, `editIn` and `finishIn` take a `Locked` and a `dir` separately; a caller holding the lock of repository A can change repository B. `Locked` records `common`: check that `dir`'s git common dir is it, or make the changes take the directory from the `Locked`.
