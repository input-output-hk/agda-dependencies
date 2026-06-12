{-# OPTIONS --safe #-}
module Nat where

open import Bool

data Nat : Set where
  zero : Nat
  suc  : (n : Nat) → Nat

infix  4 _==_ _<_
infixl 6 _+_ _-_
infixl 7 _*_

_+_ : Nat → Nat → Nat
zero  + m = m
suc n + m = suc (n + m)

_-_ : Nat → Nat → Nat
n     - zero = n
zero  - suc m = zero
suc n - suc m = n - m

_*_ : Nat → Nat → Nat
zero  * m = zero
suc n * m = m + n * m

_==_ : Nat → Nat → Bool
zero  == zero  = true
suc n == suc m = n == m
_     == _     = false

_<_ : Nat → Nat → Bool
_     < zero  = false
zero  < suc _ = true
suc n < suc m = n < m
