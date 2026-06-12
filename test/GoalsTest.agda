{-# OPTIONS --allow-unsolved-metas #-}
-- | Fixture for agda-goals. Hand-crafted to demonstrate
-- canonicalisation: several holes of type `Nat -> Nat`, several of
-- type `Nat`, one of type `List Nat -> Nat`. The biggest bucket
-- should be `Nat -> Nat` (3 occurrences).
module GoalsTest where

open import Nat using (Nat; _+_; zero; suc)
open import List using (List; []; _∷_)

-- Three holes of type Nat -> Nat.
double : Nat → Nat
double = ?

triple : Nat → Nat
triple = ?

negate? : Nat → Nat
negate? = ?

-- Two holes of type Nat.
zeroOrSomething : Nat
zeroOrSomething = ?

oneOrSomething : Nat
oneOrSomething = ?

-- One hole of type List Nat -> Nat.
sumList : List Nat → Nat
sumList = ?
