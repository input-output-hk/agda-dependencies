{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
-- | The naming convention for graph nodes: how a live 'QName' becomes the
-- identity string on the wire ('nodeKeyForDefinition') and the module it is
-- attributed to ('moduleKeyOfQ'). Constructor identities additionally use
-- their compiler definition's owner. The resolved naming is shared by
-- the producer ("AgdaDeps.Deps", which stores them in each 'NodeRef') and
-- the subterm hasher ("AgdaDeps.TermCanon"), so a hashed reference names
-- the same node the graph does. Changing the convention means bumping
-- 'AgdaDeps.Deps.nodeKeyVersion'.
module AgdaDeps.NodeKey
  ( nodeKeyOfQ
  , nodeKeyForDefinition
  , nodeKeyResolver
  , nodeKeyFromPretty
  , moduleKeyOfQ
  , bindingLineOfQ
  , liftAnonSegments
  ) where

import Control.Applicative ( (<|>) )
import Data.List ( intercalate, isInfixOf )

import Agda.Syntax.Abstract.Name ( QName, nameBindingSite, nameCanonical )
import Agda.Syntax.Common.Pretty ( prettyShow )
import Agda.Syntax.Internal ( qnameModule, qnameName )
import Agda.Syntax.Position ( posLine, rStart )
import Agda.TypeChecking.Monad
  ( TCM, Definition(..), pattern Constructor, conData
  , getSignature, useTC, stImports, lookupDefinition )

import AgdaDeps.Util ( splitOn )

-- | Canonical node-identity string for a 'QName'. Anonymous-module segments
-- (the @._.@ marker Agda uses for both @where@ helpers and @module _ (…)
-- where@ members) are lifted into the nearest named ancestor via
-- 'liftAnonSegments' (@Mod._.helper@ ↦ @Mod.helper@). Lifting collapses the
-- @_@ qualifier, so same-named helpers are disambiguated by binding line
-- (@Mod.helper\@15@); one with no binding site falls back to the lifted name.
--
-- Base identity for non-constructors. Emission uses 'nodeKeyForDefinition' or
-- 'nodeKeyResolver' so constructor owners remain distinct. Stored as @nrKey@;
-- the wire @"name"@ and edge endpoints use that resolved string. Do not revert to bare
-- 'prettyShow': same-named @where@-helpers collapse onto one node and lose
-- their edges. 'moduleKeyOfQ' is the matching module-attribution function.
nodeKeyOfQ :: QName -> String
nodeKeyOfQ qn = nodeKeyFromPretty (prettyShow qn) (bindingLineOfQ qn)

-- | Constructors belong to their declared datatype/record, even when Agda
-- prints an overloaded constructor in the enclosing module. Qualifying by
-- the owner preserves identity without changing source spellings or relying
-- on process-local compiler counters.
nodeKeyForDefinition :: Definition -> String
nodeKeyForDefinition def = case theDef def of
  Constructor{conData = owner} ->
    nodeKeyOfQ owner ++ "." ++ prettyShow (nameCanonical (qnameName (defName def)))
  _ -> nodeKeyOfQ (defName def)

-- | Immutable compiler-signature snapshot for pure codecs and hashes. Identity
-- lookup does not unfold a body or cross abstraction/opacity for computation.
-- Force encoded names before retaining a result, so the snapshot can be freed.
nodeKeyResolver :: TCM (QName -> String)
nodeKeyResolver = do
  local <- getSignature
  imported <- useTC stImports
  pure $ \q -> maybe (nodeKeyOfQ q) nodeKeyForDefinition
    (lookupDefinition q local <|> lookupDefinition q imported)

-- | 'nodeKeyOfQ' with the @prettyShow@ string and binding line supplied by
-- a caller implementing a base (non-constructor) identity.
nodeKeyFromPretty :: String -> Maybe Int -> String
nodeKeyFromPretty raw mbLine
  | "._." `isInfixOf` raw          -- where-helper marker (cf. 'nrWhereHelper')
  , Just ln <- mbLine = lifted ++ "@" ++ show ln
  | otherwise         = lifted
  where lifted = liftAnonSegments raw

-- | Canonical owning-module string for a 'QName', with anonymous sub-modules
-- lifted away via 'liftAnonSegments' so attribution lands on the nearest
-- named module (@Mod._@ ↦ @Mod@). Every QName→module derivation must route
-- through this, or phantom @Mod._@ nodes surface and set membership drifts.
moduleKeyOfQ :: QName -> String
moduleKeyOfQ = liftAnonSegments . prettyShow . qnameModule

-- | 1-indexed start line of a 'QName''s binding site, if Agda recorded a
-- usable range. Synthetic names (e.g. @unsolved#meta.*@) return 'Nothing'.
bindingLineOfQ :: QName -> Maybe Int
bindingLineOfQ qn =
  let r = nameBindingSite (qnameName qn)
  in fromIntegral . posLine <$> rStart r

-- | Drop bare-@_@ dot-segments from a dotted qualified name, lifting
-- @where@-block and parameterised-section defs (Agda desugars both into
-- anonymous @Parent._@ sub-modules) into their nearest named ancestor:
-- @"M._.N"@ ↦ @"M.N"@, @"M._"@ ↦ @"M"@. Only whole @"_"@ segments are
-- dropped, so mixfix names (@_+_@) survive.
liftAnonSegments :: String -> String
liftAnonSegments = intercalate "." . filter (/= "_") . splitOn '.'
