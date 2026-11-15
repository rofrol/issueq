issueq: a test that a git started under the lock keeps it after its parent is killed

The contract (README, "Inheritance by git children") says every git started under the lock holds it until it exits, so a git that outlives a killed holder excludes the next change. rr2 tests this through its own harness; issueq's Tests.lean does not yet. The test needs a git child that blocks on an event the test controls, without a shell file (AGENTS.project.md).
