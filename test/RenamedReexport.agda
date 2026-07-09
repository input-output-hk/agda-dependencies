{-# OPTIONS --safe #-}
module RenamedReexport where

-- R14 fixture: a public re-export carrying a `renaming` alias.
--
-- `open … public renaming (Nat to Number)` re-exports every public name
-- of module `Nat`, but the `Nat` type is renamed to `Number` in this
-- module's scope. The expanded graph.json `reexports[]` row for
-- (from = RenamedReexport, to = Nat) must therefore carry a `renames`
-- object mapping the in-scope alias `Number` to the canonical FQN
-- `Nat.Nat`. Every other re-exported name is un-renamed and stays out of
-- `renames`, so the map is a proper subset of `names`.
open import Nat public renaming (Nat to Number)
