{-# OPTIONS --safe #-}
module Collision where

open import Nat using (Nat; zero; suc; _+_)

-- Two distinct targets, so each same-named `where` helper has its own
-- out-edge. Tests E1: distinct `where` helpers that share a simple name
-- (`QED`) inside one module must stay distinct graph nodes, and their
-- edges (useA ⇝ targetA, useB ⇝ targetB) must both survive.

targetA : Nat
targetA = zero

targetB : Nat
targetB = suc zero

useA : Nat
useA = QED
  where
    QED : Nat
    QED = targetA

useB : Nat
useB = QED
  where
    QED : Nat
    QED = targetB
