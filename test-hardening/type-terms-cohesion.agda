{-# OPTIONS --cohesion #-}
module type-terms-cohesion where

module Flat (@♭ A : Set) where
  postulate
    value : A

  module Nested (B : Set) where
    postulate
      nested : A → B → A
