module type-terms where

open import Agda.Builtin.Nat
open import Agda.Builtin.Equality
open import Agda.Builtin.Reflection using (Name)

StateProperty = Nat → Set

AtLeast≥ : Nat → StateProperty
AtLeast≥ k = λ s → k ≡ s

One : StateProperty
One = AtLeast≥ 1

postulate
  Named : Name → Set
  quotedNat : Named (quote Nat)

module _ where
  postulate local : Set

  postulate quotedLocal : Named (quote local)
