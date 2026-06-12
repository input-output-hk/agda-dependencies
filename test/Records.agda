{-# OPTIONS --safe #-}
module Records where

open import Nat using (Nat; zero; suc; _+_; _*_)

-- A record with multiple fields, deliberately not using a manifest
-- pattern constructor so the projections show up as Field-coloured
-- references in the highlighted snippet.
record Point : Set where
  field
    x : Nat
    y : Nat

open Point public

-- A "constructor" via copattern matching.
mkPoint : Nat -> Nat -> Point
x (mkPoint a _) = a
y (mkPoint _ b) = b

-- A function that uses both fields. Triggers Field highlighting at the
-- two projection sites and re-uses the `Nat` operators imported above.
sumCoords : Point -> Nat
sumCoords p = x p + y p

-- Constant Point, exercising the field-by-name projection path again
-- via a copattern definition.
origin : Point
x origin = zero
y origin = zero

-- A second record with a different shape, so multiple records co-exist
-- in the corpus (paragraphBounds will see independent blocks).
record Box (A : Set) : Set where
  field
    contents : A
    count    : Nat

open Box public

double : Box Nat -> Nat
double b = count b * count b
