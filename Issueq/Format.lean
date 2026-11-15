/-! The queue's format, purely: `issues/ORDER` (`parse`, `render`), the
check of it against the item files `issues/ID.md` (`check`), an item's
title (`titleOf`) and the ids (`isIssueId`, `idFrom`). It imports no other
module, so a reader of the queue can take the format alone; reading and
changing the files under the lock is `Issueq.lean`'s.

The format is rr's, which rr2, `rr2-view` and AgentDeck's `ad todo` read:
sections `## NAME`, each followed by an empty line and its `ID TITLE`
lines, an empty line between sections; an item's file starts with its
title. -/

namespace Issueq

/-- An issue id of the queue's format: six characters of a-z and 2-7. -/
def isIssueId (s : String) : Bool :=
  s.length == 6 && s.all fun c => ('a' ≤ c && c ≤ 'z') || ('2' ≤ c && c ≤ '7')

structure Item where
  id : String
  title : String
  deriving BEq, Repr, Inhabited

structure Section where
  name : String
  items : Array Item
  deriving BEq, Repr, Inhabited

abbrev Order := Array Section

/-- The section a command names: `next`, `proposed` or `needs`. -/
def sectionName : String → Option String
  | "next" => some "Next, in order"
  | "proposed" => some "Proposed"
  | "needs" => some "Needs a decision"
  | _ => none

/-- An `issues/ORDER` text read strictly: `## NAME` lines and `ID TITLE`
lines after the first of them, empty lines anywhere; anything else is an
error naming its line. -/
def parse (text : String) : Except String Order := do
  let mut out : Order := #[]
  let mut n := 0
  for line in text.splitOn "\n" do
    n := n + 1
    if line.isEmpty then continue
    if let some name := line.dropPrefix? "## " then
      out := out.push { name := name.toString, items := #[] }
      continue
    if out.isEmpty then throw s!"issues/ORDER line {n}: an item before the first section"
    match line.splitOn " " with
    | id :: rest@(_ :: _) =>
      let title := " ".intercalate rest
      unless isIssueId id && !title.trimAscii.isEmpty do
        throw s!"issues/ORDER line {n}: not `ID TITLE`"
      out := out.modify (out.size - 1) fun s => { s with items := s.items.push { id, title } }
    | _ => throw s!"issues/ORDER line {n}: not `ID TITLE`"
  return out

/-- The text of `o`, in the format `parse` reads and rr writes. -/
def render (o : Order) : String :=
  "\n".intercalate <| o.toList.map fun s =>
    s!"## {s.name}\n" ++ if s.items.isEmpty then "" else
      "\n" ++ String.join (s.items.toList.map fun i => s!"{i.id} {i.title}\n")

def ids (o : Order) : List String :=
  o.toList.flatMap fun s => s.items.toList.map (·.id)

/-- Where the item `id` is: its section's index and its own in it. -/
def locate (o : Order) (id : String) : Option (Nat × Nat) := Id.run do
  for h : k in [0:o.size] do
    if let some j := o[k].items.findIdx? (·.id == id) then return some (k, j)
  return none

def remove (o : Order) (id : String) : Order :=
  o.map fun s => { s with items := s.items.filter (·.id != id) }

/-- Where an item goes. -/
inductive Place where
  | top (sec : String)
  | bottom (sec : String)
  | after (id : String)
  deriving BEq, Repr

def insert (o : Order) (item : Item) : Place → Except String Order
  | .top sec => match o.findIdx? (·.name == sec) with
    | some k => .ok (o.modify k fun s => { s with items := #[item] ++ s.items })
    | none => .error s!"no section `{sec}` in issues/ORDER"
  | .bottom sec => match o.findIdx? (·.name == sec) with
    | some k => .ok (o.modify k fun s => { s with items := s.items.push item })
    | none => .error s!"no section `{sec}` in issues/ORDER"
  | .after other => match locate o other with
    | some (k, j) => .ok (o.modify k fun s =>
        { s with items := (s.items.extract 0 (j + 1)).push item ++ s.items.extract (j + 1) s.items.size })
    | none => .error s!"no item {other} in issues/ORDER"

/-- What is wrong with a queue whose ORDER is `o` and whose item files are
`files` (each id with its file's first line): a section named twice, an id
listed twice, an item without its file or whose file has another title, a
file without its item. Files whose names are no ids (README.md) are not
items. -/
def check (o : Order) (files : List (String × String)) : List String := Id.run do
  let mut bad : List String := []
  let names := o.toList.map (·.name)
  if names.eraseDups.length != names.length then bad := bad ++ ["a section is named twice in issues/ORDER"]
  let listed := ids o
  for id in listed.eraseDups do
    if listed.count id > 1 then bad := bad ++ [s!"{id} is listed more than once in issues/ORDER"]
  for s in o do
    for i in s.items do
      match files.lookup i.id with
      | none => bad := bad ++ [s!"{i.id} is in issues/ORDER but has no issues/{i.id}.md"]
      | some t => if t != i.title then bad := bad ++ [s!"issues/{i.id}.md's title is not its title in issues/ORDER"]
  for (id, _) in files do
    unless listed.contains id do bad := bad ++ [s!"issues/{id}.md is not in issues/ORDER"]
  return bad

/-- The title of an item's text, its first line; none when that is empty. -/
def titleOf (text : String) : Option String :=
  let t := ((text.splitOn "\n").headD "").trimAscii.toString
  if t.isEmpty then none else some t

/-- `id` taken from six random bytes, one character of the queue's alphabet
from each. -/
def idFrom (bytes : ByteArray) : String :=
  let alphabet := "abcdefghijklmnopqrstuvwxyz234567".toList
  String.ofList (bytes.toList.map fun b => alphabet[b.toNat % 32]!)

end Issueq
