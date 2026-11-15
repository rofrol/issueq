import Lake
open Lake DSL

-- A warning fails the build: fix the code it names, never turn a linter off.
package issueq where
  testDriver := "tests"
  leanOptions := #[⟨`warningAsError, true⟩]

-- The owner's POSIX bindings (macOS): `flock`, pipes and `posix_spawn`-style
-- starts of git. Pinned by a commit that carries the tag `pin/c5e642692534`
-- there, the same commit rr2 pins.
require «lean-posix» from git "https://github.com/rofrol/lean-posix" @ "c5e64269253493a2676bf7d16e348b6eb8bd6cb8"

-- The library: `Issueq` (the changes and the command line), `Issueq.Format`
-- (pure) and `Issueq.Git` (git and the lock).
@[default_target] lean_lib Issueq where
  globs := #[.andSubmodules `Issueq]

@[default_target] lean_exe issueq where
  root := `Main

-- `lake test`: the format against examples, and the executable's changes,
-- its lock and its failures in throwaway repositories.
-- The tests start the executable `issueq` built next to them.
lean_exe tests where
  root := `Tests.Main
  needs := #[BuildKey.packageTarget `issueq `issueq]
