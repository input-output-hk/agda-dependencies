-- Regression test for the postModuleAD signature-walk fix
-- (FeaturesAdded.md, 2026-05-25 follow-up).
--
-- `dead-priv` is a top-level private definition with no caller
-- anywhere — neither inside nor outside this module. Before the fix
-- Agda's `eliminateDeadCode` pruned it from `iSignature` before the
-- backend `compileDef` hook fired, so agda-deps never saw it. After
-- the fix the JSON's `definitions[]` lists all four functions below.
module DeadPrivate where

open import Agda.Builtin.Nat

public-fn : Nat → Nat
public-fn x = x

private
  reachable-priv : Nat → Nat
  reachable-priv x = x + 1

  -- dead: no caller anywhere; must still appear in the graph
  dead-priv : Nat → Nat
  dead-priv x = reachable-priv x + 2

public-fn-deep : Nat → Nat
public-fn-deep x = reachable-priv x
