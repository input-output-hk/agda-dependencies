{-# OPTIONS --safe #-}
module Overloaded where

open import Agda.Builtin.Nat using (Nat; zero)
open import Agda.Builtin.Bool using (Bool; true)
open import Agda.Builtin.Reflection using (Name)

record First : Set where
  constructor pack
  field first : Nat
record Second : Set where
  constructor pack
  field second : Bool
record Third : Set where
  constructor pack
  field third : Nat
record Left : Set where
  constructor mk
  field left : Nat
record Right : Set where
  constructor mk
  field right : Bool

one : First
one = pack zero
two : Second
two = pack true
three : Third
three = pack zero
leftValue : Left
leftValue = mk zero
rightValue : Right
rightValue = mk true

data Fourth : Set where
  wrap : Nat → Fourth
data Fifth : Set where
  wrap : Nat → Fifth

four : Fourth
four = wrap zero
five : Fifth
five = wrap zero

unpackFirst : First → Nat
unpackFirst (pack value) = value
unpackThird : Third → Nat
unpackThird (pack value) = value

quotedFourth : Name
quotedFourth = quote Fourth.wrap
quotedFifth : Name
quotedFifth = quote Fifth.wrap

data Named (name : Name) : Set where

fourthType : Set
fourthType = Named (quote Fourth.wrap)
fifthType : Set
fifthType = Named (quote Fifth.wrap)
