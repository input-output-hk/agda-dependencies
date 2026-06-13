-- A module whose type-check FAILS via instance resolution, leaving
-- unsolved metavariables in the TCM state (mirrors the
-- Jolteon-FastBFT TestTrace failure: Agda cannot pick an instance for
-- a _>>=_, leaving unsolved instance metas). The --keep-going partial
-- pass must survive this and still emit a graph.
module Broken where

open import Agda.Builtin.Nat
open import Good

record Pack (A : Set) : Set where
  field unpack : A

open Pack {{...}}

-- No Pack Nat instance is in scope: instance search fails and the
-- instance meta (and the type metas threaded through it) stay open.
use : Nat
use = unpack + double 1
