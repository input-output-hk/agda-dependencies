{-# OPTIONS --safe #-}
-- Fixture for the phase-2 `matchConstant` PROBE (`AgdaDeps.MatchConstant`).
--
-- The probe is not a shipped feature: it emits nothing to the wire and runs
-- only under `AGDA_DEPS_MATCH_CONSTANT=1`, where it dumps `MC-CAND` /
-- `MC-HIT` lines to stderr. This corpus is what keeps the analysis honest,
-- since no golden covers it — every row below is asserted in CI.
--
-- A "match-constant" position is one whose case split could be replaced by a
-- wildcard without changing any clause. The rows fall into three groups:
-- cases that must fire, controls that must not, and the two guards that were
-- not in the design note (the type-refinement guard, and the rule that EVERY
-- split on an argument must be collapsible).
module MC where

data Bool : Set where
  true  : Bool
  false : Bool

data Nat : Set where
  zero : Nat
  suc  : Nat → Nat

data Maybe (A : Set) : Set where
  nothing : Maybe A
  just    : A → Maybe A

data Empty : Set where

data _≡_ {A : Set} (x : A) : A → Set where
  refl : x ≡ x

not : Bool → Bool
not true  = false
not false = true

-- FIRES. The motivating case: both branches return the same thing and the
-- split decides nothing. Expect mc=[0].
f1 : Bool → Nat → Nat
f1 true  b = b
f1 false b = b

-- Control: the branches genuinely differ.
f2 : Bool → Nat → Nat
f2 true  b = b
f2 false _ = zero

-- Control: a branch reads the constructor's FIELD, so the slab cannot be
-- removed.
f3 : Maybe Nat → Nat → Nat
f3 (just x) _ = x
f3 nothing  b = b

-- FIRES with a constructor of arity > 0: `just`'s field is ignored and both
-- branches return `b`. This is the case the slab substitution exists for --
-- the two branches live in contexts of different size. Expect mc=[0].
f4 : Maybe Nat → Nat → Nat
f4 (just _) b = b
f4 nothing  b = b

-- Control: an absurd (`Fail`) branch. The match computes nothing but is
-- load-bearing for coverage.
f5 : Empty → Nat → Nat
f5 () b

-- FIRES through a catch-all: one explicit constructor plus a wildcard clause
-- computing the same thing. The catch-all keeps the matched variable, so it
-- is treated as a slab of size 1 -- and "does not look at the fields"
-- becomes "does not look at the matched value". Expect mc=[0].
f6 : Bool → Nat → Nat
f6 true b = b
f6 _    b = b

-- Control: a catch-all that USES the matched value.
f7 : Bool → (Bool → Nat) → Nat
f7 true g = g true
f7 x    g = g x

-- Control for the every-split rule: argument 1 is split under both branches
-- of argument 0 -- decoratively under `true`, load-bearingly under `false`.
-- Wildcarding argument 1 would change `f8 false false`, so position 1 must
-- NOT be reported even though one of its two splits is collapsible.
f8 : Bool → Bool → Nat → Nat
f8 true  true  b = b
f8 true  false b = b
f8 false true  b = b
f8 false false _ = zero

-- FIRES inside a `where` helper, and the index must be a position on the
-- HELPER's own signature (its 0), not on the parent's prepended binders.
-- Same section shift as phase 1.
f9 : Nat → Nat → Nat
f9 a b = helper true b
  where
    helper : Bool → Nat → Nat
    helper true  y = y
    helper false y = y

-- Control: record built by copatterns (`projPatterns`), not a match.
record R : Set where
  field
    fst : Nat
    snd : Nat
open R

mkR : Nat → R
fst (mkR n) = n
snd (mkR n) = n

-- FIRES with mixed arities: `zero` binds nothing, `suc` binds a field that
-- is ignored. Expect mc=[0].
f10 : Nat → Nat → Nat
f10 zero    b = b
f10 (suc _) b = b

-- CONTROL FOR THE TYPE-REFINEMENT GUARD -- the row the design note's property
-- gets wrong. Both bodies are the identical term `refl` (a constructor's
-- parameters are dropped in internal syntax, so `refl` here really is nullary),
-- so "every branch computes the same thing" holds and a body-only comparison
-- calls this collapsible. But `notInv _ = refl` does NOT typecheck: the goal
-- type `not (not x) ≡ x` only reduces once `x` is known. The match is
-- load-bearing for TYPE-CHECKING. On the standard library this shape is 101 of
-- 102 raw candidates, so without this guard the analysis is almost entirely
-- wrong. Expect nothing.
notInv : (x : Bool) → not (not x) ≡ x
notInv true  = refl
notInv false = refl
