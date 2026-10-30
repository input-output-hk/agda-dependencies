{-# OPTIONS --safe --without-K #-}
module representations where

open import Agda.Builtin.Bool using (Bool)
open import Agda.Builtin.Nat using (Nat; zero)
open import Agda.Builtin.Sigma using (Σ)

Arrow : Set → Set → Set
Arrow A B = A → B

data Payload (A : Set) : Set where
  pack : {x : Bool} → Arrow A (Payload A)

record Pair (A : Set) : Set where
  constructor pair
  field
    first : A
    second : Bool

record NoEta : Set where
  no-eta-equality
  constructor no-eta
  field bit : Bool

module Section (A : Set) where
  data Stored (B : Set) : Set where
    store : A → B → Stored B

data Choice : Set where
  left right : Bool → Choice

data Indexed : Nat → Set where
  only-zero : Indexed zero

mutual
  data Recursive : Set where
    roll : Other → Recursive
  data Other : Set where
    other : Recursive → Other

abstract
  data Secret : Set where
    secret : Bool → Secret

Alias : Set → Set
Alias A = Σ A (λ _ → Bool)
