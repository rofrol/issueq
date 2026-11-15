import Issueq

/-! `lake test`: the format against examples, then the executable's changes,
its lock and its failures, each in a throwaway repository. This program is
also a helper of its tests: `tests hold-queue DIR` holds the queue lock of
DIR until its stdin ends. The changes run the executable `issueq` that Lake
builds next to this program (`lakefile.lean`, `needs`). -/

open Issueq

def sampleOrder : String :=
  "## Next, in order\n\naaaaaa First item\nbbbbbb Second item\n\n## Proposed\n\n## Needs a decision\n\ncccccc Third item\n"

def formatChecks : List (String × Bool) :=
  let o := (parse sampleOrder).toOption.getD #[]
  let it (id : String) : Item := { id, title := s!"T {id}" }
  let names (o : Order) := o.toList.map fun s => s.items.toList.map (·.id)
  let files := [("aaaaaa", "First item"), ("bbbbbb", "Second item"), ("cccccc", "Third item")]
  [ ("format: ORDER is read and written back as it was, empty sections too",
      o.size == 3 && render o == sampleOrder
        && render ((parse "## A\n## B\n").toOption.getD #[]) == "## A\n\n## B\n"),
    ("format: a stray line, a bad id or a missing title is refused, naming its line",
      (parse "x\n## A\n") matches .error _
        && (match parse "## A\n\nAAAAAA Title\n" with | .error e => e.startsWith "issues/ORDER line 3" | _ => false)
        && (parse "## A\n\naaaaaa\n") matches .error _),
    ("format: an item goes to the top or the end of a section, or after another",
      names ((insert o (it "dddddd") (.top "Proposed")).toOption.getD #[]) == [["aaaaaa", "bbbbbb"], ["dddddd"], ["cccccc"]]
        && names ((insert o (it "dddddd") (.top "Next, in order")).toOption.getD #[]) == [["dddddd", "aaaaaa", "bbbbbb"], [], ["cccccc"]]
        && names ((insert o (it "dddddd") (.bottom "Next, in order")).toOption.getD #[]) == [["aaaaaa", "bbbbbb", "dddddd"], [], ["cccccc"]]
        && names ((insert o (it "dddddd") (.after "aaaaaa")).toOption.getD #[]) == [["aaaaaa", "dddddd", "bbbbbb"], [], ["cccccc"]]
        && (insert o (it "dddddd") (.after "zzzzzz")) matches .error _
        && (insert o (it "dddddd") (.top "Nowhere")) matches .error _),
    ("format: a valid queue has no problems; each kind of problem is named",
      check o files == []
        && check o (files.take 2) == ["cccccc is in issues/ORDER but has no issues/cccccc.md"]
        && check o (files ++ [("dddddd", "Stray")]) == ["issues/dddddd.md is not in issues/ORDER"]
        && check o (files.set 0 ("aaaaaa", "Other title")) == ["issues/aaaaaa.md's title is not its title in issues/ORDER"]
        && check ((insert o { id := "aaaaaa", title := "First item" } (.top "Proposed")).toOption.getD #[]) files
          == ["aaaaaa is listed more than once in issues/ORDER"]),
    ("format: a fresh id has the queue's format",
      isIssueId (idFrom (ByteArray.mk #[0, 31, 32, 255, 100, 7]))
        && idFrom (ByteArray.mk #[0, 25, 26, 31, 32, 57]) == "az27az") ]

/-- This repository's own queue is valid and written as `render` writes it. -/
def ownQueue : IO (List (String × Bool)) := do
  let ok ← try
      let o ← readChecked "."
      pure (render o == (← IO.FS.readFile "issues/ORDER"))
    catch e =>
      IO.eprintln s!"own queue: {e}"
      pure false
  return [("this repository's queue is valid and in the queue's format", ok)]

/-! ## Processes -/

/-- A child of this program, its stdout and stderr each on a pipe. -/
structure Child where
  pid : UInt32
  out : UInt32
  err : UInt32

/-- Starts the program `exe` with `args` in `cwd`, `stdin` on its 0. -/
def startExe (exe : String) (cwd : System.FilePath) (args : Array String) (stdin : UInt32 := Posix.devNull) : IO Child := do
  let (oR, oW) ← Posix.pipe
  let (eR, eW) ← Posix.pipe
  let r ← try Posix.trySpawn (#[exe] ++ args) (stdin := stdin) (stdout := oW) (stderr := eW) (cwd := some cwd)
    finally
      Posix.close oW
      Posix.close eW
  match r with
  | .ok pid => return ⟨pid, oR, eR⟩
  | .error f =>
    Posix.close oR
    Posix.close eR
    throw (IO.userError s!"cannot start {exe} {args}: {f.stage}: {← Posix.strerror f.errno}")

/-- Starts this program with `args`. -/
def start (cwd : System.FilePath) (args : Array String) (stdin : UInt32 := Posix.devNull) : IO Child := do
  startExe (← IO.appPath).toString cwd args stdin

/-- Starts the executable `issueq` built next to this program with `args`. -/
def startIssueq (cwd : System.FilePath) (args : Array String) : IO Child := do
  let some bin := (← IO.appPath).parent | throw (IO.userError "this program's path has no directory")
  startExe (bin / "issueq").toString cwd args

/-- Reads `fd` until what was read contains `marker` or its input ends:
what was read. -/
partial def readUntil (fd : UInt32) (marker : String) (acc : String := "") : IO String := do
  if (acc.splitOn marker).length > 1 then return acc
  let b ← Posix.read fd 4096
  if b.size == 0 then return acc
  readUntil fd marker (acc ++ String.fromUTF8Lossy b)

/-- Reads the child's stdout and stderr to their end and reaps it: its exit
status (128 plus a signal), stdout and stderr. -/
def Child.finish (c : Child) : IO (UInt32 × String × String) := do
  let err ← IO.asTask (prio := .dedicated) (try readToEnd c.err finally Posix.close c.err)
  let out ← try readToEnd c.out finally Posix.close c.out
  let code ← Posix.waitpid c.pid
  return (code, out, ← IO.ofExcept (← IO.wait err))

/-- `issueq ARGS` in `repo`, as a process: its exit status, stdout and stderr. -/
def issueq (repo : System.FilePath) (args : List String) : IO (UInt32 × String × String) := do
  (← startIssueq repo args.toArray).finish

def items : List (String × String) :=
  [("aaaaaa", "First item"), ("bbbbbb", "Second item"), ("cccccc", "Third item")]

/-- A new repository in `dir` on `main`, with a queue of three items in
"Next, in order". -/
def queueRepo (dir : System.FilePath) : IO Unit := do
  IO.FS.createDirAll (dir / "issues")
  let g (args : Array String) : IO Unit := discard <| gitOk dir args
  g #["init", "-q", "-b", "main"]
  g #["config", "user.name", "issueq tests"]
  g #["config", "user.email", "issueq-tests@example.invalid"]
  g #["config", "commit.gpgsign", "false"]
  IO.FS.writeFile (dir / "issues" / "ORDER")
    ("## Next, in order\n\n" ++ String.join (items.map fun (i, t) => s!"{i} {t}\n") ++ "\n## Proposed\n\n## Needs a decision\n")
  for (i, t) in items do IO.FS.writeFile (dir / "issues" / s!"{i}.md") s!"{t}\n\nIts body.\n"
  g #["add", "-A"]
  g #["commit", "-q", "-m", "init"]

def headOf (repo : System.FilePath) (rev : String := "HEAD") : IO String :=
  return (← gitOk repo #["rev-parse", rev]).trimAscii.toString

def subjectOf (repo : System.FilePath) : IO String :=
  return (← gitOk repo #["log", "-1", "--format=%s"]).trimAscii.toString

def trailerOf (repo : System.FilePath) : IO String :=
  return (← gitOk repo #["log", "-1", "--format=%(trailers:key=Queue-change,valueonly)"]).trimAscii.toString

def idsOf (repo : System.FilePath) : IO (List (List String)) :=
  return (← readChecked repo).toList.map fun s => (s.items.map (·.id)).toList

/-- Runs `k` with a new empty directory, removed afterwards. -/
def inTemp (k : System.FilePath → IO α) : IO α := do
  let tmp ← IO.FS.createTempDir
  try k tmp finally IO.FS.removeDirAll tmp

/-- Each change, through the executable: it prints what it did, commits
only `issues/` paths with the trailer and a subject naming the change, and
leaves a valid queue. -/
def changes : IO (List (String × Bool)) := inTemp fun tmp => do
  let repo := tmp / "repo"
  queueRepo repo
  -- Another's work beside the queue: a staged new file and an unstaged one.
  IO.FS.writeFile (repo / "staged.txt") "staged\n"
  discard <| gitOk repo #["add", "--", "staged.txt"]
  IO.FS.writeFile (repo / "loose.txt") "loose\n"
  IO.FS.writeFile (repo / "tracked.txt") "first\n"
  discard <| gitOk repo #["add", "--", "tracked.txt"]
  discard <| gitOk repo #["commit", "-q", "-m", "tracked", "--", "tracked.txt"]
  IO.FS.writeFile (repo / "tracked.txt") "changed, not staged\n"
  IO.FS.writeFile (tmp / "new.md") "New item\n\nBody.\n"
  let (c1, out1, _) ← issueq repo ["add", "--section", "next", "--top", (tmp / "new.md").toString]
  let newId := (out1.splitOn " ").headD ""
  let added := c1 == 0 && isIssueId newId && (← idsOf repo).headD [] == [newId, "aaaaaa", "bbbbbb", "cccccc"]
    && (← subjectOf repo) == s!"issues: add {newId} New item" && (← trailerOf repo) == "rr2"
    && (out1.trimAscii.toString.splitOn " ")[1]? == some (← headOf repo)
  IO.FS.writeFile (tmp / "edit.md") "Renamed item\n"
  let (c2, _, _) ← issueq repo ["edit", "bbbbbb", (tmp / "edit.md").toString]
  let edited := c2 == 0 && (← readChecked repo)[0]!.items[2]!.title == "Renamed item"
    && (← IO.FS.readFile (repo / "issues" / "bbbbbb.md")) == "Renamed item\n"
    && (← subjectOf repo) == "issues: edit bbbbbb Renamed item"
  let (c3, _, _) ← issueq repo ["move", "cccccc", "--section", "needs"]
  let moved := c3 == 0 && (← idsOf repo) == [[newId, "aaaaaa", "bbbbbb"], [], ["cccccc"]]
    && (← subjectOf repo) == "issues: move cccccc to the end of Needs a decision"
  IO.FS.createDirAll (tmp / "props")
  IO.FS.writeFile (tmp / "props" / "1.md") "A proposal\n"
  IO.FS.writeFile (tmp / "props" / ".hidden") "Not a proposal\n"
  let (c4, out4, _) ← issueq repo ["finish", "aaaaaa", "--proposals", (tmp / "props").toString]
  let propId := (out4.splitOn " ").headD ""
  let finished := c4 == 0 && (← idsOf repo) == [[newId, "bbbbbb"], [propId], ["cccccc"]]
    && !(← (repo / "issues" / "aaaaaa.md").pathExists)
    && (← subjectOf repo) == s!"issues: finish aaaaaa First item, proposing {propId}"
  let only := (← gitOk repo #["log", "--format=", "--name-only", "HEAD~4..HEAD"]).splitOn "\n"
    |>.filter (!·.isEmpty) |>.all (·.startsWith "issues/")
  let others := (← gitOk repo #["status", "--porcelain"]).trimAscii.toString == "A  staged.txt\n M tracked.txt\n?? loose.txt"
    && (← IO.FS.readFile (repo / "tracked.txt")) == "changed, not staged\n"
    && (← gitOk repo #["show", ":staged.txt"]) == "staged\n"
  return [("change: add puts the item where it is told, prints its id and the commit, with the trailer", added),
    ("change: edit replaces the item's file and its title in ORDER", edited),
    ("change: move to a section puts the item at its end", moved),
    ("change: finish removes the item and its file and adds the proposals, hidden files left out, at the end of Proposed", finished),
    ("change: every change commits only paths under issues/, another's staged, unstaged and untracked files left as they were", only && others)]

/-- A move to where the item already is commits nothing, says so and exits
0; a move that changes ORDER commits it. -/
def moves : IO (List (String × Bool)) := inTemp fun tmp => do
  let repo := tmp / "repo"
  queueRepo repo
  let before ← headOf repo
  let stays (args : List String) (id : String) : IO Bool := do
    let (code, out, err) ← issueq repo (["move", id] ++ args)
    return code == 0 && out == s!"{id} is already there\n" && err.isEmpty && (← headOf repo) == before
  let top ← stays ["--top"] "aaaaaa"
  let bottom ← stays ["--section", "next"] "cccccc"
  let after ← stays ["--after", "aaaaaa"] "bbbbbb"
  let (code, out, _) ← issueq repo ["move", "cccccc", "--top"]
  let committed := (← gitOk repo #["show", "HEAD:issues/ORDER"]) == (← IO.FS.readFile (repo / "issues" / "ORDER"))
    && (← headOf repo "HEAD~1") == before
  return [("move: to where the item already is, nothing is committed", top && bottom && after),
    ("move: a move that changes ORDER commits it and prints the commit",
      code == 0 && committed && out == s!"{← headOf repo}\n" && (← idsOf repo) == [["cccccc", "aaaaaa", "bbbbbb"], [], []])]

/-- A change refuses a queue with uncommitted changes under `issues/`, and a
change that fails before its commit leaves `issues/` as `HEAD` has it. -/
def failures : IO (List (String × Bool)) := inTemp fun tmp => do
  let repo := tmp / "repo"
  queueRepo repo
  let before ← headOf repo
  IO.FS.writeFile (repo / "issues" / "aaaaaa.md") "First item\n\nChanged by hand.\n"
  IO.FS.writeFile (tmp / "new.md") "New item\n"
  let (c1, _, e1) ← issueq repo ["add", (tmp / "new.md").toString]
  let dirty := c1 == 1 && e1.startsWith "issueq: " && (e1.splitOn "uncommitted changes").length > 1
    && (← headOf repo) == before
  discard <| gitOk repo #["checkout", "-q", "--", "issues"]
  -- A commit that fails after the change wrote and staged its files: git
  -- signs it with a program that does not exist.
  discard <| gitOk repo #["config", "commit.gpgsign", "true"]
  discard <| gitOk repo #["config", "gpg.program", (tmp / "no-such-signer").toString]
  IO.FS.writeFile (tmp / "edit.md") "Renamed item\n"
  IO.FS.writeFile (tmp / "new2.md") "Another new item\n"
  let (c2, _, e2) ← issueq repo ["edit", "aaaaaa", (tmp / "edit.md").toString]
  let (c2b, _, _) ← issueq repo ["add", (tmp / "new2.md").toString]
  let status ← gitOk repo #["status", "--porcelain", "--untracked-files=all"]
  let undone := c2 == 1 && c2b == 1 && (e2.splitOn "git commit").length > 1 && status.trimAscii.isEmpty
    && (← headOf repo) == before
  discard <| gitOk repo #["config", "commit.gpgsign", "false"]
  let (c3, _, e3) ← issueq repo ["move", "zzzzzz", "--top"]
  let (c4, _, e4) ← issueq repo ["nonsense"]
  return [("failure: uncommitted changes under issues/ are refused, nothing committed", dirty),
    ("failure: a change whose commit fails after it wrote and staged its files leaves issues/ and the index as HEAD has them", undone),
    ("failure: an unknown item is refused", c3 == 1 && (e3.splitOn "no item zzzzzz").length > 1),
    ("failure: an unknown command is refused with the usage, naming issueq", c4 == 1 && e4.startsWith "issueq: usage: issueq add ")]

/-- Two writers of one queue: while this process holds the lock and has
committed an item, a second writer says it waits for the lock, which is the
positive event awaited before the lock is let go; its commit then comes
after the first's. -/
def twoWriters : IO (List (String × Bool)) := inTemp fun tmp => do
  let repo := tmp / "repo"
  queueRepo repo
  IO.FS.writeFile (tmp / "second.md") "Second writer's item\n"
  let (second, first, said, held) ← withLock "tests" repo fun l => do
    let (_, sha) ← addIn l repo "First writer's item\n" (.bottom "Next, in order") none
    let c ← startIssueq repo #["add", "--section", "next", (tmp / "second.md").toString]
    let said ← readUntil c.err "issueq: waiting for the queue lock"
    -- Still under the lock: the second writer has committed nothing.
    return (c, sha, said, (← headOf repo) == sha)
  let (code, out, _) ← second.finish
  let titles := ((← readChecked repo)[0]!.items.map (·.title)).toList
  return [("lock: a second writer waits for the lock while the first holds it",
      said.startsWith "issueq: waiting for the queue lock" && held),
    ("lock: the second writer's commit comes after the first's, both items kept in order",
      code == 0 && (← headOf repo "HEAD~1") == first && titles.drop 3 == ["First writer's item", "Second writer's item"]
        && (out.splitOn " ").length == 2)]

/-- A holder of the queue lock killed with SIGKILL lets go of it: the kernel
releases the `flock` with the process. The holder waits on a pipe this test
keeps open, so only the kill ends it. -/
def killedHolder : IO (List (String × Bool)) := inTemp fun tmp => do
  let repo := tmp / "repo"
  queueRepo repo
  let lock := lockPath (← commonDir repo)
  let (inR, inW) ← Posix.pipe
  let holder ← try start repo #["hold-queue", repo.toString] inR finally Posix.close inR
  let held ← readUntil holder.out "held\n"
  let during ← Posix.lockFile lock false
  if let .ok fd := during then Posix.unlock fd
  discard <| Posix.kill holder.pid.toInt32 9
  let (code, _, _) ← holder.finish
  Posix.close inW
  let after ← Posix.lockFile lock false
  if let .ok fd := after then Posix.unlock fd
  return [("lock: a killed holder of the lock lets go of it",
    held == "held\n" && code == 128 + 9
      && (match during with | .error e => e == Posix.lockHeld | _ => false) && after.isOk)]

def main (args : List String) : IO UInt32 := do
  match args with
  | ["hold-queue", dir] =>
    withLock "tests" dir fun _ => do
      IO.println "held"
      (← IO.getStdout).flush
      discard <| (← IO.getStdin).readToEnd
    return 0
  | [] =>
    -- A hang (a child that never says what a case waits for, while the case
    -- holds the lock it waits on) ends this program by SIGALRM, which fails
    -- `lake test`; its children end with it: the lock holder at its stdin's
    -- end, a waiting issueq once the lock is let go. The suite takes about
    -- 4 s on the owner's M1 (measured 2026-11-15).
    Posix.alarm 300 -- delay: test deadline: the whole suite
    let results := formatChecks ++ (← ownQueue) ++ (← changes) ++ (← moves) ++ (← failures)
      ++ (← twoWriters) ++ (← killedHolder)
    let mut failed := 0
    for (name, ok) in results do
      IO.println s!"{if ok then "ok  " else "FAIL"} {name}"
      unless ok do failed := failed + 1
    IO.println s!"{results.length - failed} passed, {failed} failed"
    return if failed == 0 then 0 else 1
  | _ =>
    IO.eprintln "usage: tests [hold-queue DIR]"
    return 2
