-- A module that type-checks fine; its defs/edges must survive in the
-- --keep-going graph even when a sibling module fails to check.
module Good where

open import Agda.Builtin.Nat

double : Nat → Nat
double n = n + n

quadruple : Nat → Nat
quadruple n = double (double n)
