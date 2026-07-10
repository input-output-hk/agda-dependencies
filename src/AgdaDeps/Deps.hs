{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
-- | Dependency analysis: walks each 'Definition' to extract its direct
-- lemma/postulate/data dependencies ('computeDefAD' / 'compileDefAD'),
-- classifies it as 'Defined' / 'Postulate' / 'Hole' ('classifyDef'),
-- and filters compiler-generated definitions out of the graph
-- ('ignoreDef'). Node identity is 'nodeKey' / 'hashQName'; edge
-- provenance is 'EdgeProv' / 'tagOne'.
module AgdaDeps.Deps
  ( -- * The per-definition record
    ADDef(..)
  , DefKind(..)
  , DefAccess(..)
  , UnsafeTag(..)

    -- * Module-level soundness escapes (file @OPTIONS@ pragmas)
  , safetyRelevantOptionFlags
  , optionEscapes

    -- * Edge provenance
  , EdgeProv(..)
  , provPrec
  , provTag

    -- * Hashing & QName collection
  , nodeKey
  , moduleKey
  , nodeKeyVersion
  , hashQName
  , collectAllQNames

    -- * Building 'ADDef's
  , computeDefAD
  , compileDefAD

    -- * Classification (for node colouring)
  , classifyDef
  , classifyKind
  , isUnsolvedMetaName

    -- * Filtering compiler-generated noise
  , ignoreDef
  , ignoreDependency

    -- * Side-channel: edges through ignored defs
  , IgnoredEdgeMap
  , ignoredEdgesRef
  , resetIgnoredEdges
  , recordIgnoredDef
  , readIgnoredEdges
  , mergeIgnoredEdges
  , expandThroughIgnored
  , contractIgnoredEdges

    -- * Side-channel: instance-method providers
  , MethodProviderMap
  , methodProvidersRef
  , resetMethodProviders
  , recordMethodProviders
  , readMethodProviders
  , mergeMethodProviders
  , addInstanceMethodEdges
  ) where

import Control.DeepSeq ( NFData(..) )
import Control.Monad ( filterM )
import Control.Monad.IO.Class ( MonadIO(liftIO) )
import Data.IORef ( IORef, modifyIORef', newIORef, readIORef, writeIORef )
import Data.List ( foldl', isInfixOf, isPrefixOf )
import Data.Maybe ( isJust, mapMaybe )
import Data.Map.Strict ( Map )
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Set ( Set )
import qualified Data.Set as S
import Data.Sequence ( Seq, (|>) )
import qualified Data.Sequence as Seq
import Data.Word ( Word64 )
import System.IO.Unsafe ( unsafePerformIO )

import Agda.Utils.Hash ( hashString )
import Agda.Utils.Lens ( (^.) )

import Agda.Syntax.Abstract.Name ( QName, qnameToConcrete, nameBindingSite )
import Agda.Syntax.Common ( unArg, namedThing )
import Agda.Syntax.Internal
  ( qnameName, qnameModule, MetaId, Clause(..)
  , Pattern'(..)
  , Term, unEl
  )
import Agda.Syntax.Internal.Names ( namesIn )
import Agda.Syntax.Internal.MetaVars ( allMetasList )
import Agda.Syntax.Position ( rStart, posLine )

import Agda.Syntax.Common.Pretty ( Pretty(..), prettyShow, render, (<+>), vcat, pshow )

import Agda.TypeChecking.Monad
  ( TCM
  , Definition(..), Defn(..)
  , Projection(..)
  , pattern Function, funWith, funExtLam, funInline, funIsKanOp, funClauses
  , funProjection, funTerminates
  , pattern Primitive, primClauses
  , pattern PrimitiveSort
  , pattern Axiom
  , pattern DataOrRecSig
  , pattern Datatype
  , pattern Record
  , pattern Constructor
  )
-- 'defInstance' lives on 'Definition' and is re-exported through
-- 'Agda.TypeChecking.Monad' alongside 'Defn'.
import Agda.TypeChecking.Monad.MetaVars ( lookupMetaInstantiation, isOpenMeta )
import Agda.TypeChecking.Monad.Options ( withShowAllArguments )
import Agda.TypeChecking.Monad.Signature ( getConstInfo )
import Agda.TypeChecking.Pretty ( prettyTCM )
import Agda.TypeChecking.Reduce ( normalise )

import Agda.Compiler.Backend ( IsMain )

import AgdaDeps.Options ( Options(..), DefState(..), isExcludedModule )
import AgdaDeps.TermCanon ( subtermHashes )
import AgdaDeps.Util ( isWithFun, isWithFun', liftAnonSegments )

-- | Structural classification of a definition, derived from its
-- 'Defn' shape (e.g. record-field projections vs. regular functions).
data DefKind
  = DKFunction
  | DKProjection
  | DKDatatype
  | DKRecord
  | DKConstructor
  | DKPostulate
  | DKPrimitive
  | DKOther
  deriving (Show, Eq)

instance NFData DefKind where
  rnf x = x `seq` ()

-- | Whether a definition is declared @private@ in its defining module.
-- 'Nothing' on 'ADDef._access' means it could not be determined and is
-- treated as \"public\".
data DefAccess
  = AccPrivate
  | AccPublic
  deriving (Show, Eq)

instance NFData DefAccess where
  rnf AccPrivate = ()
  rnf AccPublic  = ()

-- | A soundness escape that a definition uses /directly/ (not
-- transitively). Orthogonal to 'DefState': a def can be 'Defined' and
-- still carry escapes. Emitted as the optional per-def @unsafe@ wire
-- array (omitted when empty, so escape-free corpora stay byte-identical).
--
--   * 'UNonTerminating' — @{-# NON_TERMINATING #-}@
--     (@funTerminates = Just False@).
--   * 'UTrustMe' — the body/type references @primTrustMe@.
--
-- A @{-# TERMINATING #-}@ tag was prototyped (@funTerminates = Just True@)
-- and dropped: verified empirically against this corpus that the ordinary
-- termination checker /also/ writes @Just True@ back into the signature
-- for every proven-terminating def, so the field cannot distinguish the
-- pragma from a normal proof — it fired on @Nat._+_@, @Test.sum@, etc.
-- 'UNonTerminating' alone still fixes the measured audit miss.
data UnsafeTag
  = UNonTerminating
  | UTrustMe
  deriving (Show, Eq, Ord)

instance NFData UnsafeTag where
  rnf x = x `seq` ()

-- | File-level @{-# OPTIONS ⋯ #-}@ flags that make @agda --safe@ reject
-- a whole module — the module-level analogue of 'UnsafeTag'. This is the
-- set of /unconditional single-flag/ escapes from Agda's own
-- @Agda.Interaction.Options.Base.unsafePragmaOptions@ (the function
-- backing the @SafeFlagPragma@ warning); RE-SYNC THIS LIST on an Agda
-- bump. It is a superset across the supported range: 2.9 adds
-- @--local-rewriting@ over 2.8, and an unknown token simply never
-- matches, so one set serves both builds (no CPP).
--
-- /Deliberately excluded/: combination-conditional escapes that
-- @unsafePragmaOptions@ reports only when two flags co-occur
-- (@--cubical-compatible@ + @--with-K@, @--without-K@ + @--flat-split@,
-- @--without-K@ + @--large-indices@, @--large-indices@ +
-- @--forced-argument-recursion@). A file-token scan cannot evaluate the
-- combination without reconstructing the resolved 'PragmaOptions', so
-- those are out of scope here (and none is a common soundness audit
-- miss). Also out of scope: per-block declaration pragmas such as
-- @{-# NO_POSITIVITY_CHECK #-}@ / @{-# TERMINATING #-}@, which are NOT
-- @OPTIONS@ pragmas and never appear in @iFilePragmaOptions@.
safetyRelevantOptionFlags :: Set String
safetyRelevantOptionFlags = S.fromList
  [ "--allow-unsolved-metas"
  , "--allow-incomplete-matches"
  , "--no-positivity-check"
  , "--no-termination-check"
  , "--type-in-type"
  , "--omega-in-omega"
  , "--sized-types"
  , "--injective-type-constructors"
  , "--irrelevant-projections"
  , "--experimental-irrelevance"
  , "--rewriting"
  , "--local-rewriting"
  , "--cumulativity"
  , "--allow-exec"
  , "--no-load-primitives"
  ]

-- | Keep only the safety-relevant flags ('safetyRelevantOptionFlags')
-- from a module's raw file-level @OPTIONS@ tokens, deduplicated and in
-- ascending order. Empty when the module declares no file-level
-- soundness escape (so escape-free corpora emit nothing). Pure, so the
-- caller in "AgdaDeps.Backend" only has to hand it the flattened
-- @iFilePragmaOptions@ token list.
optionEscapes :: [String] -> [String]
optionEscapes toks =
  S.toAscList (S.intersection safetyRelevantOptionFlags (S.fromList toks))

-- | 'nodeKey' of Agda's @primTrustMe@ primitive. Confirmed empirically
-- against @test/Unsafe.agda@ (the QName survives 'namesIn' verbatim even
-- though the primitive itself is filtered from the node set).
trustMeNodeKey :: String
trustMeNodeKey = "Agda.Builtin.TrustMe.primTrustMe"

-- | How an outbound edge from a definition was discovered. Emitted as
-- a wire tag (see 'provTag') at JSON-emission time in
-- "AgdaDeps.Backend.GraphJson".
--
-- Precedence (high to low when several apply to the same @(src, dst)@):
-- 'ESignature' > 'EWith' > 'EModuleLocal' > 'EBody' > 'EUnknown'.
data EdgeProv
  = ESignature  -- ^ Target appears in @defType@.
  | EBody       -- ^ Target appears in @theDef@ only (not in @defType@,
                -- not a with-/anonymous-module helper).
  | EModuleLocal -- ^ Target is an anonymous-module helper (a @where@-block
                -- helper or a parameterised-section member; Agda represents
                -- both identically). Flags a locally-scoped helper, not
                -- ownership by this source. Wire tag: @module-local@.
  | EWith       -- ^ Target is the with-helper named by @funWith@.
  | EUnknown    -- ^ Catch-all: instance-method provider edges, or
                -- contracted edges whose chain's source provenance was
                -- indeterminate.
  deriving (Show, Eq, Ord)

instance NFData EdgeProv where
  rnf x = x `seq` ()

-- | Combine two provenances by precedence. Used when contraction or
-- instance-method extension reaches the same @(src, dst)@ pair more
-- than once.
provPrec :: EdgeProv -> EdgeProv -> EdgeProv
provPrec a b
  | precRank a >= precRank b = a
  | otherwise                = b
  where
    -- Precedence: ESignature > EWith > EModuleLocal > EBody > EUnknown.
    precRank :: EdgeProv -> Int
    precRank ESignature   = 4
    precRank EWith        = 3
    precRank EModuleLocal = 2
    precRank EBody        = 1
    precRank EUnknown     = 0

-- | Wire tag for 'EdgeProv', emitted in expanded JSON's
-- @definitionEdgesProvenance@ array.
provTag :: EdgeProv -> String
provTag ESignature   = "signature"
provTag EBody        = "body"
provTag EModuleLocal = "module-local"
provTag EWith        = "with"
provTag EUnknown     = "unknown"

-- | One node in the dependency graph: a 'QName' plus its direct
-- dependencies and its classification.
--
-- '_depsProv' parallels '_deps' with the invariant
-- @M.keysSet _depsProv == _deps@; every kept dep carries exactly one
-- 'EdgeProv' tag.
data ADDef = ADDef
  { _name   :: QName            -- ^ name of the definition
  , _deps   :: !(Set QName)     -- ^ its dependencies (named free variables)
  , _depsProv :: !(Map QName EdgeProv)
                                -- ^ per-dep provenance tag.
                                -- Invariant: @M.keysSet _depsProv == _deps@.
  , _state  :: !DefState        -- ^ classification used for node colouring
  , _kind   :: !DefKind         -- ^ structural shape from Agda's 'Defn'
  , _line   :: !(Maybe Int)     -- ^ 1-indexed start line of the binding site
  , _access :: !(Maybe DefAccess)
                                -- ^ public/private as seen in the defining
                                -- module's scope. 'Nothing' when unknown.
  , _subtermHashes :: !(Maybe [Word64])
                                -- ^ Canonical-form hashes for every
                                -- subterm walked in @defType@ and
                                -- @theDef@. Populated only under
                                -- @--with-term-hashes@; 'Nothing'
                                -- otherwise. See 'AgdaDeps.TermCanon'.
  , _subtermDepths :: !(Maybe [Int])
                                -- ^ Parallel to '_subtermHashes': AST
                                -- depth of each emitted subterm.
  , _sig    :: !(Maybe String)
                                -- ^ Rendered type signature (reify of
                                -- @defType@ via @prettyTCM@, collapsed to
                                -- one line; no normalisation, implicits
                                -- hidden). Populated only under
                                -- @--with-signatures@; 'Nothing'
                                -- otherwise. Emitted as the per-def
                                -- @"type"@ field in expanded JSON.
  , _unsafe :: ![UnsafeTag]
                                -- ^ Soundness escapes used directly by
                                -- this definition (see 'UnsafeTag').
                                -- Always computed (no flag); emitted as
                                -- the optional @"unsafe"@ array, omitted
                                -- when empty. Strict: always traversed
                                -- at emission and it's a short list.
  } deriving (Show)

instance Pretty ADDef where
  pretty ADDef{..} = vcat [ pshow "Name:"  <+> pretty _name
                          , pshow "State:" <+> pshow _state
                          , pshow "Kind:"  <+> pshow _kind
                          , pshow "Line:"  <+> pshow _line
                          , pshow "Access:" <+> pshow _access
                          , pshow "Deps:"  <+> pretty _deps
                          , pshow "DepsProv:" <+> pshow (M.toAscList _depsProv)
                          , pshow "Unsafe:" <+> pshow _unsafe ]

-- | Canonical node-identity string for a 'QName'. Anonymous-module
-- segments (the @._.@ marker Agda uses for both @where@-block helpers and
-- @module _ (…) where@ section members) are lifted into the nearest named
-- ancestor via 'liftAnonSegments' — @Mod._.helper@ becomes @Mod.helper@.
-- Lifting collapses the per-section @_@ qualifier, so same-named helpers
-- are disambiguated by binding-site line (@Mod.helper\@15@); a helper with
-- no recorded binding site falls back to the bare lifted name.
--
-- Single source of truth for node identity: 'hashQName' is its hash, and
-- the JSON wire @"name"@ field and edge endpoints are this exact string.
-- Do not revert to bare 'prettyShow': same-named @where@-helpers collapse
-- onto one node and lose their edges. 'moduleKey' is the matching
-- module-attribution function.
nodeKey :: QName -> String
nodeKey qn
  | "._." `isInfixOf` raw     -- 'isWhereHelperName', inlined to reuse 'raw'
  , Just ln <- bindingLine qn = lifted ++ "@" ++ show ln
  | otherwise                 = lifted
  where
    raw    = prettyShow qn
    lifted = liftAnonSegments raw

-- | Canonical owning-module string for a 'QName', with anonymous
-- sub-modules lifted away via 'liftAnonSegments' so attribution lands on
-- the nearest named module (@Mod._@ ↦ @Mod@). Every place that derives a
-- module name from a 'QName' for the graph must route through this, or
-- phantom @Mod._@ module nodes surface and set/index/membership drift.
moduleKey :: QName -> String
moduleKey = liftAnonSegments . prettyShow . qnameModule

-- | Version of the node-key convention emitted by 'nodeKey'. Stamped
-- into @graph.json@ so a consumer can detect a stale-format cached graph.
-- Bump whenever 'nodeKey' changes shape. Currently 3 (anonymous-module
-- segments lifted into the nearest named ancestor).
nodeKeyVersion :: Int
nodeKeyVersion = 3

-- | Stable integer ID for a 'QName', shared by every renderer. The hash
-- of 'nodeKey', so distinct same-named @where@/anonymous-module helpers
-- hash to distinct ids.
hashQName :: QName -> Int
hashQName = fromIntegral . hashString . nodeKey

-- | Every 'QName' that appears in the graph (definition names plus
-- their dependencies), deduplicated by 'hashQName'. Result is in
-- ascending hashQName order. 'IM.insert' is "last write wins" on hash
-- collision.
collectAllQNames :: [ADDef] -> [QName]
collectAllQNames defs = IM.elems (foldl' addDef IM.empty defs)
  where
    addDef :: IM.IntMap QName -> ADDef -> IM.IntMap QName
    addDef !acc ADDef{..} =
      let !acc1 = IM.insert (hashQName _name) _name acc
      in S.foldl' (\ !m qn -> IM.insert (hashQName qn) qn m) acc1 _deps

-- ** building ADDefs

-- | Build an 'ADDef' for a *kept* (non-ignored) definition.
--
-- Collects raw 'QName' dependencies via 'namesIn' and stores them
-- verbatim in '_deps' (including references to ignored helpers such as
-- @with-NNN@). 'postCompileAD' later calls 'contractIgnoredEdges' to
-- contract those out and apply the per-QName ignore filter.
computeDefAD :: Options -> Definition -> TCM ADDef
computeDefAD opts def@Defn{..} = do
  let excludes = optExcludeModules opts
      notExcluded qn = not (isExcludedModule excludes (moduleKey qn))
      -- Walk 'defType' and 'theDef' separately to record which set each
      -- name came from. Raw walks are shared with 'classifyDefWith' so
      -- each tree is traversed once. 'ignoreDependency' is applied later
      -- in 'contractIgnoredEdges'.
      !rawSig    = namesIn defType
      !rawBody   = namesIn theDef
      !sigNames  = S.fromList (filter notExcluded rawSig)
      !bodyNames = S.fromList (filter notExcluded rawBody)
      !deps      = S.union sigNames bodyNames
      !withTarget = case theDef of
        Function { funWith = w } -> isWithFun' w
        _                        -> Nothing
      !depsProv = M.fromSet (tagOne sigNames bodyNames withTarget) deps
  -- Reuse the raw (pre-exclude) name walks: a synthetic @unsolved#meta.*@
  -- name in an excluded module must still flip the Hole classification.
  st <- classifyDefWith rawSig rawBody def
  let !kd      = classifyKind def
      !lineMb  = bindingLine defName
      !termPairs = if optWithTermHashes opts
                     then Just (concatMap (subtermHashes (optMinTermDepth opts))
                                          (definitionTerms def))
                     else Nothing
      (!termHs, !termDs) = case termPairs of
        Just ps -> (Just (map fst ps), Just (map snd ps))
        Nothing -> (Nothing, Nothing)
  -- Render the type signature on demand: 'prettyTCM' reifies the stored
  -- 'defType', collapsed to a single line. '--normalise-signatures'
  -- reduces the type to its semantic form before reifying;
  -- '--show-implicit' reifies with implicit/irrelevant arguments shown.
  sigStr <- if optWithSignatures opts
              then do
                ty  <- if optNormaliseSignatures opts then normalise defType
                                                      else pure defType
                doc <- (if optShowImplicit opts then withShowAllArguments else id)
                         (prettyTCM ty)
                pure (Just (unwords (words (render doc))))
              else pure Nothing
  -- Soundness escapes, computed from data already in hand (no extra
  -- term traversals): the termination-pragma marker on 'theDef' plus a
  -- scan of the raw (pre-exclude) name walks for @primTrustMe@.
  let termTag = case theDef of
        Function{ funTerminates = Just False } -> [UNonTerminating]
        _                                      -> []
      usesTrustMe = any ((== trustMeNodeKey) . nodeKey) (rawSig ++ rawBody)
      !unsafeTags = termTag ++ [ UTrustMe | usesTrustMe ]
  return ADDef
    { _name   = defName
    , _deps   = deps
    , _depsProv = depsProv
    , _state  = st
    , _kind   = kd
    , _line   = lineMb
    , _access = Nothing  -- back-filled in postCompile from iScope
    , _subtermHashes = termHs
    , _subtermDepths = termDs
    , _sig    = sigStr
    , _unsafe = unsafeTags
    }

-- | Every 'Term' reachable from a 'Definition' for fingerprinting
-- purposes: the type's underlying 'Term' (via 'unEl') plus every
-- clause body that's actually present. For 'Datatype' / 'Record' /
-- 'Constructor' / 'Axiom' the body has no 'Term'-shaped content, so
-- only the type contributes.
definitionTerms :: Definition -> [Term]
definitionTerms Defn{..} = unEl defType : bodyTerms theDef
  where
    bodyTerms (Function   { funClauses  = cls }) = mapMaybe clauseBody cls
    bodyTerms (Primitive  { primClauses = cls }) = mapMaybe clauseBody cls
    bodyTerms _                                  = []

-- | Tag a single outgoing edge by precedence:
-- signature > with > module-local > body > unknown.
tagOne
  :: S.Set QName        -- ^ names from @defType@
  -> S.Set QName        -- ^ names from @theDef@
  -> Maybe QName        -- ^ @funWith@ helper, if any
  -> QName              -- ^ the dep to tag
  -> EdgeProv
tagOne sigNames bodyNames withTarget qn
  | qn `S.member` sigNames        = ESignature
  | Just qn == withTarget         = EWith
  | isWhereHelperName qn          = EModuleLocal
  | qn `S.member` bodyNames       = EBody
  | otherwise                     = EUnknown

-- | True when a 'QName' is a where-block / anonymous-module helper:
-- 'prettyShow' contains the @"._."@ anonymous-module marker. Matches
-- @Where._.sq@, @Where._.go@; does NOT match mixfix operators like
-- @_+_@ or @_∧_@ (a single dotted segment with no enclosing dots).
isWhereHelperName :: QName -> Bool
isWhereHelperName qn = "._." `isInfixOf` prettyShow qn

-- | 1-indexed start line of a 'QName''s binding site, if Agda recorded a
-- usable range for it. Synthetic names (e.g. @unsolved#meta.*@,
-- generated helpers we kept) typically return 'Nothing'.
bindingLine :: QName -> Maybe Int
bindingLine qn =
  let r = nameBindingSite (qnameName qn)
  in fromIntegral . posLine <$> rStart r

-- | Per-definition entry point used by the Agda backend hook.
--
-- For *ignored* definitions (with-helpers, pattern lambdas, Kan ops,
-- inlined module-instantiation copies, etc.) records the raw out-edges
-- into 'ignoredEdgesRef' before returning 'Nothing', so the closure
-- pass in 'contractIgnoredEdges' can stitch real-to-real edges across
-- chains of ignored defs.
--
-- Side-effect: for instance binders (defs with 'defInstance' set, or
-- whose body is a copattern lambda over a record's projections),
-- records the binder as a provider for each projection method it
-- supplies into 'methodProvidersRef' (consumed by
-- 'addInstanceMethodEdges').
compileDefAD :: Options -> env -> IsMain -> Definition -> TCM (Maybe ADDef)
compileDefAD opts _ _ def@Defn{..}
  | ignoreDef def = do
      -- Record raw out-edges of the ignored def, without applying
      -- 'ignoreDependency' (references to other ignored defs are kept
      -- so the closure pass can chain through). Module-exclusion still
      -- applies.
      let notExcluded qn = not (isExcludedModule excludes (moduleKey qn))
          !sigNames  = S.fromList (filter notExcluded (namesIn defType))
          !bodyNames = S.fromList (filter notExcluded (namesIn theDef))
          !raw       = S.union sigNames bodyNames
          !withTarget = case theDef of
            Function { funWith = w } -> isWithFun' w
            _                        -> Nothing
          !rawProv = M.fromSet (tagOne sigNames bodyNames withTarget) raw
      recordIgnoredDef defName rawProv
      return Nothing
  | isExcludedModule excludes (moduleKey defName) = return Nothing
  | otherwise = do
      recordInstanceMethods def
      Just <$> computeDefAD opts def
  where
    excludes = optExcludeModules opts

-- | If @def@ looks like an instance binder, record it as a provider
-- for every projection method it dispatches. Two signals are checked:
--
--   1. 'defInstance' is 'Just _' (any @instance ⋯@ declaration); the
--      binder is credited even when no method names can be recovered
--      from the body (e.g. @R ∋ record { ⋯ }@).
--   2. Body is a 'Function' whose first clause's first pattern is a
--      'ProjP' (the @R ∋ λ where ._method → …@ copattern-lambda idiom);
--      the projection 'QName's are harvested as the supplied methods.
recordInstanceMethods :: Definition -> TCM ()
recordInstanceMethods Defn{..} =
  let isInstance = isJust defInstance
      methods    = projectionMethods theDef
  in if isInstance || not (null methods)
       then recordMethodProviders defName methods
       else return ()
  where
    -- Pull the projection QName off the head pattern of every clause.
    -- The @R ∋ λ where@ shape has one ProjP per clause; anything else
    -- (var-pattern dispatch, deep nested patterns) yields the empty
    -- list.
    projectionMethods :: Defn -> [QName]
    projectionMethods (Function { funClauses = cls }) =
      mapMaybe headProj cls
    projectionMethods _ = []

    headProj :: Clause -> Maybe QName
    headProj cl = case namedClausePats cl of
      (p : _) -> case namedThing (unArg p) of
                   ProjP _ q -> Just q
                   _         -> Nothing
      _ -> Nothing

-- ** Side-channel: edges through ignored defs
--
-- Raw out-edges of each ignored def that 'compileDefAD' drops, keyed by
-- the ignored def's 'QName', so a kept def that references it can see
-- what it transitively reaches. Mutable global state, not persisted.
--
-- The value is a 'Map QName EdgeProv' carrying the same provenance
-- tagging as kept defs; contraction discards the inside-the-chain
-- provenance and inherits the kept def's tag towards the chain entry
-- (see 'contractWith').
type IgnoredEdgeMap = Map QName (Map QName EdgeProv)

{-# NOINLINE ignoredEdgesRef #-}
ignoredEdgesRef :: IORef IgnoredEdgeMap
ignoredEdgesRef = unsafePerformIO $ newIORef M.empty

-- | Clear the side-channel map. Called at the start of a compile so
-- repeated in-process invocations stay independent.
resetIgnoredEdges :: MonadIO m => m ()
resetIgnoredEdges = liftIO $ writeIORef ignoredEdgesRef M.empty

-- | Record an ignored def's out-edges (strict 'modifyIORef'').
recordIgnoredDef :: MonadIO m => QName -> Map QName EdgeProv -> m ()
recordIgnoredDef qn deps =
  liftIO $ modifyIORef' ignoredEdgesRef (M.insert qn deps)

-- | Read the ignored-edges map. Used by the fragment cache's write
-- path to extract a module's slice.
readIgnoredEdges :: MonadIO m => m IgnoredEdgeMap
readIgnoredEdges = liftIO $ readIORef ignoredEdgesRef

-- | Union a cached module's ignored-edges slice back in (fragment
-- cache hit: the module's @compileDef@ hooks never ran, so its
-- entries must come from the fragment). Left-biased on collision —
-- a freshly-recorded entry wins over a cached one.
mergeIgnoredEdges :: MonadIO m => IgnoredEdgeMap -> m ()
mergeIgnoredEdges extra =
  liftIO $ modifyIORef' ignoredEdgesRef (`M.union` extra)

-- ** Side-channel: instance-method providers
--
-- Records (method -> [binders]) for each instance binder checked, so
-- 'postCompileAD' can add reverse edges (method usages credit the
-- binder, which is otherwise reached only via instance resolution).

-- | Method @QName@ -> list of instance binders that provide it.
-- A method may be implemented by several binders; the list preserves
-- insertion order, matching Agda's compile order.
type MethodProviderMap = Map QName [QName]

{-# NOINLINE methodProvidersRef #-}
methodProvidersRef :: IORef MethodProviderMap
methodProvidersRef = unsafePerformIO $ newIORef M.empty

-- | Clear the providers map at the start of a compile so repeated
-- in-process invocations stay independent.
resetMethodProviders :: MonadIO m => m ()
resetMethodProviders = liftIO $ writeIORef methodProvidersRef M.empty

-- | Read the providers map. Used by 'Backend.postCompileAD'.
readMethodProviders :: MonadIO m => m MethodProviderMap
readMethodProviders = liftIO $ readIORef methodProvidersRef

-- | Union a cached module's provider slice back in (fragment cache
-- hit). Per-method binder lists are appended; downstream
-- 'addInstanceMethodEdges' treats them as a set, so order is
-- immaterial.
mergeMethodProviders :: MonadIO m => MethodProviderMap -> m ()
mergeMethodProviders extra =
  liftIO $ modifyIORef' methodProvidersRef (M.unionWith (++) extra)

-- | Append @binder@ to the providers list for each of @methods@. An
-- empty @methods@ list is a no-op (the binder is still recorded by the
-- defInstance-marker path when its method names can't be recovered).
recordMethodProviders :: MonadIO m => QName -> [QName] -> m ()
recordMethodProviders binder methods =
  liftIO $ modifyIORef' methodProvidersRef $ \m ->
    foldl' (\acc method ->
              M.insertWith (\new old -> head new : old) method [binder] acc)
           m
           methods

-- | After contraction, walk every kept def's @_deps@ and append edges
-- to any registered providers. Purely additive: forward edges stay in
-- place.
--
-- Added edges are tagged 'EUnknown' (provider links are inferred from
-- method dispatch, not a syntactic walk). 'M.union' is left-biased, so
-- existing tags in '_depsProv' are preserved.
--
-- Complexity: O(D * d), D = number of kept defs, d = average |deps|.
addInstanceMethodEdges :: [ADDef] -> TCM [ADDef]
addInstanceMethodEdges defs = do
  providers <- readMethodProviders
  if M.null providers
    then pure defs
    else pure (map (extendOne providers) defs)
  where
    extendOne :: MethodProviderMap -> ADDef -> ADDef
    extendOne providers d =
      let !extra = S.foldl' (collect providers) S.empty (_deps d)
      in if S.null extra
           then d
           else
             let !newDeps = S.union (_deps d) extra
                 !newProv = M.union (_depsProv d)
                                    (M.fromSet (const EUnknown) extra)
             in d { _deps = newDeps, _depsProv = newProv }

    collect :: MethodProviderMap -> Set QName -> QName -> Set QName
    collect providers !acc qn = case M.lookup qn providers of
      Nothing -> acc
      Just bs -> foldl' (flip S.insert) acc bs

-- | Closure pass over a set of 'QName's against the side-channel of
-- ignored-def out-edges: every QName that's an ignored-def key is
-- replaced by its own out-edges (recursively), and every other QName is
-- kept. Hidden defs are contracted through, not emitted.
--
-- Thin wrapper around 'bfsClosure'. Production code uses
-- 'contractIgnoredEdges' instead, which memoises across many calls.
expandThroughIgnored :: MonadIO m => Set QName -> m (Set QName)
expandThroughIgnored frontier0 = do
  hidden <- liftIO $ readIORef ignoredEdgesRef
  pure $ bfsClosure hidden frontier0

-- | Post-pass: rewrite each 'ADDef'@._deps@ + @._depsProv@ by
-- contracting through the side-channel of ignored defs, then apply the
-- per-QName 'ignoreDependency' filter. Called once from 'postCompileAD'
-- after every def has been processed (so the side-channel is complete).
--
-- The expansion is memoized per ignored-def key: each hidden key's
-- transitive closure (its real, non-ignored targets) is computed once
-- and cached without per-target provenance. At the kept-def boundary,
-- each real target inherits the kept def's provenance towards the chain
-- entry (the hidden helper).
--
-- The final 'ignoreDependency' pass removes any leaf 'QName' that
-- 'ignoreDef' classifies as ignorable but that wasn't in the
-- side-channel map.
contractIgnoredEdges :: [ADDef] -> TCM [ADDef]
contractIgnoredEdges defs = do
  hidden <- liftIO $ readIORef ignoredEdgesRef
  let memo = buildIgnoredClosure hidden
      -- Expand each kept def's raw dep map through the hidden chain once
      -- (pure). 'expandeds' is shared between the distinct-target scan and
      -- the per-def rewrite, so 'contractWith' runs exactly once per def.
      expandeds  = map (contractWith hidden memo . _depsProv) defs
      allTargets = S.unions (map M.keysSet expandeds)
  -- 'ignoreDependency' is a pure function of its 'QName' (a signature
  -- lookup), so run it once per distinct contracted target.
  ignored <- filterM ignoreDependency (S.toList allTargets)
  let !ignoredSet = S.fromList ignored
  pure (zipWith (rewrite ignoredSet) defs expandeds)
  where
    -- Drop the ignored targets from a contracted dep map, keeping the
    -- surviving keys' 'EdgeProv' values.
    rewrite ignoredSet d expanded =
      let !keptProv = M.withoutKeys expanded ignoredSet
      in d { _deps = M.keysSet keptProv, _depsProv = keptProv }

    -- One-shot expansion of a kept def's raw dep map: every QName that
    -- is an ignored-def key is replaced by its cached closure of real
    -- targets (each inheriting the kept def's tag towards the key);
    -- every other QName is kept with its original tag. On a target
    -- reached by two paths, 'provPrec' picks the higher-precedence tag.
    contractWith
      :: IgnoredEdgeMap
      -> Map QName (Set QName)
      -> Map QName EdgeProv
      -> Map QName EdgeProv
    contractWith hidden memo srcMap =
      M.foldlWithKey' step M.empty srcMap
      where
        step !acc qn provFromSrc = case M.lookup qn memo of
          Just realTargets ->
            -- Inherit @provFromSrc@ for every real target reached
            -- through the hidden chain entered at @qn@.
            S.foldl'
              (\ !m realTgt -> M.insertWith provPrec realTgt provFromSrc m)
              acc realTargets
          Nothing
            | M.member qn hidden ->
                -- In 'hidden' but missing from memo: fall back to
                -- in-line BFS.
                let !extra = bfsClosure hidden (S.singleton qn)
                in S.foldl'
                     (\ !m realTgt -> M.insertWith provPrec realTgt provFromSrc m)
                     acc extra
            | otherwise -> M.insertWith provPrec qn provFromSrc acc

-- | Standalone BFS closure, used by 'expandThroughIgnored' and as the
-- fallback in 'contractIgnoredEdges'. @frontier0@ is the set of
-- starting QNames; the result is every reachable QName that's *not* an
-- ignored-def key. 'EdgeProv' tags inside the closure are discarded.
bfsClosure :: IgnoredEdgeMap -> Set QName -> Set QName
bfsClosure hidden frontier0 =
  let initial :: Seq QName
      initial = Seq.fromList (S.toList frontier0)
      (_, kept) = go initial IS.empty S.empty
  in kept
  where
    go :: Seq QName -> IS.IntSet -> Set QName
       -> (IS.IntSet, Set QName)
    go q !visited !kept = case Seq.viewl q of
      Seq.EmptyL -> (visited, kept)
      qn Seq.:< rest ->
        let !h = hashQName qn
        in if IS.member h visited
             then go rest visited kept
             else
               let !visited' = IS.insert h visited
               in case M.lookup qn hidden of
                    Just inner ->
                      -- Provenance tags inside @inner@ are discarded;
                      -- only reachability matters.
                      let !rest' = M.foldlWithKey' (\ !q' k _ -> q' |> k) rest inner
                      in go rest' visited' kept
                    Nothing ->
                      let !kept' = S.insert qn kept
                      in go rest visited' kept'

-- | Build a per-ignored-key cache of the set of *real* (non-ignored)
-- targets each hidden def reaches transitively. Provenance inside the
-- chain is dropped; 'contractWith' assigns the final provenance.
--
-- Algorithm: Kahn's topological sort on the hidden→hidden subgraph plus
-- a bottom-up dynamic-programming union, visiting each hidden node and
-- each hidden-to-hidden edge exactly once. Any key not emitted by Kahn
-- (a cycle member) falls back to a per-key BFS via 'bfsClosure'.
--
-- Each key's adjacency is partitioned once into
-- @(hiddenDeps, nonHiddenDeps)@; the DP step at key @k@ is
-- @closure[k] = nonHiddenDeps[k] ∪ ⋃ closure[d] for d in hiddenDeps[k]@.
buildIgnoredClosure :: IgnoredEdgeMap -> Map QName (Set QName)
buildIgnoredClosure hidden = withCycles
  where
    keys :: Set QName
    keys = M.keysSet hidden

    -- Forward adjacency partitioned once into (hiddenDeps, nonHiddenDeps);
    -- per-edge provenance inside the chain is discarded.
    adj :: Map QName (Set QName, Set QName)
    adj = M.map partitionEntry hidden
      where
        partitionEntry :: Map QName EdgeProv -> (Set QName, Set QName)
        partitionEntry m =
          let !ks = M.keysSet m
          in S.partition (`S.member` keys) ks

    -- Reverse adjacency on the hidden→hidden subgraph.
    revAdj :: Map QName (Set QName)
    revAdj = M.foldlWithKey' addRev M.empty adj
      where
        addRev !m k (hDeps, _) =
          S.foldl'
            (\ !acc d -> M.insertWith S.union d (S.singleton k) acc)
            m hDeps

    -- Initial out-degree: number of hidden deps each key has.
    outDeg0 :: Map QName Int
    outDeg0 = M.map (S.size . fst) adj

    -- Seed Kahn's with every node whose hidden-deps set is empty.
    seed :: Seq QName
    seed = Seq.fromList
      [ k | (k, (h, _)) <- M.toList adj, S.null h ]

    -- Bottom-up DP. By the Kahn invariant, every hidden dep of @k@ is
    -- in @memo@ when @k@ is popped, so the union is a straight lookup.
    kahn :: Map QName (Set QName) -> Map QName Int -> Seq QName
         -> Map QName (Set QName)
    kahn !memo !deg q = case Seq.viewl q of
      Seq.EmptyL    -> memo
      k Seq.:< rest ->
        let (hDeps, nDeps) = M.findWithDefault (S.empty, S.empty) k adj
            !closed        = S.foldl' unionMemo nDeps hDeps
            unionMemo !acc d =
              S.union acc (M.findWithDefault S.empty d memo)
            !memo'         = M.insert k closed memo
            preds          = M.findWithDefault S.empty k revAdj
            (deg', rest')  = S.foldl' decrement (deg, rest) preds
            decrement (!d, !qq) p =
              let !nv = M.findWithDefault 0 p d - 1
                  !d' = M.insert p nv d
              in if nv <= 0
                   then (d', qq |> p)
                   else (d', qq)
        in kahn memo' deg' rest'

    !partial = kahn M.empty outDeg0 seed

    -- Cycle fallback: any key not emitted by Kahn (out-degree > 0) is
    -- part of a directed cycle in the hidden subgraph; compute its
    -- closure with 'bfsClosure'.
    cycleMembers :: Set QName
    cycleMembers = keys `S.difference` M.keysSet partial

    withCycles :: Map QName (Set QName)
    withCycles
      | S.null cycleMembers = partial
      | otherwise           =
          S.foldl' addCycle partial cycleMembers
      where
        addCycle !m k =
          let !c = bfsClosure hidden (S.singleton k)
          in M.insert k c m

-- ** classification

-- | True when a 'QName' is one of the synthetic @unsolved#meta.*@
-- postulates Agda generates under @--allow-unsolved-metas@ (via
-- @openMetasToPostulates@).
isUnsolvedMetaName :: QName -> Bool
isUnsolvedMetaName qn = "unsolved#meta." `isPrefixOf` prettyShow (qnameName qn)

-- | Structural classification from 'theDef'. In Agda 2.9 'funProjection'
-- is @Either ProjectionLikenessMissing Projection@; a 'Right' carrying a
-- 'projProper' 'Just' is a record-field projection ('DKProjection'), the
-- rest are plain functions.
classifyKind :: Definition -> DefKind
classifyKind Defn{ theDef = d } = case d of
  Function{}    -> case funProjection d of
                     Right p | isJust (projProper p) -> DKProjection
                     _                               -> DKFunction
  Datatype{}    -> DKDatatype
  Record{}      -> DKRecord
  Constructor{} -> DKConstructor
  Axiom{}       -> DKPostulate
  Primitive{}   -> DKPrimitive
  _             -> DKOther

-- | Classify a 'Definition' as fully-defined, postulate, or
-- hole-bearing. Holes are detected by:
--
-- 1. Walking 'defType' and 'theDef' for any lingering open 'MetaV', and
-- 2. References to @unsolved#meta.*@ generated names (which Agda's
--    @openMetasToPostulates@ leaves under @--allow-unsolved-metas@).
--
-- A definition whose *own* name starts with @"unsolved#meta."@ is itself
-- a hole-marker.
classifyDef :: Definition -> TCM DefState
classifyDef def@Defn{..} = classifyDefWith (namesIn defType) (namesIn theDef) def

-- | 'classifyDef' with the @defType@/@theDef@ name walks supplied by the
-- caller, so 'computeDefAD' (which already walks both) does not pay for a
-- second traversal of the same term trees. The lists must be the *raw*
-- (pre-exclude-filter) names.
classifyDefWith :: [QName] -> [QName] -> Definition -> TCM DefState
classifyDefWith sigRaw bodyRaw def@Defn{..}
  | isUnsolvedMetaName defName = return Hole
  | otherwise = case theDef of
      Axiom{} -> return Postulate
      _ -> do
        let metas = allMetasList defType ++ metasInDefn theDef
            referencedNames = sigRaw ++ bodyRaw
            referencesUnsolvedMeta = any isUnsolvedMetaName referencedNames
        if referencesUnsolvedMeta
          then return Hole
          else if null metas
            then return Defined
            else do
              anyUnsolved <- anyM isMetaUnsolved metas
              return $ if anyUnsolved then Hole else Defined
  where
    isMetaUnsolved :: MetaId -> TCM Bool
    isMetaUnsolved m = isOpenMeta <$> lookupMetaInstantiation m

    anyM :: Monad m => (a -> m Bool) -> [a] -> m Bool
    anyM _ []     = return False
    anyM p (x:xs) = do
      b <- p x
      if b then return True else anyM p xs

-- | Collect metavariables in a 'Defn' by walking the cases that carry
-- term content ('Defn' has no 'AllMetas' instance).
metasInDefn :: Defn -> [MetaId]
metasInDefn = \case
  Function{ funClauses = cls } -> concatMap metasInClause cls
  Primitive{ primClauses = cls } -> concatMap metasInClause cls
  AbstractDefn d -> metasInDefn d
  _ -> []  -- Datatype/Record/Constructor/Axiom/etc. carry no Term bodies
  where
    metasInClause Clause{ clauseTel = tel, clauseBody = body, clauseType = ty } =
      allMetasList tel ++ allMetasList body ++ allMetasList ty

-- ** filtering

ignoreDependency :: QName -> TCM Bool
ignoreDependency qn = do
  def <- getConstInfo qn
  return $ ignoreDef def

ignoreDef :: Definition -> Bool
-- Module-instantiation copies (Agda's 'defCopy' flag): alias nodes
-- re-exporting the real definition under an importing module's
-- namespace. Catches all kinds (Function/Record/Datatype/Constructor),
-- not just the Function case 'funInline' covers.
ignoreDef Defn{..} | defCopy = True
-- Auto-generated names for `variable` blocks (the `GeneralizeTel`
-- record, its `mkGeneralizeTel` constructor, and `generalizedField-*`
-- projections), identified by the anonymous NoName segment that
-- 'prettyShow' renders as a literal "..".
ignoreDef Defn{..} | ".." `isInfixOf` prettyShow defName = True
ignoreDef Defn{..} = case theDef of

  -- Pattern-lambda / with-generated / Kan-op functions.
  Function{..} | isJust funExtLam || isWithFun funWith || isJust funIsKanOp -> True
  -- Do NOT remove: drops user @{-# INLINE #-}@ functions. Agda inlines
  -- every call site into the caller's body during type-checking, so by
  -- the time the hook fires an INLINE function has zero incoming edges;
  -- keeping it would add a false-"dead" orphan node.
  d@Function{..} | d ^. funInline -> True

  -- Primitive functions with no clauses (keeps builtin ones).
  Primitive{..} -> null primClauses

  -- Level.
  Axiom{} | prettyShow defName == "Agda.Primitive.Level" -> True

  -- Other kinds not wanted as nodes.
  PrimitiveSort{..} -> True
  DataOrRecSig{..} -> True
  GeneralizableVar _ -> True

  _ -> False
