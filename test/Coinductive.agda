{-# OPTIONS --guardedness #-}
module Coinductive where

open import Nat using (Nat; zero; suc; _+_)

-- A classic coinductive record: an infinite stream.
record Stream {a} (A : Set a) : Set a where
  coinductive
  field
    head : A
    tail : Stream A

open Stream public

-- The constant-zero stream. Forces the CoinductiveConstructor
-- highlighting class in the rendered snippet for `Stream`'s field
-- copatterns.
zeros : Stream Nat
head zeros = zero
tail zeros = zeros

-- Element-wise successor of a Nat stream. Exercises a coinductive
-- consumer as well: the result is a Stream, defined by copattern
-- matching on its projections.
mapSuc : Stream Nat -> Stream Nat
head (mapSuc s) = suc (head s)
tail (mapSuc s) = mapSuc (tail s)
