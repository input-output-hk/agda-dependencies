{-# OPTIONS --safe #-}
-- Fixture for the per-def `argUsage` field: arguments a definition never
-- actually uses, read off Agda's own positivity/polarity analysis
-- (`AgdaDeps.Deps.argUsageOf`).
--
-- Indices below are telescope positions, implicits included, so they are
-- counted from 0 over the whole binder spine.
module ArgUsage where

open import Nat using (Nat; zero; suc; _+_)

-- f1: the direct case. The first argument is bound and never mentioned.
-- Expect removable: [0].
f1 : Nat → Nat → Nat
f1 _ b = b

-- f2: the TRANSITIVITY WITNESS. `a` is genuinely used in f2's own body --
-- it is handed to `helper` -- so a purely local "does the body mention
-- it" check would call it used. Agda composes the occurrence "as argument
-- 0 of helper" with helper's own stored occurrence for that argument, and
-- helper discards it, so the verdict propagates. Expect removable: [0].
f2 : Nat → Nat → Nat
f2 a b = helper a b
  where
    helper : Nat → Nat → Nat
    helper _ y = y

-- f3: the JOINT CHAIN. `x : X` is typed by the preceding `X`, so naively
-- `X` looks needed. But `dependentPolarity` ignores the domains of other
-- Nonvariant arguments (`relevantInIgnoringNonvariant`), and `x` is itself
-- Nonvariant, so BOTH leading arguments stay Nonvariant: a "remove these
-- together" set, not two independent removals. Expect removable: [0,1].
f3 : (X : Set) → X → Nat → Nat
f3 _ _ b = b

-- f4: control -- every argument genuinely used. Must emit NO argUsage key.
f4 : Nat → Nat → Nat
f4 a b = a + b

-- A local unary index for `Vec`, deliberately NOT the shared `Nat`.
-- `test/RenamedReexport.agda` re-exports `Nat`'s constructors, so `suc` is
-- ambiguous in the entry module's scope, and Agda 2.8 / 2.9 tie-break the
-- name that `--with-signatures` reifies differently (`Nat.suc` vs
-- `RenamedReexport.suc`) -- a spurious 2.8/2.9 golden mismatch that has
-- nothing to do with what this fixture pins.
data Idx : Set where
  ze : Idx
  su : Idx → Idx

-- f5: control -- the argument is used, but only in a LATER ARGUMENT'S
-- TYPE. `dependentPolarity` demotes it to Invariant rather than leaving it
-- Nonvariant, so it must not be reported as removable.
data Vec (A : Set) : Idx → Set where
  []  : Vec A ze
  _∷_ : {n : Idx} → A → Vec A n → Vec A (su n)

f5 : (n : Idx) → Vec Nat n → Nat
f5 _ []       = zero
f5 _ (x ∷ _)  = x

-- A projection and a constructor: both drop parameters from defPolarity /
-- defArgOccurrences, so their indices are shifted off the telescope and
-- phase 1 skips them outright (`droppedPars /= 0`). Must emit NO argUsage
-- key even though `unusedField` is never read.
record Box (A : Set) : Set where
  constructor box
  field
    content    : A
    unusedTag  : Nat

open Box public

-- Uses the projection, so `Box`/`box`/`content` are all reachable nodes.
unbox : Box Nat → Nat
unbox b = content b

-- Section telescopes. Agda prepends the enclosing section's binders to
-- every definition inside it, so the ELABORATED telescope of `keeps` is
-- (k, a, b) and of `drops` is (k, a, b) too -- longer than either
-- signature line. Indices are reported over the definition's OWN binders,
-- so the section parameter `k` is never reported even when unused.
module Section (k : Nat) where

  -- Uses `k`, drops its own first argument. Expect removable: [0] --
  -- index 0 being `a`, NOT the section's `k`.
  keeps : Nat → Nat → Nat
  keeps _ b = k + b

  -- Ignores the section parameter AND its own first argument. The `k`
  -- position is dropped as not-this-definition's-to-remove, so this is
  -- still removable: [0].
  drops : Nat → Nat → Nat
  drops _ b = b

  -- Named own binders inside a section: `binders` must name the
  -- definition's OWN binder (`m`), never the section's `k`. Reading the
  -- name before the section shift would report `k` here -- the exact
  -- misalignment the shift exists to prevent.
  named : (m : Nat) → (p : Nat) → Nat
  named _ p = k + p

-- A `where` helper that wastes ONLY its parent's arguments and uses every
-- binder of its own. After the section prefix is dropped nothing is left,
-- so `wasteful`'s helper must emit NO argUsage key.
wasteful : Nat → Nat → Nat
wasteful a b = inner (a + b)
  where
    inner : Nat → Nat
    inner z = z

-- The `erasable` half of the verdict: an argument that never occurs in
-- the body but IS needed by the type of a later argument. `{A : Set}` in
-- a polymorphic identity is the canonical case -- it cannot be deleted
-- (the next binder is typed by it), only erased, so it is an `@0`
-- candidate rather than a removal.
ident : {A : Set} → A → A
ident a = a

-- `removableRequires`: the CHAIN. All three of `X`, `x : X` and `v : Vec X n`
-- are unused, but they are not independent -- `X` appears in the type of
-- both later binders, and `x` in neither. Deleting `v` alone is fine;
-- deleting `X` strands both. Expect removable [0,1,3] with
-- removableRequires {"0": [1,3]} -- and NOT an entry for 1 or 3, since
-- neither drags anything else along.
chain : (X : Set) → X → (n : Idx) → Vec X n → Idx
chain _ _ n _ = n

-- `removableRequires`: INDEPENDENT removals. Both `a` and `c` are unused
-- and neither appears in the other's type, so each can go on its own.
-- Expect removable [0,2] and NO removableRequires key at all -- this is
-- the case a symmetric "groups" encoding could not express.
indep : Nat → Nat → Nat → Nat
indep _ b _ = b

-- `binders`: the reported position's name and hiding, read off the
-- syntactic Pi spine of the definition's type (`AgdaDeps.Deps.piSpine`).
-- Instance arguments are the third hiding; a named one pins both halves.
record Def (A : Set) : Set where
  field def : A

useless : ⦃ d : Def Nat ⦄ → Nat → Nat
useless b = b

-- `binders` past the end of the spine. `defType` here is the *unreduced*
-- `Fun`, so the syntactic spine has no binders at all, while the stored
-- occurrence/polarity lists (computed on the reduced spine) have one. The
-- verdict is still reported; the binder simply is not, so there must be NO
-- `binders` key -- silence, not a guessed "explicit".
Fun : Set
Fun = Nat → Nat

opaqueArg : Fun
opaqueArg _ = zero

-- Generalisation. A `variable` the signature mentions is INSERTED as a
-- leading binder, and so is each of that variable's own dependencies --
-- neither is written on the signature line. Agda names a mentioned
-- variable after itself (`A`, indistinguishable from a written binder)
-- and a dependency after its path (`P.A`). A source binder name can never
-- contain `.`, so the dotted form is a sound signal that the position has
-- no binder to edit; `binders` reports it exactly as Agda's own printer
-- spells it (the `type` string shows `P.A` too).
variable
  A : Set
  P : A → Set

-- Inserted `{A : Set}` at 0 (named `A`), the discarded own binder at 1.
genMentions : A → Nat → Nat
genMentions _ b = b

-- Mentions `P` only, so `A` is inserted as P's dependency and named
-- `P.A`: expect binders {"0": {"implicit", "P.A"}, "1": {"implicit", "P"}}.
genDependency : (∀ {x} → P x) → Nat → Nat
genDependency _ b = b

-- IRRELEVANCE: the deletability guard (`Deps.guardDeletable`). Agda's verdict
-- answers "does the meaning depend on this value"; `removable` claims "the
-- binder can be deleted". They come apart when the argument occurs in the type
-- only at an IRRELEVANT position: `dependentPolarity` tests occurrence with
-- `relevantInIgnoringSortAnn`, whose `RelevantIn` monoid discards occurrences
-- under irrelevance, so the position stays `Nonvariant`/`Unused` and looks
-- removable -- while deleting the binder leaves the type mentioning a name
-- that is no longer in scope.
data Wrap (n : Nat) : Set where
  wrap : Wrap n

-- A type family that consumes its second argument irrelevantly.
Irrel : Nat → .(Nat) → Set
Irrel n _ = Wrap n

-- Shape A: the binder is itself IRRELEVANT and occurs in the codomain.
-- Must emit nothing for position 1.
irrInCodomain : (n : Nat) → .(p : Nat) → Irrel n p
irrInCodomain n p = wrap

-- Shape B: the binder is RELEVANT, and its only occurrence is at an
-- irrelevant argument position of a callee. Invisible to any "is this binder
-- irrelevant?" test, so it is the case a consumer-side filter could not catch.
-- Must emit nothing for position 1.
relAtIrrelevantPosition : (n : Nat) → (p : Nat) → Irrel n p
relAtIrrelevantPosition n p = wrap

-- Control: an irrelevant argument that is genuinely never mentioned anywhere.
-- This one IS deletable and must still be reported -- the guard must filter,
-- not blanket-reject irrelevance. Expect removable [1].
irrUnmentioned : (n : Nat) → .(p : Nat) → Nat
irrUnmentioned n _ = n
