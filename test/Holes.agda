{-# OPTIONS --allow-unsolved-metas #-}
module Holes where

open import Nat using (Nat; _+_; zero; suc)

-- ** Postulate: classified as Postulate (red)
postulate
  magic : Nat

-- ** Unsolved hole: classified as Hole (purple)
incomplete : Nat → Nat
incomplete n = ?

-- ** Fully defined (uses a postulate as a dependency): classified as Defined (green)
useMagic : Nat
useMagic = magic + magic
