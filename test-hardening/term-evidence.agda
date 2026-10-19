{-# OPTIONS --safe #-}
module term-evidence where

open import Agda.Builtin.Nat
open import Agda.Builtin.Equality
open import Agda.Builtin.List

Time : Set
Time = Nat

record Clock : Set where
  constructor clock
  field delta : Time
open Clock

right-zero : ∀ {n : Nat} → n + 0 ≡ n
right-zero {zero} = refl
right-zero {suc n} rewrite right-zero {n} = refl

shift : Nat → Nat
shift n = n + 0

shift-again : Nat → Nat
shift-again n = n + 0

projected : (c : Clock) → delta c + 0 ≡ delta c
projected c = right-zero

implicit : ∀ {n : Nat} → n + 0 ≡ n
implicit {n} = right-zero

select : Nat → Nat
select zero = 0
select (suc n) with n
... | zero = 1
... | suc m = m + 0

map : ∀ {A B : Set} → (A → B) → List A → List B
map f [] = []
map f (x ∷ xs) = f x ∷ map f xs

mapped : (Nat → Nat) → List Nat → List Nat
mapped f xs = map f (map shift xs)

mapped-again : (Nat → Nat) → List Nat → List Nat
mapped-again f xs = map f (map shift-again xs)

postulate-free-proof : ∀ {n : Nat} → shift n ≡ n
postulate-free-proof = right-zero

module Section (base : Nat) where
  compute : Nat → Nat
  compute n = base + (n + 0)

data Empty : Set where

absurd : Empty → Nat
absurd ()

data Indexed : Nat → Set where
  token : (n : Nat) → Indexed n

dotted : (n : Nat) → Indexed n → Nat
dotted .n (token n) = n

literal : Nat → Nat
literal 10 = 1
literal _ = 2

open import Agda.Builtin.Char using (Char)
character : Char → Nat
character 'a' = 1
character _ = 2

successor : Nat → Nat
successor n = suc (n + 0)

-- Empty records have an implicit constructor but no field domains that could
-- accidentally hide a section count including the record module's self value.
module ConstructorSection (A : Set) where
  record EmptyRecord (a : A) : Set where

  makeEmpty : (a : A) → EmptyRecord a
  makeEmpty a = record {}
