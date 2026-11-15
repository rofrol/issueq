import Issueq

/-- `issueq add|move|edit|finish ...`: rr2's `rr2 issue`, without rr2's
settling of its own interrupted integrations (README, "rr2's
integrations"). -/
def main (args : List String) : IO UInt32 :=
  Issueq.cli "issueq" "issueq" (fun _ _ => pure ()) args
