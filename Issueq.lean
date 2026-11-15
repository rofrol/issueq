import Issueq.Format
import Issueq.Git

/-! The queue, `issues/ORDER` with one `issues/ID.md` per item, changed only
under one lock and committed at once: the format is `Issueq/Format.lean`'s,
git and the lock `Issueq/Git.lean`'s; this module reads and changes the
files.

Each change (`add`, `move`, `edit`, `finish`) checks that `issues/` of the
checkout it acts on has no uncommitted change, reads the queue and checks
it (`check`), writes the new files, checks them again and commits exactly
the paths it changed, by path, with the trailer `Queue-change: rr2`, which
marks the commits made this way. A failure before the commit puts
`issues/` back as it was in `HEAD`, which it was before the change.

`cli` (the executable `issueq`, and `rr2 issue`) acts on the main checkout,
the repository's main worktree, after running its caller's `before` under
the lock. -/

namespace Issueq

def freshId (taken : List String) : IO String := do
  for _ in [0:100] do
    let id := idFrom (← IO.getRandomBytes 6)
    unless taken.contains id do return id
  throw (IO.userError "no free issue id after 100 tries")

def issuesDir (dir : System.FilePath) : System.FilePath := dir / "issues"

/-- The item files of `dir`'s queue: each id with its file's first line. -/
def itemFiles (dir : System.FilePath) : IO (List (String × String)) := do
  let entries ← (issuesDir dir).readDir
  let mut out := []
  for e in entries.qsort (·.fileName < ·.fileName) do
    if let some id := e.fileName.dropSuffix? ".md" then
      if isIssueId id.toString then
        let text ← IO.FS.readFile e.path
        out := out ++ [(id.toString, ((text.splitOn "\n").headD "").trimAscii.toString)]
  return out

/-- The queue of `dir`, read and checked. -/
def readChecked (dir : System.FilePath) : IO Order := do
  let o ← IO.ofExcept (parse (← IO.FS.readFile (issuesDir dir / "ORDER")))
  let bad := check o (← itemFiles dir)
  unless bad.isEmpty do throw (IO.userError s!"the queue in {dir} is not valid: {"; ".intercalate bad}")
  return o

/-- Throws when `issues/` in `dir` has a change not committed, staged or
not, or a file git does not track. -/
def ensureClean (l : Locked) (dir : System.FilePath) : IO Unit := do
  let out ← l.gitOk dir #["status", "--porcelain", "--untracked-files=all", "--", "issues"]
  unless out.trimAscii.isEmpty do
    throw (IO.userError s!"issues/ in {dir} has uncommitted changes:\n{out.trimAscii}")

/-- Writes `text` to `path` by a rename, so a reader sees the old file or
the new one whole. -/
def writeWhole (path : System.FilePath) (text : String) : IO Unit := do
  let tmp := System.FilePath.mk (path.toString ++ ".issueq-tmp")
  IO.FS.writeFile tmp text
  IO.FS.rename tmp path

def trailer := "Queue-change: rr2"

/-- Commits exactly `paths` (relative to `dir`) as they are in `dir`, with
`subject`, `body` and the trailer, leaving whatever else is staged alone;
checks that the commit changed no other path. The commit's id. -/
def commitPaths (l : Locked) (dir : System.FilePath) (paths : List String) (subject : String) (body : Option String) : IO String := do
  discard <| l.gitOk dir (#["add", "-A", "--"] ++ paths.toArray)
  let msg := subject ++ "\n\n" ++ (body.map (·.trimAscii.toString ++ "\n\n")).getD "" ++ trailer ++ "\n"
  let (h, msgPath) ← IO.FS.createTempFile
  try
    h.putStr msg
    h.flush
    discard <| l.gitOk dir (#["commit", "-q", "-F", msgPath.toString, "--"] ++ paths.toArray)
  finally
    IO.FS.removeFile msgPath
  let changed := (← l.gitOk dir #["show", "--name-only", "--format=", "HEAD"]).splitOn "\n" |>.filter (!·.isEmpty)
  let extra := changed.filter (!paths.contains ·)
  unless extra.isEmpty do
    throw (IO.userError s!"the queue commit in {dir} changed other paths too: {", ".intercalate extra}")
  return (← l.gitOk dir #["rev-parse", "HEAD"]).trimAscii.toString

/-- Runs one change of `dir`'s queue: `issues/` checked clean first, and on
a failure before the commit put back as `HEAD` has it. -/
def change (l : Locked) (dir : System.FilePath) (k : IO α) : IO α := do
  ensureClean l dir
  try k catch e =>
    discard <| l.git dir #["reset", "-q", "--", "issues"]
    discard <| l.git dir #["checkout", "-q", "HEAD", "--", "issues"]
    discard <| l.git dir #["clean", "-fq", "--", "issues"]
    throw e

/-- Writes `o` and the files `texts` (id, text), checks the result, and
commits them with the files `gone` removed. -/
def publish (l : Locked) (dir : System.FilePath) (o : Order) (texts : List (String × String)) (gone : List String)
    (subject : String) (why : Option String) : IO String := do
  for (id, text) in texts do
    writeWhole (issuesDir dir / s!"{id}.md") (if text.endsWith "\n" then text else text ++ "\n")
  for id in gone do IO.FS.removeFile (issuesDir dir / s!"{id}.md")
  writeWhole (issuesDir dir / "ORDER") (render o)
  discard <| readChecked dir
  commitPaths l dir ("issues/ORDER" :: (texts.map (·.1) ++ gone).map (s!"issues/{·}.md")) subject why

/-! ## The changes, each under the lock -/

/-- Adds an item whose file is `text` at `place`: its id and the commit. -/
def addIn (l : Locked) (dir : System.FilePath) (text : String) (place : Place) (why : Option String) :
    IO (String × String) := change l dir do
  let o ← readChecked dir
  let some title := titleOf text | throw (IO.userError "the item's first line, its title, is empty")
  let id ← freshId (ids o ++ (← itemFiles dir).map (·.1))
  let o ← IO.ofExcept (insert o { id, title } place)
  let sha ← publish l dir o [(id, text)] [] s!"issues: add {id} {title}" why
  return (id, sha)

/-- What a move did: the commit it made, or none, since the item was
already where it was to go and ORDER stays as it is. -/
inductive Moved where
  | committed (sha : String)
  | alreadyThere
  deriving BEq, Repr

/-- Moves the item `id` to `place`; makes no commit when that leaves ORDER
as it is (already at the top of the section, at its end, or right after
the item named). -/
def moveIn (l : Locked) (dir : System.FilePath) (id : String) (place : Place) (why : Option String) :
    IO Moved := change l dir do
  let o ← readChecked dir
  let some (k, j) := locate o id | throw (IO.userError s!"no item {id} in issues/ORDER")
  if place == .after id then throw (IO.userError s!"{id} cannot go after itself")
  let item := o[k]!.items[j]!
  let moved ← IO.ofExcept (insert (remove o id) item place)
  if moved == o then return .alreadyThere
  let where_ := match place with
    | .top s => s!"to the top of {s}" | .bottom s => s!"to the end of {s}" | .after a => s!"after {a}"
  return .committed (← publish l dir moved [] [] s!"issues: move {id} {where_}" why)

/-- Replaces the item's file with `text`; its title in ORDER follows. -/
def editIn (l : Locked) (dir : System.FilePath) (id : String) (text : String) (why : Option String) :
    IO String := change l dir do
  let o ← readChecked dir
  if (locate o id).isNone then throw (IO.userError s!"no item {id} in issues/ORDER")
  let some title := titleOf text | throw (IO.userError "the item's first line, its title, is empty")
  let o := o.map fun s => { s with items := s.items.map fun i => if i.id == id then { i with title } else i }
  publish l dir o [(id, text)] [] s!"issues: edit {id} {title}" why

/-- Removes the item `id` and its file, and adds each of `proposals` (item
texts) at the end of "Proposed": the new ids and the commit. -/
def finishIn (l : Locked) (dir : System.FilePath) (id : String) (proposals : List String) (why : Option String) :
    IO (List String × String) := change l dir do
  let o ← readChecked dir
  let some (k, j) := locate o id | throw (IO.userError s!"no item {id} in issues/ORDER")
  let title := o[k]!.items[j]!.title
  let mut o := remove o id
  let mut taken := ids o ++ (← itemFiles dir).map (·.1)
  let mut added : List (String × String) := []
  for text in proposals do
    let some t := titleOf text | throw (IO.userError "a proposal's first line, its title, is empty")
    let pid ← freshId taken
    taken := pid :: taken
    o ← IO.ofExcept (insert o { id := pid, title := t } (.bottom "Proposed"))
    added := added ++ [(pid, text)]
  let also := if added.isEmpty then "" else s!", proposing {", ".intercalate (added.map (·.1))}"
  let sha ← publish l dir o added [id] s!"issues: finish {id} {title}{also}" why
  return (added.map (·.1), sha)

/-- The item texts in the directory `dir`, one per file, by file name;
none when it does not exist. Hidden files are not proposals. -/
def readProposals (dir : System.FilePath) : IO (List String) := do
  unless ← dir.pathExists do return []
  let entries := (← dir.readDir).qsort (·.fileName < ·.fileName)
  let mut out := []
  for e in entries do
    if e.fileName.startsWith "." then continue
    out := out ++ [← IO.FS.readFile e.path]
  return out

/-! ## The command line -/

/-- The usage of the command `cmd` (`issueq`, `rr2 issue`). -/
def usage (cmd : String) : String :=
  s!"usage: {cmd} add [--section next|proposed|needs | --after ID] [--top] [-F MSG] FILE|-
       {cmd} move ID (--section next|proposed|needs [--top] | --top | --after ID) [-F MSG]
       {cmd} edit ID [-F MSG] FILE|-
       {cmd} finish ID [--proposals DIR] [-F MSG]"

structure Opts where
  sec : Option String := none
  top : Bool := false
  after : Option String := none
  msg : Option String := none
  proposals : Option String := none
  rest : List String := []

def parseOpts : List String → Except String Opts
  | [] => .ok {}
  | "--section" :: s :: more => do
    let some name := sectionName s | .error s!"no section {s}: next, proposed or needs"
    pure { ← parseOpts more with sec := some name }
  | "--top" :: more => do pure { ← parseOpts more with top := true }
  | "--after" :: id :: more => do
    unless isIssueId id do .error s!"not an issue id: {id}"
    pure { ← parseOpts more with after := some id }
  | "-F" :: f :: more => do pure { ← parseOpts more with msg := some f }
  | "--proposals" :: d :: more => do pure { ← parseOpts more with proposals := some d }
  | a :: more => do
    if a.startsWith "-" && a != "-" then .error s!"unknown option {a}"
    let o ← parseOpts more
    pure { o with rest := a :: o.rest }

/-- Where `--section`, `--top` and `--after` put an item; `current` is the
section it is in, for a move with `--top` alone. -/
def placeOf (o : Opts) (current : Option String) : Except String Place :=
  match o.after, o.sec, o.top with
  | some a, none, false => .ok (.after a)
  | none, some s, true => .ok (.top s)
  | none, some s, false => .ok (.bottom s)
  | none, none, true => match current with
    | some s => .ok (.top s)
    | none => .ok (.top "Proposed")
  | none, none, false => match current with
    | some _ => .error "say where: --section, --top or --after"
    | none => .ok (.bottom "Proposed")
  | _, _, _ => .error "--after goes with neither --section nor --top"

def readText (arg : String) : IO String :=
  if arg == "-" then do (← IO.getStdin).readToEnd else IO.FS.readFile arg

def checkId (id : String) : IO Unit :=
  unless isIssueId id do throw (IO.userError s!"not an issue id: {id}")

/-- The command `cmd` (`issueq`, `rr2 issue`), on the main checkout of the
current directory's repository: prints what it did; the exit code. Its
messages start with `prog: `. `before` runs under the lock before the
change, on the main checkout: rr2 settles there the integrations a killed
rr2 left, which this library does not know; the executable `issueq` runs
nothing there (README, "rr2's integrations"). -/
def cli (prog cmd : String) (before : Locked → System.FilePath → IO Unit) (args : List String) : IO UInt32 := do
  try
    let (sub, o) ← match args with
      | sub :: more => pure (sub, ← IO.ofExcept (parseOpts more))
      | [] => throw (IO.userError (usage cmd))
    let why ← o.msg.mapM IO.FS.readFile
    let (dir, _) ← mainCheckout (← IO.currentDir)
    match sub, o.rest with
    | "add", [file] =>
      let text ← readText file
      let place ← IO.ofExcept (placeOf o none)
      let (id, sha) ← withLock prog dir fun l => do before l dir; addIn l dir text place why
      IO.println s!"{id} {sha}"
    | "move", [id] =>
      checkId id
      let moved ← withLock prog dir fun l => do
        before l dir
        let q ← readChecked dir
        let cur := (locate q id).map fun (k, _) => q[k]!.name
        moveIn l dir id (← IO.ofExcept (placeOf o cur)) why
      match moved with
      | .committed sha => IO.println sha
      | .alreadyThere => IO.println s!"{id} is already there"
    | "edit", [id, file] =>
      checkId id
      let text ← readText file
      IO.println (← withLock prog dir fun l => do before l dir; editIn l dir id text why)
    | "finish", [id] =>
      checkId id
      let props ← match o.proposals with
        | some d => readProposals d
        | none => pure []
      let (added, sha) ← withLock prog dir fun l => do before l dir; finishIn l dir id props why
      IO.println (" ".intercalate (added ++ [sha]))
    | _, _ => throw (IO.userError (usage cmd))
    return 0
  catch e =>
    IO.eprintln s!"{prog}: {e}"
    return 1

end Issueq
