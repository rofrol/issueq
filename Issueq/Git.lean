import Posix

/-! Git as the queue runs it (`gitAs`, `gitOk`, `commonDir`, `mainCheckout`)
and the queue lock (`withLock`, `Locked`), which a git started under it
holds too. It imports no other module of this library.

The lock is an exclusive `flock` of `rr2-queue.lock` (the name rr2 gave it,
kept so that rr2 and this tool exclude each other) in the repository's git
common dir, which its main checkout and all its worktrees share; the kernel
lets go of it when its holder ends, however it ends, and every git child the
holder started under it (`gitAs`), which holds it too until it exits.
`withLock` waits for it (saying so on stderr when another holds it) and is
the only way to a `Locked`, which every change takes, so no change runs
without the lock. -/

namespace Issueq

/-- The holder of the queue lock of one repository: only `withLock` makes
one, so every change, which takes one, runs under the lock. `fd` is the
descriptor that holds the lock, close-on-exec, so no child inherits it but
those the lock is handed to: every git child that runs under the lock
(`gitAs`). -/
structure Locked where
  private mk ::
  common : System.FilePath
  fd : UInt32

/-- Everything `fd` gives until its input ends (or a read fails, as
`Posix.read` gives it), as text, bytes that are not UTF-8 replaced. -/
partial def readToEnd (fd : UInt32) (acc : ByteArray := .empty) : IO String := do
  let b ← Posix.read fd 65536
  if b.size == 0 then return String.fromUTF8Lossy acc
  readToEnd fd (acc ++ b)

/-- Runs git in `dir` (`git -C DIR ARGS`): its exit code (128 plus the
signal that ended it), stdout and stderr; `input`, when given, on its stdin,
else `/dev/null`. Started by `Posix.trySpawn`, so git gets its 0, 1 and 2
and no other descriptor of the caller's, but, with `hold`, the queue lock's
(`keep`), at its own number and inheritable in git, while the caller's own
stays close-on-exec: a git that outlives a caller killed under the lock
keeps the
lock until it exits, so the next queue change, and its `reconcile`, waits
for that git's end instead of judging the repository while the git still
writes it (item c47ldg, step 3, vut6vw); its own children, which it starts
without closing the descriptor, keep it too. Never given to the agent, which
no git starts. Throws when git cannot be started. -/
def gitAs (hold : Option Locked) (dir : System.FilePath) (args : Array String) (input : Option String := none) :
    IO (UInt32 × String × String) := do
  let (outR, outW) ← Posix.pipe
  let (errR, errW) ← try Posix.pipe catch e => do Posix.close outR; Posix.close outW; throw e
  let inPipe ← try input.mapM fun _ => Posix.pipe catch e => do
    for fd in [outR, outW, errR, errW] do Posix.close fd
    throw e
  let spawned ← try
      Posix.trySpawn (#["git", "-C", dir.toString] ++ args)
        (stdin := (inPipe.map (·.1)).getD Posix.devNull) (stdout := outW) (stderr := errW)
        (keep := some ((hold.map (#[·.fd])).getD #[]))
    catch e =>
      -- Thrown, nothing started: the parent's ends too.
      for fd in [outR, errR] ++ (inPipe.map (·.2)).toList do Posix.close fd
      throw e
    finally
      -- The child's ends are its own now, whatever the spawn's result.
      Posix.close outW
      Posix.close errW
      if let some (r, _) := inPipe then Posix.close r
  match spawned with
  | .error f =>
    for fd in [outR, errR] ++ (inPipe.map (·.2)).toList do Posix.close fd
    throw (IO.userError s!"cannot start git {" ".intercalate args.toList} in {dir}: {f.stage}: {← Posix.strerror f.errno}")
  | .ok pid =>
    -- Each stream on a thread of its own, so none fills while another is
    -- read or written; stdin ends when its write end closes. Whatever
    -- happens to the streams, git is reaped before this returns or throws,
    -- so no git of a caller under the lock outlives the call while the
    -- caller goes on under that lock (a failure here is settled under it).
    let attempt : IO (Task (Except IO.Error UInt32) × Task (Except IO.Error String) × String) := do
      let fed ← IO.asTask (prio := .dedicated) do
        match inPipe with
        | some (_, w) => try Posix.writeAll w (input.getD "").toUTF8 finally Posix.close w
        | none => pure 0
      let err ← IO.asTask (prio := .dedicated) (try readToEnd errR finally Posix.close errR)
      let out ← try readToEnd outR finally Posix.close outR
      pure (fed, err, out)
    let streams ← attempt.toBaseIO
    let code ← Posix.waitpid pid
    let (fed, err, out) ← IO.ofExcept streams
    let fed ← IO.ofExcept (← IO.wait fed)
    let err ← IO.ofExcept (← IO.wait err)
    -- A git that failed may stop reading its input (EPIPE): its exit code
    -- and stderr say why. One that succeeded without all of it is refused.
    if fed != 0 && code == 0 then
      throw (IO.userError s!"git {" ".intercalate args.toList} in {dir} exited 0 without reading all its input: {← Posix.strerror fed}")
    return (code, out, err)

/-- Runs git in `dir`, holding no lock (`gitAs`): its exit code, stdout and
stderr. -/
def git (dir : System.FilePath) (args : Array String) : IO (UInt32 × String × String) :=
  gitAs none dir args

/-- `gitAs`, giving git's stdout. When it fails, throws its stderr, or its
stdout when stderr is empty: some failures, such as `git commit` with
nothing to commit, say why on stdout only. -/
def gitOkAs (hold : Option Locked) (dir : System.FilePath) (args : Array String) : IO String := do
  let (code, out, err) ← gitAs hold dir args
  if code != 0 then
    let why := if err.trimAscii.isEmpty then out.trimAscii else err.trimAscii
    throw (IO.userError s!"git {" ".intercalate args.toList} in {dir} failed: {why}")
  return out

/-- `gitOkAs` holding no lock. -/
def gitOk (dir : System.FilePath) (args : Array String) : IO String :=
  gitOkAs none dir args

/-- Git in `dir` under the lock `l`, which it holds too until it exits
(`gitAs`). -/
def Locked.git (l : Locked) (dir : System.FilePath) (args : Array String) : IO (UInt32 × String × String) :=
  gitAs (some l) dir args

/-- `gitOkAs` under the lock `l`. -/
def Locked.gitOk (l : Locked) (dir : System.FilePath) (args : Array String) : IO String :=
  gitOkAs (some l) dir args

def commonDir (dir : System.FilePath) : IO System.FilePath := do
  return (← gitOk dir #["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimAscii.toString

/-- The main checkout of `dir`'s repository, its main worktree (which `git
worktree list` gives first), and the branch checked out there as a full ref
(`refs/heads/NAME`): the repository's integration branch, which holds the
queue and into which rr2 integrates, whatever its name (`main`, `master`).
Git keeps no local "default branch" to ask instead: `init.defaultBranch`
names only a new repository's first branch, and `refs/remotes/origin/HEAD`
needs a remote. Throws for a bare repository and for a main worktree on a
detached HEAD, which names no branch. Its git holds `hold` (`gitAs`). -/
def mainCheckoutAs (hold : Option Locked) (dir : System.FilePath) : IO (System.FilePath × String) := do
  let out ← gitOkAs hold dir #["worktree", "list", "--porcelain", "-z"]
  -- The first record's fields, up to the empty field that ends it.
  let fields := (out.splitOn "\x00").takeWhile (!·.isEmpty)
  let some path := fields.findSome? fun f => (f.dropPrefix? "worktree ").map (·.toString)
    | throw (IO.userError "git lists no worktree of this repository")
  if fields.contains "bare" then throw (IO.userError s!"{path} is a bare repository, which has no checkout to integrate into")
  let some branch := fields.findSome? fun f => (f.dropPrefix? "branch ").map (·.toString)
    | throw (IO.userError s!"the main checkout {path} is on a detached HEAD, so it names no branch to integrate into; check a branch out there")
  return (path, branch)

/-- `mainCheckoutAs` holding no lock. -/
def mainCheckout (dir : System.FilePath) : IO (System.FilePath × String) :=
  mainCheckoutAs none dir

/-- A branch's name as people say it: `refs/heads/` taken off. -/
def branchName (ref : String) : String := ((ref.dropPrefix? "refs/heads/").map (·.toString)).getD ref

def lockPath (common : System.FilePath) : System.FilePath := common / "rr2-queue.lock"

/-- Runs `k` holding the queue lock of `dir`'s repository, waited for; says
on stderr, after `prog: `, that it waits when another holds it: another
changer of the queue (this tool, rr2), or a git child of one killed under
the lock, which holds it until it exits (`gitAs`).
Throws when the lock cannot be had. -/
def withLock (prog : String) (dir : System.FilePath) (k : Locked → IO α) : IO α := do
  let common ← commonDir dir
  let path := lockPath common
  let fd ← match ← Posix.lockFile path false with
    | .ok fd => pure fd
    | .error e =>
      if e != Posix.lockHeld then throw (IO.userError s!"cannot lock {path} (errno {e})")
      IO.eprintln s!"{prog}: waiting for the queue lock {path}, which another holds"
      (← IO.getStderr).flush
      match ← Posix.lockFile path true with
      | .ok fd => pure fd
      | .error e => throw (IO.userError s!"cannot lock {path} (errno {e})")
  try k ⟨common, fd⟩ finally Posix.unlock fd

end Issueq
