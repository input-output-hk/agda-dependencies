{-# OPTIONS --safe #-}
module Where where

open import Nat using (Nat; zero; suc; _+_; _*_)
open import List using (List; []; _∷_)

-- A function with a where clause containing several nested helpers.
-- Tests both that paragraphBounds spans the full where-block in the
-- highlighted snippet and that the where-generated helpers are still
-- filtered out by ignoreDef (they should not appear as separate nodes
-- in the graph — only `sumSquares` should).
sumSquares : List Nat -> Nat
sumSquares xs = go xs
  where
    sq : Nat -> Nat
    sq n = n * n

    go : List Nat -> Nat
    go []       = zero
    go (n ∷ ns) = sq n + go ns

-- A second `where`-using function so the paragraph extraction has to
-- correctly bound *two* such blocks in the same source file.
weirdSum : Nat -> Nat -> Nat
weirdSum a b = bump (a + b)
  where
    bump : Nat -> Nat
    bump n = n + n
