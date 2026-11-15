issueq: say "main worktree" instead of rr2's "checkout to integrate into" in mainCheckout's errors

`mainCheckoutAs` (Issueq/Git.lean) refuses a bare repository and a detached main worktree with rr2's wording ("no checkout to integrate into", "names no branch to integrate into"); sol noted it in consult round 20261115-203515-b8cc. rr2's tests may match these texts, so change them with rr2's pin update.
