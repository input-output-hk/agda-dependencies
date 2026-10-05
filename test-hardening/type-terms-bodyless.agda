module type-terms-bodyless where

{-# TERMINATING #-}
T : Set
T = T

postulate p : T

data Empty : Set where

absurd : Empty → Empty
absurd ()
