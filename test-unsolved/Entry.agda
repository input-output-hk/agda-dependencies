-- Entry module for the silent-unsolved-meta corpus. Contains an HONEST
-- interaction hole (`?`): it must classify as state H with NO
-- `unsolvedMetas` count and NO `unsolvedModules` row for this module —
-- the split between "open goal the author can see" and "silently
-- un-produced evidence" is the whole point of the fixture.
module Entry where

open import MetaProbe

honest : ℕ
honest = ?

double : ⊥
double = use
