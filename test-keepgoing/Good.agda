-- A module that type-checks fine; its defs/edges must survive in the
-- --keep-going graph even when a sibling module fails to check.
module Good where

open import Agda.Builtin.Nat

double : Nat → Nat
double n = n + n

quadruple : Nat → Nat
quadruple n = double (double n)

-- Section-telescope coverage for the partial pass. Agda prepends the
-- enclosing section's telescope to a `where` helper, so `helper`'s
-- elaborated arity is 2 (`n` from the parent, then its own argument) while
-- its own signature has 1. `argUsage` subtracts that prefix via
-- `lookupSection`, which under --keep-going only works if
-- `mergeIfaceSig` merged `sigSections` -- and `lookupSection` FALLS BACK to
-- EmptyTel rather than failing, so a dropped merge is silent. Asserting
-- arity 1 here makes it loud.
withHelper : Nat → Nat
withHelper n = helper n
  where
    helper : Nat → Nat
    helper _ = zero
