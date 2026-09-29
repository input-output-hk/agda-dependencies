{-# OPTIONS --safe #-}
module Access where

open import Nat using (Nat; zero; suc)

-- Access back-fill regression (findPrivateRanges): a `private` block is
-- bounded by its own indentation, not by the next column-0 line. `shown`
-- is a public sibling of the indented private block inside `Sub`, and was
-- once reported private because that block ran on to `visible`.

private
  hidden : Nat
  hidden = zero

module Sub where
  private
    inner : Nat
    inner = suc zero

  shown : Nat
  shown = inner

visible : Nat
visible = hidden
