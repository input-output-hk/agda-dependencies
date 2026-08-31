{-# OPTIONS --allow-unsolved-metas --guardedness #-}
module _ where

-- open import Agda.Builtin.Nat using (Nat; _+_; _*_)
-- open import Agda.Builtin.List using (List; []; _∷_)
open import Nat using (Nat; _+_; _*_; zero)
open import List using (List; []; _∷_)
open import Holes using (magic; incomplete; useMagic)
open import Coinductive using (Stream; zeros; mapSuc)
open import Records using (Point; sumCoords; origin; double)
open import Where using (sumSquares; weirdSum)
open import Collision using (useA; useB)  -- E1 regression: same-named `where` helpers
open import InlineGap using (useInline; useAlias)  -- inliner-gap characterisation (#3)
open import AnonSection using (useSection)  -- anonymous-module section lifting (nodeKeyVersion 3)
import RenamedReexport  -- R14 fixture. Qualified (no `open`) on purpose: `open`ing pulls the Nat->Number alias into scope and reprints every --with-signatures type as `Number`.
import Unsafe  -- R12 fixture (soundness escapes). Qualified (no `open`) to keep its names out of scope, same rationale as RenamedReexport above.
import OptionEscapes  -- R15 fixture (file-level {-# OPTIONS #-} escapes). Qualified; --type-in-type is non-infective so Test stays unaffected.
import ArgUsage  -- M1 fixture (never-used arguments). Qualified: its `Vec`/`Box`/`ident` names would otherwise collide with the corpus.

variable a b : Set

-- ** Datatypes & functions

data Exp (v : Set) : Set where
  Plus : Exp v → Exp v → Exp v
  Int : Nat → Exp v
  Var : v → Exp v
{-# COMPILE AGDA2?? Exp #-}

eval : (a → Nat) → Exp a → Nat
eval env (Plus a b) = eval env a + eval env b
eval env (Int n) = n
eval env (Var x) = env x
{-# COMPILE AGDA2?? eval #-}

eval' : (a → Nat) → Exp a → Nat
eval' env _ = zero

-- ** Natural numbers

sum : List Nat → Nat
sum []       = zero
sum (x ∷ xs) = x + sum xs
{-# COMPILE AGDA2?? sum #-}

-- ** Polymorphic functions

_++_ : List a → List a → List a
[]       ++ ys = ys
(x ∷ xs) ++ ys = x ∷ (xs ++ ys)
{-# COMPILE AGDA2?? _++_ #-}

map : (a → b) → List a → List b
map f [] = []
map f (x ∷ xs) = f x ∷ map f xs
{-# COMPILE AGDA2?? map #-}

{-
-- ** Lambdas

plus3 : List Nat → List Nat
plus3 = map (λ n → n + 3)
{-# COMPILE AGDA2?? plus3 #-}

doubleLambda : Nat → Nat → Nat
doubleLambda = λ a b → a + 2 * b
{-# COMPILE AGDA2?? doubleLambda #-}

-- ** Modules

module M (n : Nat) where
  increase : Nat → Nat
  increase = _+ n

open M 1 renaming (increase to increment)

testModule : Nat
testModule = increment 41
-- -}
-- -}
-- -}
-- -}
