{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
-- | Dependency analysis: walks each 'Definition' to extract its direct
-- lemma/postulate/data dependencies ('computeDefAD' / 'compileDefAD'),
-- classifies it as 'Defined' / 'Postulate' / 'Hole' ('classifyDef'),
-- and filters compiler-generated definitions out of the graph
-- ('ignoreDef'). Node identity is 'nodeKey' / 'hashQName'; edge
-- provenance is 'EdgeProv' / 'tagOneWith'.
module AgdaDeps.Deps
  ( -- * Node identity
    NodeRef(..)
  , mkRef
  , nrSrcLoc

    -- * The per-definition record
  , ADDef(..)
  , DefKind(..)
  , DefAccess(..)
  , UnsafeTag(..)
  , ArgUsage(..)
  , ArgBinder(..)
  , BinderHiding(..)
  , argUsageOf

    -- * Module-level soundness escapes (file @OPTIONS@ pragmas)
  , safetyRelevantOptionFlags
  , optionEscapes

    -- * Edge provenance
  , EdgeProv(..)
  , provPrec
  , provTag

    -- * Hashing & node collection
  , nodeKey
  , moduleKey
  , nodeKeyVersion
  , hashQName
  , collectAllQNames
    -- ** QName-level identity (producer-side: live interface QNames)
  , nodeKeyOfQ
  , moduleKeyOfQ

    -- * Building 'ADDef's
  , computeDefAD
  , compileDefAD

    -- * Classification (for node colouring)
  , classifyDef
  , classifyKind
  , isUnsolvedMetaName

    -- * Silent (non-interaction) unsolved metas
  , srcLocOfQ
  , markerIsSilent
  , unsolvedInterfaceLines
  , liveSilentMetaLines

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
import Control.Monad ( filterM, unless, when )
import Control.Monad.IO.Class ( MonadIO(liftIO) )
import Data.Binary ( Binary )
import qualified Data.Binary as B
import Data.IORef ( IORef, modifyIORef', newIORef, readIORef, writeIORef )
import Data.List ( foldl', isInfixOf, isPrefixOf, sort, sortOn )
import Data.Maybe ( fromMaybe, isJust, mapMaybe, maybeToList )
import Data.Map.Strict ( Map )
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Set ( Set )
import qualified Data.Set as S
import Data.Sequence ( Seq, (|>) )
import qualified Data.Sequence as Seq
import Data.Word ( Word32, Word64 )
import System.Environment ( lookupEnv )
import System.IO ( hPutStrLn, stderr )
import System.IO.Unsafe ( unsafePerformIO )

import Agda.Utils.Hash ( hashString )
import Agda.Utils.Lens ( (^.) )

import Agda.Syntax.Abstract.Name ( QName, nameBindingSite )
import Agda.Syntax.Common ( unArg, namedThing, Hiding(..), getHiding )
import Agda.Syntax.Internal
  ( qnameName, qnameModule, MetaId, Clause(..)
  , Pattern'(..)
  , Term(Pi), Type, Telescope, telToList, unAbs, unDom, unEl
  , Suggest(suggestName)
  )
import Agda.Syntax.Internal.Names ( namesIn )
import Agda.Syntax.Internal.MetaVars ( allMetasList )
import Agda.Syntax.Position ( rStart, posLine, posPos, rangeFile, rangeFilePath )
import Agda.Utils.FileName ( filePath )
import Agda.Utils.Size ( size )
import qualified Agda.Utils.Maybe.Strict as Strict

-- Silent-unsolved-meta detection: the split between an honest interaction
-- @?@ and a silently-inserted unsolved meta is read from each interface's
-- stored highlighting ('iHighlighting'): Agda's @warningHighlighting@ marks
-- 'UnsolvedMetaVariables' ranges with the 'UnsolvedMeta' aspect and
-- 'UnsolvedConstraints' with 'UnsolvedConstraint', while
-- 'UnsolvedInteractionMetas' produce no aspect. Identical modules/fields on
-- Agda 2.8 and 2.9 — no CPP.
import Agda.Interaction.Highlighting.Precise ( HighlightingInfo )
import qualified Agda.Interaction.Highlighting.Range as HR
import qualified Agda.Utils.RangeMap as RangeMap
import Agda.Syntax.Common.Aspect
  ( Aspects(otherAspects), OtherAspect(UnsolvedMeta, UnsolvedConstraint) )
import qualified Data.HashMap.Strict as HMap
import qualified Data.Text.Lazy as TL

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
  , Polarity(..)
  )
-- Argument-usage analysis ('argUsageOf') reads two fields Agda already
-- fills in during positivity/polarity checking. 'Polarity' rides in on the
-- re-export chain above (Monad -> Monad.Base -> Monad.Base.Types), but
-- 'Occurrence' is imported plainly into Monad.Base and NOT re-exported, so
-- it needs its own import. Same modules and fields on 2.8 and 2.9 — no CPP.
import Agda.TypeChecking.Positivity.Occurrence ( Occurrence(..) )
-- 'defInstance' comes in via 'Agda.TypeChecking.Monad' alongside 'Defn'.
import Agda.TypeChecking.Monad.Base
  ( Interface, miInterface, iHighlighting, iSignature, iSource
  , sigDefinitions )
import Agda.TypeChecking.Monad.Imports ( getVisitedModules )
import Agda.TypeChecking.Monad.MetaVars
  ( lookupMetaInstantiation, isOpenMeta, getInteractionMetas, getUnsolvedMetas )
import Agda.TypeChecking.Monad.Options ( withShowAllArguments )
import Agda.TypeChecking.Monad.Signature ( droppedPars, getConstInfo, lookupSection )
import Agda.TypeChecking.Pretty ( prettyTCM )
import Agda.TypeChecking.Reduce ( normalise )
import Agda.TypeChecking.Free ( freeIn )
import Agda.TypeChecking.Telescope ( telView )
import Agda.TypeChecking.Substitute ( TelV(..), absBody )

import Agda.Compiler.Backend ( IsMain )

import AgdaDeps.Options ( Options(..), DefState(..), isExcludedModule )
import AgdaDeps.MatchConstant ( matchConstantAnalysable, matchConstantOf )
import AgdaDeps.TermCanon ( subtermHashes )
import AgdaDeps.Util ( dedupOrd, isWithFun, liftAnonSegments )

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

-- | A soundness escape a definition uses /directly/. Orthogonal to
-- 'DefState' (a 'Defined' def can carry escapes). Emitted as the optional
-- per-def @unsafe@ wire array, omitted when empty.
--
--   * 'UNonTerminating' — @{-# NON_TERMINATING #-}@ (@funTerminates = Just False@).
--   * 'UTrustMe' — body/type references @primTrustMe@.
--
-- No @{-# TERMINATING #-}@ tag: the ordinary termination checker also sets
-- @funTerminates = Just True@, so it's indistinguishable from a normal proof.
data UnsafeTag
  = UNonTerminating
  | UTrustMe
  deriving (Show, Eq, Ord)

instance NFData UnsafeTag where
  rnf x = x `seq` ()

-- | Arguments a definition never actually uses, read straight off the
-- analysis Agda already ran for positivity\/polarity checking. Nothing is
-- computed here beyond two field reads, a zip and a walk of the type's
-- 'Pi' spine ('piSpine', which the arity count pays for anyway) — see
-- 'argUsageOf'.
--
-- Both index lists are ascending /telescope positions, implicits
-- included/, over the definition's __own__ binders — the ones a reader
-- sees on its signature line. See 'argUsageOf' for why that is not the
-- same thing as the elaborated telescope.
data ArgUsage = ArgUsage
  { auRemovable :: ![Int]
    -- ^ @Unused@ /and/ 'Nonvariant': the binder and the argument at every
    -- call site can go.
  , auRemovableRequires :: ![(Int, [Int])]
    -- ^ Which /other/ 'auRemovable' positions must be removed alongside a
    -- given one, transitively. Ascending by key; only positions with a
    -- non-empty requirement appear, so this is empty whenever every
    -- removal stands alone (always, for a single-index verdict). See
    -- 'removableRequiresOf'.
  , auErasable  :: ![Int]
    -- ^ @Unused@ but not 'Nonvariant': used only in types, so an @\@0@
    -- candidate rather than a removal.
  , auArity     :: !Int
    -- ^ Telescope positions this verdict ranges over; every index in
    -- either list is @< auArity@.
  , auBinders   :: ![(Int, ArgBinder)]
    -- ^ How each /reported/ position is written, for a report line that
    -- says @argument 0 ({A : Set})@ rather than @argument 0@. Sparse and
    -- ascending: only positions appearing in 'auRemovable' or
    -- 'auErasable', and only those the syntactic spine actually reaches
    -- (see 'piSpine') — a position with no entry is not a claim that it
    -- is explicit.
  } deriving (Show, Eq)

instance NFData ArgUsage where
  rnf (ArgUsage r q e a b) =
    rnf r `seq` rnf q `seq` rnf e `seq` rnf a `seq` rnf b

-- | Surface facts about one binder, read off the syntactic 'Pi' spine of
-- the definition's type: enough to name it in a report line without the
-- consumer re-parsing the source signature.
--
-- Deliberately not the binder's /type/ — that is the existing
-- @--with-signatures@ @type@ field's job, and unlike this it is not
-- re-indexed onto the definition's own binders.
data ArgBinder = ArgBinder
  { abHiding :: !BinderHiding
    -- ^ Always known: a spine position has an argument info.
  , abName   :: !(Maybe String)
    -- ^ The binder name /as Agda spells it/, or 'Nothing' when the spine
    -- has none (@Nat -> Nat@ binds nothing to name). Never guessed:
    -- Agda's own 'suggestName' is what maps its @\"_\"@ placeholder to
    -- 'Nothing'.
    --
    -- A name containing a @.@ (e.g. @\"P.A\"@) is a binder Agda /inserted/
    -- by generalising a @variable@ declaration — specifically one of the
    -- mentioned variable's own dependencies. A source binder name can
    -- never contain @.@, so that is a sound test rather than a guess, and
    -- it is worth making: such a position has no binder on the signature
    -- line to delete or annotate. It is reported as-is because that is
    -- exactly the name Agda's own printer uses (it appears in the sibling
    -- @--with-signatures@ @type@ string too), so dropping it would lose
    -- the consumer's only signal. Positions for a generalised variable
    -- that the signature /mentions/ carry its plain name and are
    -- indistinguishable from a written binder here.
  } deriving (Show, Eq)

instance NFData ArgBinder where
  rnf (ArgBinder h n) = rnf h `seq` rnf n

-- | How a binder is written, hence how a call site passes it. The
-- distinction a report line cannot omit: \"argument 0\" of
-- @{a : Set} -> List a -> List a@ reads as the first @List@ to almost
-- anyone, and it is the @{a : Set}@.
data BinderHiding
  = BHExplicit
  | BHImplicit
  | BHInstance
  deriving (Show, Eq)

instance NFData BinderHiding where
  rnf x = x `seq` ()

-- | Per-argument \"never used\" verdict for a definition, or 'Nothing'
-- when there is nothing to report (the overwhelmingly common case, so it
-- costs one constructor tag).
--
-- __Indices are over the definition's own binders.__ Agda prepends the
-- enclosing section's telescope to every definition inside it, so for a
-- @where@ helper or a def in a parametrised @module M (n : Nat) where@,
-- the elaborated telescope 'defPolarity' \/ 'defArgOccurrences' index is
-- /longer/ than the signature as written. A @where@ helper that ignores
-- its parent's arguments would otherwise report those parent binders as
-- \"removable\" — binders that do not exist on its source line and cannot
-- be deleted from it. So the raw verdict is shifted down by the section
-- telescope size and anything landing in that prefix is dropped, leaving
-- exactly the positions a reader could strike off the signature.
--
-- The 'lookupSection' is a plain state read (two 'Map' lookups, no
-- reduction), gated on there being something to report. Do not read that
-- gate as \"rare\": 'auErasable' fires on the ubiquitous @{A : Set}@
-- implicit used only in later types, so roughly a quarter of definitions
-- reach it. Only 'auRemovable' is rare.
--
-- Agda runs this analysis for /every/ mutual block, plain functions
-- included (@Rules.Decl.checkPositivity_@ → @computePolarity@), and
-- serialises both lists into the interface, so the verdict is available
-- cross-module with no re-checking. The two fields compose
-- interprocedurally — an occurrence \"as argument @i@ of @g@\" is composed
-- with @g@'s own stored occurrence for that argument — so an argument
-- threaded into a @where@-helper that discards it reads @Unused@ in the
-- parent too. 'computePolarity' also post-processes with
-- @dependentPolarity@, demoting to 'Invariant' any argument a later
-- relevant argument's type (or the codomain) depends on, which is what
-- keeps type-dependent arguments out of 'auRemovable'.
--
-- Scope, phase 1 — only non-projection-like 'Function's:
--
-- * Projection(-like) functions and constructors drop their parameters
--   from /both/ lists, so the indices are shifted off the telescope by
--   @droppedPars@. Testing @droppedPars == 0@ is exactly that condition;
--   a later phase wanting these rows can add the offset back rather than
--   emitting a misaligned one.
-- * @Axiom@ \/ @Primitive@ have no body for an argument to go unused in,
--   and for @Datatype@ \/ @Record@ the polarity signal means something
--   else: @enablePhantomTypes@ deliberately purges 'Nonvariant' to
--   'Covariant' on parameters so phantom types keep working.
--
-- Padding: the classifying pass stops when /either/ list runs out, which
-- implements the rule that any index past the end of one counts as used. That
-- is deliberately more conservative than Agda's own @getArgOccurrence@,
-- which falls back to a @telView@-driven computation for an out-of-range
-- index; silence is the right answer for a missing entry, and we do not
-- want that cost here.
argUsageOf :: Definition -> TCM (Maybe ArgUsage)
argUsageOf def = do
  res <- phase1
  -- Runs for *every* definition, not just those with a phase-1 verdict: a
  -- match-constant position is exactly the case phase 1 says nothing about,
  -- so gating the probe on a phase-1 finding would measure almost nothing.
  when matchConstantProbe $ probeMatchConstant def res
  pure res
  where
    phase1 = case rawArgUsage def of
      Nothing -> pure Nothing
      -- An erasable-only verdict makes no deletion claim, so it needs neither
      -- the deletability guard nor a telescope: no 'telView' is paid for the
      -- 96% of findings that are erasable-only.
      Just au0 | null (auRemovable au0) -> finish au0
               | otherwise -> do
        TelV tel core <- telView (defType def)
        finish (guardDeletable [piSpineOf (defType def), telSpine tel core] au0)
    -- Nothing survived: report nothing rather than an object of empty lists.
    finish au
      | null (auRemovable au) && null (auErasable au) = pure Nothing
      | otherwise = do
          k <- sectionPrefixSize def
          pure (dropSectionPrefix k au)

-- | Phase-2 measurement scaffold, off unless @AGDA_DEPS_MATCH_CONSTANT@ is
-- set in the environment. Deliberately a stderr dump rather than a wire
-- field: the match-constant analysis (see "AgdaDeps.MatchConstant") walks a
-- case tree per definition, which is a real cost, and the consumer asked for
-- measured yield before any wire commitment.
--
-- Two line kinds, so a corpus run can be counted with @grep@:
--
-- > MC-CAND <name>                                  -- in the population
-- > MC-HIT  <name> mc=[…] rem=[…] era=[…] arity=n   -- has a finding
--
-- @rem@ \/ @era@ are the /phase-1/ verdict for the same definition, so
-- "already reported for some other position" is a property of one line.
matchConstantProbe :: Bool
matchConstantProbe =
  unsafePerformIO (isJust <$> lookupEnv "AGDA_DEPS_MATCH_CONSTANT")
{-# NOINLINE matchConstantProbe #-}

-- | Run the analysis and dump it. Positions go through the same
-- 'shiftOntoOwnBinders' as phase 1's, so the numbers reported are the ones a
-- wire field would carry.
probeMatchConstant :: Definition -> Maybe ArgUsage -> TCM ()
probeMatchConstant def mau =
  when (matchConstantAnalysable def) $ do
    raw <- matchConstantOf def
    k   <- sectionPrefixSize def
    let mc   = shiftOntoOwnBinders k raw
        name = nodeKeyOfQ (defName def)
    liftIO $ hPutStrLn stderr $ "MC-CAND " ++ name
    unless (null mc) $ liftIO $ hPutStrLn stderr $
      "MC-HIT " ++ name ++ " mc=" ++ show mc
        ++ " rem=" ++ show (maybe [] auRemovable mau)
        ++ " era=" ++ show (maybe [] auErasable mau)
        ++ " arity=" ++ show (maybe (-1) auArity mau)

-- | One view of a type's @Pi@ spine: the domains by position, how many there
-- are, and the final codomain. Two views are consulted for every occurrence
-- question (see 'deletableRemovable'), because neither alone is sound:
--
--   * the __syntactic__ spine ('piSpineOf') is the type as written, which is
--     what a source deletion has to respect — but it stops at a type that
--     only becomes a function after unfolding;
--   * the __reduced__ spine (Agda's @telView@) sees through such a type — but
--     reduction can /erase/ an occurrence entirely: a codomain @Irrel n p@
--     whose @Irrel@ ignores its second argument reduces to @Wrap n@, and the
--     binder the source still mentions has vanished.
--
-- A position is rejected if /either/ view finds an occurrence, which is the
-- conservative direction: it can only shrink the removable set.
data Spine = Spine
  { spDoms :: !(IM.IntMap Type)  -- ^ domain at each position
  , spLen  :: !Int
  , spCore :: Type               -- ^ the codomain, under all 'spLen' binders
  }

-- | Build a view from its domains in position order. The one place
-- @spLen == IM.size spDoms@ is established, so the invariant holds by
-- construction for both views rather than in two parallel spellings.
mkSpine :: [Type] -> Type -> Spine
mkSpine ds core = Spine (IM.fromList (zip [0 ..] ds)) (length ds) core

-- | The reduced view, from @telView@'s output.
telSpine :: Telescope -> Type -> Spine
telSpine tel core = mkSpine (map (snd . unDom) (telToList tel)) core

-- | The syntactic view: walk the @Pi@ spine of the type as stored, without
-- reducing anything.
--
-- __Descend with 'absBody', never @unAbs@.__ A non-dependent @Pi@ is stored as
-- @NoAbs@, whose body is /not/ under the binder — @unAbs@ hands it back
-- unshifted, so a walk using it silently mixes two de Bruijn index spaces and
-- every later occurrence test is answered about the wrong variable.
-- @absBody@ is Agda's accessor for exactly this: it @raise@s a @NoAbs@ body by
-- one. (@telView@ is safe for the same reason — @underAbstraction@ goes through
-- @absBody@.) The sibling 'piSpine' may use @unAbs@ because it reads only
-- hiding and names, never an index.
piSpineOf :: Type -> Spine
piSpineOf t0 = mkSpine ds core
  where
    (ds, core) = go t0
    go t = case unEl t of
      Pi d b -> let (rest, c) = go (absBody b) in (unDom d : rest, c)
      _      -> ([], t)

-- | Is the binder at position @i@ free in the codomain of this view?
-- Positions count from the left and de Bruijn indices from the right, so
-- under all @spLen@ binders the binder at @i@ is @spLen-1-i@. A view too
-- short to say anything about @i@ answers 'False' — it casts no veto — which
-- is the same convention 'freeInDomain' uses for a missing domain.
freeInCore :: Spine -> Int -> Bool
freeInCore sp i
  | i >= spLen sp = False
  | otherwise     = freeIn (spLen sp - 1 - i) (spCore sp)

-- | Is the binder at position @i@ free in the domain at position @j@? Inside
-- domain @j@ the binder at @i@ has index @j-1-i@.
freeInDomain :: Spine -> Int -> Int -> Bool
freeInDomain sp i j =
  maybe False (freeIn (j - 1 - i)) (IM.lookup j (spDoms sp))

-- | Drop the @removable@ positions whose binder cannot actually be deleted,
-- and re-derive everything that depends on the set.
--
-- @removable@ comes from Agda's own verdict, which answers "does the
-- definition's /meaning/ depend on this value" — not "can this binder be
-- deleted". The two come apart for an argument that occurs in the type only at
-- an __irrelevant__ position: @dependentPolarity@ tests occurrence with
-- @relevantInIgnoringSortAnn@, whose @RelevantIn@ monoid /discards/ occurrences
-- under irrelevance (@withVarOcc o x | isIrrelevant o = mempty@,
-- @TypeChecking\/Free.hs@), so such an argument is never demoted to
-- 'Invariant', and @defArgOccurrences@ does not count it either. Both signals
-- are right about their own question; neither is deletability. Reported by the
-- consumer repo; on the standard library it affected 67 of the 145 definitions
-- carrying a @removable@ finding (145 -> 98 defs, 244 -> 142 positions), in
-- three shapes: an irrelevant binder (42); a /relevant/ binder whose only
-- occurrence is at a callee's irrelevant argument position (5 — which no test on
-- the binder itself can see); and an occurrence hidden by /reduction/ (20 — see
-- 'Spine').
--
-- 'auErasable' is untouched: it claims an @\@0@ candidate, not a removal, so
-- occurrences in the type are exactly what it is about.
guardDeletable :: [Spine] -> ArgUsage -> ArgUsage
guardDeletable spines au = au
  { auRemovable         = keep
  , auRemovableRequires = removableRequiresOf keep spines
  , auBinders           = [ b | b@(i, _) <- auBinders au, i `IS.member` reported ]
  }
  where
    keep     = deletableRemovable (auRemovable au) spines
    -- 'auBinders' annotates *reported* positions, so a position the guard
    -- dropped must lose its entry too.
    reported = reportedPositions keep (auErasable au)

-- | The removable positions whose binder can actually be deleted: those whose
-- variable occurs nowhere that survives the deletion.
--
-- The shape is Agda's own @relevantInIgnoringNonvariant@ condition — "ignore
-- the domains of the other 'Nonvariant' arguments, they are going too" — re-run
-- with 'freeIn', which has no relevance filter. So position @i@ is kept unless
-- its variable is free in
--
--   * the codomain, or
--   * the domain of a later position that is __not itself being removed__.
--
-- Occurrences inside another /surviving removable/ domain are fine: that domain
-- goes as well, which is exactly what 'removableRequiresOf' records. Keeping
-- that exemption is what makes this a filter rather than a wrecking ball — a
-- jointly-removable chain like @(X : Set) -> X -> Vec X n -> …@ has its earlier
-- positions free in later removable domains by construction, so a guard without
-- it would reject every multi-index verdict (pinned by @ArgUsage.chain@).
--
-- Hence the fixpoint: rejecting one position can strand an earlier one that
-- only occurred inside it. Iterating to the greatest stable subset is cheap —
-- arities are small and this runs only for a definition that already has a
-- removable finding.
deletableRemovable :: [Int] -> [Spine] -> [Int]
deletableRemovable removable spines = go (IS.fromList removable)
  where
    go !set
      | IS.null doomed = IS.toAscList set
      | otherwise      = go (IS.difference set doomed)
      where
        doomed = IS.fromList [ i | i <- IS.toAscList set, stranded set i ]
    -- Any view that can see the position may veto it.
    stranded set i = any veto spines
      where
        veto sp =
          freeInCore sp i
            || any (freeInDomain sp i)
                   [ j | j <- [i + 1 .. spLen sp - 1], not (j `IS.member` set) ]

-- | Which other removable positions must go with each one.
--
-- If binder @i@ is deleted, every part of the type that still mentions its
-- variable breaks. 'deletableRemovable' has already rejected @i@ if its
-- variable occurs in the codomain or in a surviving argument's domain, so the
-- only place left for it is the domain of another __removable__ argument later
-- in the telescope. So @i@ requires @j@ whenever @j > i@ is removable and
-- @i@'s variable is free in @j@'s domain — then transitively, since removing
-- @j@ drags in whatever @j@ requires.
--
-- (Before the deletability guard this reasoning leaned on 'computePolarity'
-- having ruled out every other position, which is true only up to relevance —
-- the hole that produced the irrelevant-argument defect. The guard now
-- establishes the premise directly.)
--
-- The relation is forward-only (@j > i@ always), which is what makes it a
-- DAG and lets the closure be a plain DFS with no cycle check. It also
-- means a shifted-away section prefix can never be the target of a
-- surviving requirement, so 'dropSectionPrefix' can renumber safely.
--
-- Occurrence uses 'freeIn' rather than Agda's own
-- @relevantInIgnoringSortAnn@: erring towards /more/ requirements only ever
-- makes a suggested removal larger, never unsound.
removableRequiresOf :: [Int] -> [Spine] -> [(Int, [Int])]
removableRequiresOf removable spines =
  [ (i, reqs) | i <- removable, let reqs = closure i, not (null reqs) ]
  where
    -- Direct requirements: j's domain still mentions the variable bound at
    -- i, in *either* view (see 'Spine' — the reduced one can erase the
    -- occurrence, and under-reporting a requirement is what strands a
    -- binder). Inside domain j, the binder at i has de Bruijn index j-1-i.
    -- 'removable' is ascending, so 'dropWhile' is the later-positions
    -- filter. Materialised once per source position: 'closure' revisits
    -- these sets, and each entry costs a 'freeIn' walk of a domain.
    direct = IM.fromList
      [ (i, IS.fromList
              [ j
              | j <- dropWhile (<= i) removable
              , any (\ sp -> freeInDomain sp i j) spines
              ])
      | i <- removable ]
    edges i = IM.findWithDefault IS.empty i direct
    -- Seeded with i's direct targets rather than i itself: the relation
    -- only points forward, so i can never be reached back and needs no
    -- removing from the result.
    closure i = IS.toAscList (go IS.empty (IS.toAscList (edges i)))
      where
        go !seen []       = seen
        go !seen (x : xs)
          | x `IS.member` seen = go seen xs
          | otherwise          = go (IS.insert x seen) (IS.toAscList (edges x) ++ xs)

-- | How many leading binders Agda prepended to this definition from its
-- enclosing section — the ones that are not this definition's to remove.
sectionPrefixSize :: Definition -> TCM Int
sectionPrefixSize def = size <$> lookupSection (qnameModule (defName def))

-- | Drop the indices pointing into a @k@-binder section prefix and re-base
-- the rest onto the definition's own binders.
--
-- The single home of that rule: 'dropSectionPrefix' and the phase-2 probe
-- must shift identically, or the probe's numbers drift from phase 1's while
-- both still look plausible.
shiftOntoOwnBinders :: Int -> [Int] -> [Int]
shiftOntoOwnBinders k = map (subtract k) . filter (>= k)

-- | The positions that carry an 'auBinders' entry: exactly the reported ones.
-- Shared between the raw verdict and the guard so a name annotation can never
-- desynchronise from the verdict it annotates.
reportedPositions :: [Int] -> [Int] -> IS.IntSet
reportedPositions rm er = IS.fromList rm `IS.union` IS.fromList er

-- | Re-index an 'ArgUsage' from the elaborated telescope to the
-- definition's own, dropping the @k@ section-inherited leading binders
-- and everything that pointed into them. Yields 'Nothing' when nothing
-- survives, so a @where@ helper that only \"wastes\" its parent's
-- arguments correctly reports nothing at all.
dropSectionPrefix :: Int -> ArgUsage -> Maybe ArgUsage
dropSectionPrefix k au@(ArgUsage rm rq er ar bs)
  | k <= 0                = Just au
  | null rm' && null er'  = Nothing
  | otherwise             = Just (ArgUsage rm' rq' er' (max 0 (ar - k)) bs')
  where
    shift = shiftOntoOwnBinders k
    rm'   = shift rm
    er'   = shift er
    -- Requirements point forward, so a surviving key's targets all survive
    -- too; a key inside the prefix goes with its binder.
    rq'   = [ (i - k, shift js) | (i, js) <- rq, i >= k ]
    -- Names must be re-indexed with the verdict they annotate, or they
    -- reintroduce exactly the misalignment this shift exists to fix.
    bs'   = [ (i - k, b) | (i, b) <- bs, i >= k ]

-- | The raw verdict, indices over the /elaborated/ telescope. Pure: two
-- field reads, a zip and a walk of the type's 'Pi' spine. 'argUsageOf'
-- wraps it to re-index onto the definition's own binders.
rawArgUsage :: Definition -> Maybe ArgUsage
rawArgUsage def@Defn{..}
  | not analysable                  = Nothing
  | null removable && null erasable = Nothing
  -- Requirements need a reducing 'telView'; 'argUsageOf' fills them in.
  | otherwise = Just (ArgUsage removable [] erasable telArity binders)
  where
    analysable = case theDef of
      Function{} -> droppedPars def == 0
      _          -> False
    -- One strict pass: the two stored lists are zipped, classified and
    -- counted together. This runs for every non-ignored function, so it
    -- allocates no intermediate tuples and walks neither list twice.
    -- Stopping when *either* list runs out IS the padding rule — any
    -- position past the end of one of them counts as used.
    (removable, erasable, analysed) = classify 0 [] [] defArgOccurrences defPolarity
    classify !i !rm !er (o : os) (p : ps) = case o of
      Unused | p == Nonvariant -> classify (i + 1) (i : rm) er os ps
             | otherwise       -> classify (i + 1) rm (i : er) os ps
      _                        -> classify (i + 1) rm er os ps
    classify !i !rm !er _ _ = (reverse rm, reverse er, i)
    -- The syntactic 'Pi' spine (no reduction), widened to cover every
    -- analysed position: 'dependentPolarity' walks a *reduced* spine, so
    -- the stored lists can outrun the unreduced one. The 'max' keeps
    -- @index < auArity@ true without paying for a reduction here.
    spine    = piSpine defType
    telArity = max (length spine) analysed
    -- Reported positions only, in one pass over the spine we already walk
    -- for 'telArity' — so names cost what the count costs. Positions past
    -- the end of the spine (the outrun case above) simply get no entry.
    -- The two verdict lists are disjoint by construction (each index is
    -- classified once) and each ascending, so this stays ascending.
    reported = reportedPositions removable erasable
    binders  = [ (i, b) | (i, b) <- zip [0 ..] spine, i `IS.member` reported ]

-- | The definition's binders as /written/, read off the syntactic 'Pi'
-- spine of its type. Pure and __non-reducing__: hiding is in the domain's
-- argument info and the name in the 'Abs', both sitting on the very spine
-- Agda's own @arity@ counts — so this returns the binders for what the
-- count already cost. A 'telView' would be the wrong tool twice over: it
-- reduces, and a source binder name is not a fact reduction can reveal.
--
-- The result can be __shorter__ than the stored polarity \/ occurrence
-- lists, which 'dependentPolarity' derived from a /reduced/ spine (a type
-- that only becomes a function after unfolding a definition). A position
-- past the end therefore gets no entry at all — silence, not a default,
-- for the same reason the padding rule counts an unlisted position as
-- used.
piSpine :: Type -> [ArgBinder]
piSpine = go . unEl
  where
    go (Pi d b) = ArgBinder (hidingOf (getHiding d)) (suggestName b)
                    : go (unEl (unAbs b))
    go _        = []
    hidingOf Hidden     = BHImplicit
    hidingOf Instance{} = BHInstance
    hidingOf NotHidden  = BHExplicit
    -- 'suggestName' is Agda's own placeholder-aware accessor: it maps the
    -- @"_"@ a nameless domain (@Nat -> Nat@) carries to 'Nothing', so we
    -- never report a name Agda invented.

-- | File-level @{-# OPTIONS ⋯ #-}@ flags that make @agda --safe@ reject a
-- whole module — the module-level analogue of 'UnsafeTag'. The
-- /unconditional single-flag/ escapes from Agda's
-- @Agda.Interaction.Options.Base.unsafePragmaOptions@; RE-SYNC on an Agda
-- bump. A superset across the supported range, so one set serves 2.8 and
-- 2.9 (no CPP).
--
-- Not covered: combination-conditional escapes (e.g. @--without-K@ +
-- @--flat-split@), which a file-token scan can't evaluate without the
-- resolved 'PragmaOptions'; and per-block declaration pragmas (e.g.
-- @{-# NO_POSITIVITY_CHECK #-}@), which are not @OPTIONS@ and never appear
-- in @iFilePragmaOptions@.
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

-- | Keep only the safety-relevant flags ('safetyRelevantOptionFlags') from
-- a module's raw file-level @OPTIONS@ tokens, deduplicated and ascending.
-- Empty when the module declares no file-level escape. Pure: the caller
-- hands it the flattened @iFilePragmaOptions@ token list.
optionEscapes :: [String] -> [String]
optionEscapes toks =
  S.toAscList (S.intersection safetyRelevantOptionFlags (S.fromList toks))

-- | 'nodeKey' of Agda's @primTrustMe@ primitive. Survives 'namesIn' even
-- though the primitive itself is filtered from the node set.
trustMeNodeKey :: String
trustMeNodeKey = "Agda.Builtin.TrustMe.primTrustMe"

-- | How an outbound edge was discovered; emitted as a wire tag (see
-- 'provTag'). Precedence when several apply to the same @(src, dst)@:
-- 'ESignature' > 'EModuleLocal' > 'EBody' > 'EUnknown'.
--
-- There is deliberately no @with@ tag. One existed and could never fire:
-- it was emitted when a dep equalled the source's @funWith@, but @funWith@
-- is non-empty on /exactly/ the definitions 'ignoreDef' drops (it names a
-- with-function's parent), so the tag could only be computed while walking
-- a definition that is never emitted — and 'contractIgnoredEdges' discards
-- inside-chain provenance anyway. A dependency reached only through a
-- with-abstraction therefore arrives on the parent tagged 'EBody', which
-- is the honest answer: post-elaboration we cannot tell it from any other
-- body reference. Recovering it would mean tagging at contraction time
-- (see Backlog.md) — a deliberate wire-content change, not a bug fix.
data EdgeProv
  = ESignature  -- ^ Target appears in @defType@.
  | EBody       -- ^ Target appears only in @theDef@ (not @defType@, not a helper).
  | EModuleLocal -- ^ Target is an anonymous-module helper (@where@-block or
                -- parameterised-section member; Agda spells both alike). A
                -- locally-scoped helper, not ownership. Wire tag: @module-local@.
  | EUnknown    -- ^ Catch-all: instance-method provider edges, or contracted
                -- edges whose chain source provenance was indeterminate.
  deriving (Show, Eq, Ord)

instance NFData EdgeProv where
  rnf x = x `seq` ()

-- | Combine two provenances by precedence, when contraction or
-- instance-method extension reaches the same @(src, dst)@ pair twice.
provPrec :: EdgeProv -> EdgeProv -> EdgeProv
provPrec a b
  | precRank a >= precRank b = a
  | otherwise                = b
  where
    precRank :: EdgeProv -> Int
    precRank ESignature   = 4
    precRank EModuleLocal = 2
    precRank EBody        = 1
    precRank EUnknown     = 0

-- | Wire tag for 'EdgeProv', emitted in expanded JSON's
-- @definitionEdgesProvenance@ array.
provTag :: EdgeProv -> String
provTag ESignature   = "signature"
provTag EBody        = "body"
provTag EModuleLocal = "module-local"
provTag EUnknown     = "unknown"

-- | One node in the dependency graph: a definition plus its direct deps
-- and classification. Invariant: @M.keysSet _depsProv == _deps@ (every
-- kept dep carries exactly one 'EdgeProv' tag).
data ADDef = ADDef
  { _name   :: NodeRef          -- ^ identity of the definition
  , _deps   :: !(Set NodeRef)   -- ^ its dependencies (named free variables)
  , _depsProv :: !(Map NodeRef EdgeProv)
                                -- ^ per-dep provenance tag.
                                -- Invariant: @M.keysSet _depsProv == _deps@.
  , _state  :: !DefState        -- ^ classification used for node colouring
  , _kind   :: !DefKind         -- ^ structural shape from Agda's 'Defn'
  , _line   :: !(Maybe Int)     -- ^ 1-indexed start line of the binding site
  , _access :: !(Maybe DefAccess)
                                -- ^ public/private as seen in the defining
                                -- module's scope. 'Nothing' when unknown.
  , _subtermHashes :: !(Maybe [Word64])
                                -- ^ Canonical-form hashes for every subterm
                                -- in @defType@/@theDef@; under
                                -- @--with-term-hashes@ only. See 'AgdaDeps.TermCanon'.
  , _subtermDepths :: !(Maybe [Int])
                                -- ^ Parallel to '_subtermHashes': AST depth
                                -- of each emitted subterm.
  , _sig    :: !(Maybe String)
                                -- ^ Reified @defType@ (one line, implicits
                                -- hidden) under @--with-signatures@ only;
                                -- emitted as the per-def @"type"@ field.
  , _unsafe :: ![UnsafeTag]
                                -- ^ Direct soundness escapes (see 'UnsafeTag').
                                -- Always computed; emitted as the optional
                                -- @"unsafe"@ array, omitted when empty.
  , _unsolvedMetas :: !Int
                                -- ^ Count of /silent/ unsolved metavariables
                                -- this def mentions: non-interaction open
                                -- metas (missing record fields, failed
                                -- instance search, unsolved @_@) — honest
                                -- interaction @?@s are NOT counted (they only
                                -- set '_state' = 'Hole'). Always computed;
                                -- emitted as the optional per-def
                                -- @"unsolvedMetas"@ field, omitted when 0.
  , _argUsage :: !(Maybe ArgUsage)
                                -- ^ Arguments this def never uses, read
                                -- off Agda's own positivity\/polarity
                                -- analysis (see 'argUsageOf'). Always
                                -- computed; 'Nothing' when there is
                                -- nothing to report, and the optional
                                -- per-def @"argUsage"@ object is then
                                -- omitted.
  } deriving (Show)

instance Pretty ADDef where
  pretty ADDef{..} = vcat [ pshow "Name:"  <+> pretty _name
                          , pshow "State:" <+> pshow _state
                          , pshow "Kind:"  <+> pshow _kind
                          , pshow "Line:"  <+> pshow _line
                          , pshow "Access:" <+> pshow _access
                          , pshow "Deps:"  <+> pretty _deps
                          , pshow "DepsProv:" <+> pshow (M.toAscList _depsProv)
                          , pshow "Unsafe:" <+> pshow _unsafe
                          , pshow "UnsolvedMetas:" <+> pshow _unsolvedMetas
                          , pshow "ArgUsage:" <+> pshow _argUsage ]

-- ** 'Binary' instances for the @--incremental@ fragment cache.
-- Identity is 'NodeRef', not 'QName', so the payload is plain data
-- serialised with 'Data.Binary' — no Agda 'EmbPrj'. Enums are tagged
-- 'Word8's; an out-of-range tag @fail@s the decode (a cache miss).

instance Binary EdgeProv where
  put = B.putWord8 . \case
    ESignature -> 0
    EBody -> 1
    EModuleLocal -> 2
    -- 3 was the retired 'with' tag; the numbering is left with a hole so
    -- the packed wire encoding of the surviving tags does not shift.
    EUnknown -> 4
  get = B.getWord8 >>= \case
    0 -> pure ESignature
    1 -> pure EBody
    2 -> pure EModuleLocal
    4 -> pure EUnknown
    _ -> fail "EdgeProv"

instance Binary DefKind where
  put = B.putWord8 . \case
    DKFunction -> 0
    DKProjection -> 1
    DKDatatype -> 2
    DKRecord -> 3
    DKConstructor -> 4
    DKPostulate -> 5
    DKPrimitive -> 6
    DKOther -> 7
  get = B.getWord8 >>= \case
    0 -> pure DKFunction
    1 -> pure DKProjection
    2 -> pure DKDatatype
    3 -> pure DKRecord
    4 -> pure DKConstructor
    5 -> pure DKPostulate
    6 -> pure DKPrimitive
    7 -> pure DKOther
    _ -> fail "DefKind"

instance Binary DefAccess where
  put = B.putWord8 . \case
    AccPrivate -> 0
    AccPublic -> 1
  get = B.getWord8 >>= \case
    0 -> pure AccPrivate
    1 -> pure AccPublic
    _ -> fail "DefAccess"

instance Binary UnsafeTag where
  put = B.putWord8 . \case
    UNonTerminating -> 0
    UTrustMe -> 1
  get = B.getWord8 >>= \case
    0 -> pure UNonTerminating
    1 -> pure UTrustMe
    _ -> fail "UnsafeTag"

instance Binary ADDef where
  -- '_deps' is derived (@M.keysSet _depsProv@), so it is not serialised but
  -- rebuilt on 'get' — the invariant can never round-trip inconsistent.
  put (ADDef n _ dp s k l a sh sd sg u um au) =
       B.put n *> B.put dp *> B.put s *> B.put k *> B.put l
    *> B.put a *> B.put sh *> B.put sd *> B.put sg *> B.put u *> B.put um
    *> B.put au
  get = do
    n <- B.get; dp <- B.get; s <- B.get; k <- B.get; l <- B.get
    a <- B.get; sh <- B.get; sd <- B.get; sg <- B.get; u <- B.get
    um <- B.get; au <- B.get
    pure (ADDef n (M.keysSet dp) dp s k l a sh sd sg u um au)

instance Binary ArgUsage where
  put (ArgUsage r q e a b) =
    B.put r *> B.put q *> B.put e *> B.put a *> B.put b
  get = ArgUsage <$> B.get <*> B.get <*> B.get <*> B.get <*> B.get

instance Binary ArgBinder where
  put (ArgBinder h n) = B.put h *> B.put n
  get = ArgBinder <$> B.get <*> B.get

instance Binary BinderHiding where
  put = B.putWord8 . \case
    BHExplicit -> 0
    BHImplicit -> 1
    BHInstance -> 2
  get = B.getWord8 >>= \case
    0 -> pure BHExplicit
    1 -> pure BHImplicit
    2 -> pure BHInstance
    _ -> fail "BinderHiding"

-- | Precomputed, serialisable node identity carried through 'ADDef', the
-- side-channels and the emitters. Everything downstream of the per-module
-- walk consumes only these projections — never a live 'QName' or TCM
-- lookup — so a cached fragment round-trips as plain 'Binary' data.
-- Built once, at the producer boundary, by 'mkRef'.
data NodeRef = NodeRef
  { nrKey       :: !String            -- ^ 'nodeKey' — the canonical identity string
  , nrHash      :: !Word64            -- ^ @hashString nrKey@ (fast 'Eq'\/'Ord', and 'hashQName')
  , nrModule    :: !String            -- ^ 'moduleKey' — owning-module attribution
  , nrLine      :: !(Maybe Int)       -- ^ 'bindingLine' — 1-indexed binding-site line
  , nrFile      :: !(Maybe FilePath)  -- ^ binding-site source file (for 'nrSrcLoc')
  , nrShort     :: !String            -- ^ unqualified display name: last @.@-segment of @prettyShow@
  , nrIgnorable :: !Bool              -- ^ precomputed @ignoreDef@, so
                                      --   'contractIgnoredEdges' needs no TCM on cached defs
  , nrWhereHelper :: !Bool            -- ^ @"._." `isInfixOf` prettyShow@ — the
                                      --   module-local (where/anon-module) marker.
                                      --   Serialised: not derivable from 'nrKey' (has @._.@ stripped).
  }

-- 'Eq'\/'Ord' compare the (hash, key) pair — hash first for Int-fast
-- containers, key to break the rare collision. A live ref and a rehydrated
-- cached ref with the same identity compare equal.
instance Eq NodeRef where
  a == b = nrHash a == nrHash b && nrKey a == nrKey b
instance Ord NodeRef where
  compare a b = compare (nrHash a) (nrHash b) <> compare (nrKey a) (nrKey b)
instance Show NodeRef where
  show = nrKey
instance Pretty NodeRef where
  pretty = pretty . nrKey
instance NFData NodeRef where
  rnf (NodeRef a b c d e f g h) =
    rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` rnf e `seq` rnf f
      `seq` rnf g `seq` rnf h
instance Binary NodeRef where
  -- 'nrHash' is derived (@hashString nrKey@) and rebuilt on 'get'.
  -- 'nrWhereHelper' (h) IS serialised: 'nrKey' has the @._.@ marker
  -- stripped by 'liftAnonSegments', so it can't be recovered.
  put (NodeRef a _ c d e f g h) =
    B.put a >> B.put c >> B.put d >> B.put e >> B.put f >> B.put g >> B.put h
  get = do
    a <- B.get; c <- B.get; d <- B.get; e <- B.get; f <- B.get; g <- B.get
    h <- B.get
    pure (NodeRef a (hashString a) c d e f g h)

-- ** QName-level identity logic (producer boundary only)

-- | Canonical node-identity string for a 'QName'. Anonymous-module segments
-- (the @._.@ marker Agda uses for both @where@ helpers and @module _ (…)
-- where@ members) are lifted into the nearest named ancestor via
-- 'liftAnonSegments' (@Mod._.helper@ ↦ @Mod.helper@). Lifting collapses the
-- @_@ qualifier, so same-named helpers are disambiguated by binding line
-- (@Mod.helper\@15@); one with no binding site falls back to the lifted name.
--
-- Single source of truth for node identity (stored as 'nrKey'; the wire
-- @"name"@ and edge endpoints are this string). Do not revert to bare
-- 'prettyShow': same-named @where@-helpers collapse onto one node and lose
-- their edges. 'moduleKeyOfQ' is the matching module-attribution function.
nodeKeyOfQ :: QName -> String
nodeKeyOfQ qn = nodeKeyFromPretty (prettyShow qn) (bindingLineOfQ qn)

-- | 'nodeKeyOfQ' with the @prettyShow@ string and binding line supplied by
-- 'mkRef', which already has both for other fields.
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

-- | @(source file, 1-indexed line)@ of a 'QName''s binding occurrence.
-- Lives here (not 'AgdaDeps.Source', which imports 'Deps') to avoid an
-- import cycle; 'Source' consumes it via 'nrSrcLoc'.
srcLocOfQ :: QName -> Maybe (FilePath, Word32)
srcLocOfQ qn = do
  let bindRange = nameBindingSite (qnameName qn)
  rf <- case rangeFile bindRange of
          Strict.Just rf -> Just rf
          Strict.Nothing -> Nothing
  p  <- rStart bindRange
  return (filePath (rangeFilePath rf), posLine p)

-- | Build the precomputed 'NodeRef' for a 'QName', memoised per 'QName'.
-- A 'NodeRef' is a deterministic function of its 'QName' (its one impure
-- input, @getConstInfo@ via 'ignoreDependency', is process-stable), so the
-- bundle is built once per distinct name regardless of edge count. The
-- cache is process-lived: 'QName' identity is stable, nothing to reset.
mkRef :: QName -> TCM NodeRef
mkRef qn = do
  cache <- liftIO (readIORef nodeRefCacheRef)
  case M.lookup qn cache of
    Just r  -> return r
    Nothing -> do
      ign <- ignoreDependency qn
      let !raw   = prettyShow qn
          !mbLn  = bindingLineOfQ qn
          !key   = nodeKeyFromPretty raw mbLn
          !short = (reverse . takeWhile (/= '.') . reverse) raw
          !isWH  = "._." `isInfixOf` raw   -- where-helper marker
          !r = NodeRef
            { nrKey       = key
            , nrHash      = hashString key
            , nrModule    = moduleKeyOfQ qn
            , nrLine      = mbLn
            , nrFile      = fst <$> srcLocOfQ qn
            , nrShort     = short
            , nrIgnorable = ign
            , nrWhereHelper = isWH
            }
      liftIO $ modifyIORef' nodeRefCacheRef (M.insert qn r)
      return r

{-# NOINLINE nodeRefCacheRef #-}
nodeRefCacheRef :: IORef (Map QName NodeRef)
nodeRefCacheRef = unsafePerformIO (newIORef M.empty)

-- ** Blessed identity accessors (NodeRef; used everywhere downstream)

-- | Canonical node-identity string. See 'nodeKeyOfQ'.
nodeKey :: NodeRef -> String
nodeKey = nrKey

-- | Owning-module attribution string. See 'moduleKeyOfQ'.
moduleKey :: NodeRef -> String
moduleKey = nrModule

-- | 1-indexed binding-site line, if any.
bindingLine :: NodeRef -> Maybe Int
bindingLine = nrLine

-- | @(source file, line)@ of the binding occurrence, if fully known.
nrSrcLoc :: NodeRef -> Maybe (FilePath, Word32)
nrSrcLoc r = (,) <$> nrFile r <*> (fromIntegral <$> nrLine r)

-- | Version of the node-key convention emitted by 'nodeKeyOfQ'. Stamped
-- into @graph.json@ so a consumer can detect a stale-format cached graph.
-- Bump whenever the key shape changes. Currently 3 (anonymous-module
-- segments lifted into the nearest named ancestor).
nodeKeyVersion :: Int
nodeKeyVersion = 3

-- | Stable integer ID for a node, shared by every renderer. The hash of
-- 'nodeKey', so distinct same-named @where@/anonymous-module helpers hash
-- to distinct ids.
hashQName :: NodeRef -> Int
hashQName = fromIntegral . nrHash

-- | Every node that appears in the graph (definition identities plus
-- their dependencies), deduplicated by 'hashQName'. Result is in
-- ascending hashQName order. 'IM.insert' is "last write wins" on hash
-- collision.
collectAllQNames :: [ADDef] -> [NodeRef]
collectAllQNames defs = IM.elems (foldl' addDef IM.empty defs)
  where
    addDef :: IM.IntMap NodeRef -> ADDef -> IM.IntMap NodeRef
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
      notExcluded qn = not (isExcludedModule excludes (moduleKeyOfQ qn))
      -- Walk 'defType' and 'theDef' separately to record which set each
      -- name came from. Raw walks are shared with 'classifyDefWith' (one
      -- traversal each); 'ignoreDependency' is applied later in
      -- 'contractIgnoredEdges'.
      !rawSig    = namesIn defType
      !rawBody   = namesIn theDef
      !sigNames  = S.fromList (filter notExcluded rawSig)
      !bodyNames = S.fromList (filter notExcluded rawBody)
      !deps      = S.union sigNames bodyNames
  -- Reuse the raw (pre-exclude) name walks: a synthetic @unsolved#meta.*@
  -- name in an excluded module must still flip the Hole classification.
  (st, silentMetas) <- classifyDefWith rawSig rawBody def
  let !kd      = classifyKind def
      !termPairs = if optWithTermHashes opts
                     then Just (concatMap (subtermHashes (optMinTermDepth opts))
                                          (definitionTerms def))
                     else Nothing
      (!termHs, !termDs) = case termPairs of
        Just ps -> let (hs, ds) = unzip ps in (Just hs, Just ds)
        Nothing -> (Nothing, Nothing)
  -- Reify 'defType' via 'prettyTCM', collapsed to one line.
  -- '--normalise-signatures' reduces first; '--show-implicit' shows
  -- implicit/irrelevant arguments.
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
      usesTrustMe = any ((== trustMeNodeKey) . nodeKeyOfQ) (rawSig ++ rawBody)
      !unsafeTags = termTag ++ [ UTrustMe | usesTrustMe ]
  -- Never-used arguments, read off Agda's positivity/polarity analysis.
  -- The state read inside only fires for a def that has a finding.
  argUsage <- argUsageOf def
  -- Convert to 'NodeRef' at the producer boundary: everything downstream
  -- is identity-as-data.
  nameRef  <- mkRef defName
  -- Tag each edge as its 'NodeRef' is built (one pass), reading the
  -- precomputed 'nrWhereHelper' bit instead of a per-edge 'prettyShow'.
  -- 'S.toAscList' fixes the key order, so 'M.fromList''s last-wins on
  -- colliding NodeRefs is deterministic.
  provPairs <- mapM (\ q -> do
                       r <- mkRef q
                       let !p = tagOneWith sigNames bodyNames q (nrWhereHelper r)
                       pure (r, p))
                    (S.toAscList deps)
  let !depsProvR = M.fromList provPairs
      !depsR     = M.keysSet depsProvR
  return ADDef
    { _name   = nameRef
    , _deps   = depsR
    , _depsProv = depsProvR
    , _state  = st
    , _kind   = kd
    , _line   = nrLine nameRef
    , _access = Nothing  -- back-filled in postCompile from iScope
    , _subtermHashes = termHs
    , _subtermDepths = termDs
    , _sig    = sigStr
    , _unsafe = unsafeTags
    , _unsolvedMetas = silentMetas
    , _argUsage = argUsage
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
-- signature > module-local > body > unknown. The module-local test
-- is the target's precomputed 'nrWhereHelper' bit (@"._." `isInfixOf`
-- prettyShow@), passed in, so no per-edge 'prettyShow' is paid.
tagOneWith
  :: S.Set QName        -- ^ names from @defType@
  -> S.Set QName        -- ^ names from @theDef@
  -> QName              -- ^ the dep to tag
  -> Bool               -- ^ target's 'nrWhereHelper'
  -> EdgeProv
tagOneWith sigNames bodyNames qn isWhere
  | qn `S.member` sigNames        = ESignature
  | isWhere                       = EModuleLocal
  | qn `S.member` bodyNames       = EBody
  | otherwise                     = EUnknown

-- | 1-indexed start line of a 'QName''s binding site, if Agda recorded a
-- usable range. Synthetic names (e.g. @unsolved#meta.*@) return 'Nothing'.
bindingLineOfQ :: QName -> Maybe Int
bindingLineOfQ qn =
  let r = nameBindingSite (qnameName qn)
  in fromIntegral . posLine <$> rStart r

-- | Per-definition entry point used by the Agda backend hook.
--
-- For *ignored* definitions (with-helpers, pattern lambdas, Kan ops,
-- module-instantiation copies, …) records the raw out-edges into
-- 'ignoredEdgesRef' before returning 'Nothing', so 'contractIgnoredEdges'
-- can stitch real-to-real edges across chains of ignored defs.
--
-- Side-effect: for instance binders (see 'recordInstanceMethods') records
-- the binder as a provider for each projection method it supplies into
-- 'methodProvidersRef' (consumed by 'addInstanceMethodEdges').
compileDefAD :: Options -> env -> IsMain -> Definition -> TCM (Maybe ADDef)
compileDefAD opts _ _ def@Defn{..}
  | ignoreDef def = do
      -- Record raw out-edges without applying 'ignoreDependency' (refs to
      -- other ignored defs are kept so the closure pass can chain through).
      -- Module-exclusion still applies.
      let notExcluded qn = not (isExcludedModule excludes (moduleKeyOfQ qn))
          !sigNames  = S.fromList (filter notExcluded (namesIn defType))
          !bodyNames = S.fromList (filter notExcluded (namesIn theDef))
          !raw       = S.union sigNames bodyNames
      -- Convert to NodeRef at the boundary (see 'computeDefAD'); tag edges
      -- off the precomputed 'nrWhereHelper' bit.
      nameRef  <- mkRef defName
      provPairs <- mapM (\ q -> do
                           r <- mkRef q
                           let !p = tagOneWith sigNames bodyNames q (nrWhereHelper r)
                           pure (r, p))
                        (S.toAscList raw)
      recordIgnoredDef nameRef (M.fromList provPairs)
      return Nothing
  | isExcludedModule excludes (moduleKeyOfQ defName) = return Nothing
  | otherwise = do
      recordInstanceMethods def
      Just <$> computeDefAD opts def
  where
    excludes = optExcludeModules opts

-- | If @def@ looks like an instance binder, record it as a provider for
-- every projection method it dispatches. Two signals:
--
--   1. 'defInstance' is 'Just _' (any @instance ⋯@); credited even when no
--      method names are recoverable from the body (e.g. @R ∋ record { ⋯ }@).
--   2. Body is a 'Function' whose head pattern is a 'ProjP' (the
--      @R ∋ λ where ._method → …@ copattern-lambda idiom); the projection
--      'QName's are the supplied methods.
recordInstanceMethods :: Definition -> TCM ()
recordInstanceMethods Defn{..} =
  let isInstance = isJust defInstance
      methods    = projectionMethods theDef
  in when (isInstance || not (null methods)) $ do
       binderRef  <- mkRef defName
       methodRefs <- mapM mkRef methods
       recordMethodProviders binderRef methodRefs
  where
    -- Pull the projection QName off each clause's head pattern. The
    -- @R ∋ λ where@ shape has one ProjP per clause; anything else yields [].
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
-- Raw out-edges of each ignored def that 'compileDefAD' drops, keyed by the
-- ignored def, so a kept def referencing it can see what it transitively
-- reaches. Mutable global state, not persisted. The per-edge 'EdgeProv' is
-- the same tagging as kept defs; contraction discards the inside-chain
-- provenance and inherits the kept def's tag (see 'contractWith').
type IgnoredEdgeMap = Map NodeRef (Map NodeRef EdgeProv)

{-# NOINLINE ignoredEdgesRef #-}
ignoredEdgesRef :: IORef IgnoredEdgeMap
ignoredEdgesRef = unsafePerformIO $ newIORef M.empty

-- | Clear the side-channel map. Called at the start of a compile so
-- repeated in-process invocations stay independent.
resetIgnoredEdges :: MonadIO m => m ()
resetIgnoredEdges = liftIO $ writeIORef ignoredEdgesRef M.empty

-- | Record an ignored def's out-edges (strict 'modifyIORef'').
recordIgnoredDef :: MonadIO m => NodeRef -> Map NodeRef EdgeProv -> m ()
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
type MethodProviderMap = Map NodeRef [NodeRef]

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
recordMethodProviders :: MonadIO m => NodeRef -> [NodeRef] -> m ()
recordMethodProviders binder methods =
  liftIO $ modifyIORef' methodProvidersRef $ \m ->
    foldl' (\acc method ->
              M.insertWith (\_ old -> binder : old) method [binder] acc)
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

    collect :: MethodProviderMap -> Set NodeRef -> NodeRef -> Set NodeRef
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
expandThroughIgnored :: MonadIO m => Set NodeRef -> m (Set NodeRef)
expandThroughIgnored frontier0 = do
  hidden <- liftIO $ readIORef ignoredEdgesRef
  pure $ bfsClosure hidden frontier0

-- | Post-pass: rewrite each 'ADDef'@._deps@ + @._depsProv@ by contracting
-- through the side-channel of ignored defs, then drop leaf deps that
-- 'ignoreDef' classifies as ignorable. Called once from 'postCompileAD'
-- after every def is processed (so the side-channel is complete).
--
-- Expansion is memoized per ignored-def key ('buildIgnoredClosure'): each
-- hidden key's closure of real, non-ignored targets is computed once. At
-- the kept-def boundary each real target inherits the kept def's
-- provenance towards the chain entry (the hidden helper).
contractIgnoredEdges :: [ADDef] -> TCM [ADDef]
contractIgnoredEdges defs = do
  hidden <- liftIO $ readIORef ignoredEdgesRef
  let memo = buildIgnoredClosure hidden
  pure (map (rewriteOne hidden memo) defs)
  where
    -- Expand a kept def's raw dep map through the hidden chain and drop
    -- ignored targets in the SAME pass. Ignorability is the precomputed
    -- 'nrIgnorable' bit (built in 'mkRef'), so this is a pure Bool read —
    -- no TCM on rehydrated cache-hit defs.
    rewriteOne hidden memo d =
      let expanded  = contractWith hidden memo (_depsProv d)
          !keptProv = M.filterWithKey (\ k _ -> not (nrIgnorable k)) expanded
      in d { _deps = M.keysSet keptProv, _depsProv = keptProv }

    -- Expand a kept def's raw dep map: every ignored-def key is replaced by
    -- its cached closure of real targets (each inheriting the kept def's tag
    -- towards the key); every other QName keeps its original tag. A target
    -- reached by two paths gets the higher-precedence tag via 'provPrec'.
    contractWith
      :: IgnoredEdgeMap
      -> Map NodeRef (Set NodeRef)
      -> Map NodeRef EdgeProv
      -> Map NodeRef EdgeProv
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
                -- In 'hidden' but missing from memo (a cycle member): BFS.
                let !extra = bfsClosure hidden (S.singleton qn)
                in S.foldl'
                     (\ !m realTgt -> M.insertWith provPrec realTgt provFromSrc m)
                     acc extra
            | otherwise -> M.insertWith provPrec qn provFromSrc acc

-- | Standalone BFS closure, used by 'expandThroughIgnored' and as the
-- fallback in 'contractIgnoredEdges'. @frontier0@ is the set of
-- starting QNames; the result is every reachable QName that's *not* an
-- ignored-def key. 'EdgeProv' tags inside the closure are discarded.
bfsClosure :: IgnoredEdgeMap -> Set NodeRef -> Set NodeRef
bfsClosure hidden frontier0 =
  let initial :: Seq NodeRef
      initial = Seq.fromList (S.toList frontier0)
      (_, kept) = go initial IS.empty S.empty
  in kept
  where
    go :: Seq NodeRef -> IS.IntSet -> Set NodeRef
       -> (IS.IntSet, Set NodeRef)
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
buildIgnoredClosure :: IgnoredEdgeMap -> Map NodeRef (Set NodeRef)
buildIgnoredClosure hidden = withCycles
  where
    keys :: Set NodeRef
    keys = M.keysSet hidden

    -- Forward adjacency partitioned once into (hiddenDeps, nonHiddenDeps);
    -- per-edge provenance inside the chain is discarded.
    adj :: Map NodeRef (Set NodeRef, Set NodeRef)
    adj = M.map partitionEntry hidden
      where
        partitionEntry :: Map NodeRef EdgeProv -> (Set NodeRef, Set NodeRef)
        partitionEntry m =
          let !ks = M.keysSet m
          in S.partition (`S.member` keys) ks

    -- Reverse adjacency on the hidden→hidden subgraph.
    revAdj :: Map NodeRef (Set NodeRef)
    revAdj = M.foldlWithKey' addRev M.empty adj
      where
        addRev !m k (hDeps, _) =
          S.foldl'
            (\ !acc d -> M.insertWith S.union d (S.singleton k) acc)
            m hDeps

    -- Initial out-degree: number of hidden deps each key has.
    outDeg0 :: Map NodeRef Int
    outDeg0 = M.map (S.size . fst) adj

    -- Seed Kahn's with every node whose hidden-deps set is empty.
    seed :: Seq NodeRef
    seed = Seq.fromList
      [ k | (k, (h, _)) <- M.toList adj, S.null h ]

    -- Bottom-up DP. By the Kahn invariant, every hidden dep of @k@ is
    -- in @memo@ when @k@ is popped, so the union is a straight lookup.
    kahn :: Map NodeRef (Set NodeRef) -> Map NodeRef Int -> Seq NodeRef
         -> Map NodeRef (Set NodeRef)
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
    cycleMembers :: Set NodeRef
    cycleMembers = keys `S.difference` M.keysSet partial

    withCycles :: Map NodeRef (Set NodeRef)
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

-- | Classify a 'Definition' as fully-defined, postulate, or hole-bearing.
-- Holes: an open 'MetaV' left in 'defType'/'theDef', a reference to an
-- @unsolved#meta.*@ name (Agda's @openMetasToPostulates@ output under
-- @--allow-unsolved-metas@), or the def's own name being such a marker.
classifyDef :: Definition -> TCM DefState
classifyDef def@Defn{..} =
  fst <$> classifyDefWith (namesIn defType) (namesIn theDef) def

-- | 'classifyDef' with the @defType@/@theDef@ name walks supplied by the
-- caller, so 'computeDefAD' avoids a second traversal. The lists must be
-- the *raw* (pre-exclude-filter) names.
--
-- Also returns the def's /silent/ unsolved-meta count ('_unsolvedMetas'):
-- distinct referenced @unsolved#meta.*@ markers that are silent
-- ('markerIsSilent'; the def's own name counts when it is such a marker)
-- plus distinct open metas that are not interaction points. State semantics
-- are unchanged — a silent meta also implies the state the old classifier
-- assigned ('Hole', or 'Postulate' for an 'Axiom'-typed def); the count is
-- the additive discriminator between an honest @?@ and silently-missing
-- evidence (missing record field, failed instance search, unsolved @_@).
classifyDefWith :: [QName] -> [QName] -> Definition -> TCM (DefState, Int)
classifyDefWith sigRaw bodyRaw Defn{..}
  | isUnsolvedMetaName defName = do
      silent <- markerIsSilent defName
      return (Hole, if silent then 1 else 0)
  | otherwise = do
      let markers = dedupOrd (filter isUnsolvedMetaName (sigRaw ++ bodyRaw))
          metas   = dedupOrd (allMetasList defType ++ metasInDefn theDef)
      openMs     <- filterM isMetaUnsolved metas
      silentRefs <- filterM markerIsSilent markers
      silentOpen <-
        if null openMs then pure [] else do
          iset <- getInteractionMetaSet
          pure [ m | m <- openMs, not (S.member m iset) ]
      let !cnt = length silentRefs + length silentOpen
          !st  = case theDef of
            Axiom{}                -> Postulate
            _ | not (null markers) -> Hole
              | not (null openMs)  -> Hole
              | otherwise          -> Defined
      return (st, cnt)
  where
    isMetaUnsolved :: MetaId -> TCM Bool
    isMetaUnsolved m = isOpenMeta <$> lookupMetaInstantiation m

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

-- ** silent (non-interaction) unsolved metas
--
-- Agda's own split between an honest interaction @?@
-- (@UnsolvedInteractionMetas@) and a silently-inserted unsolved meta
-- (@UnsolvedMetaVariables@: missing record field, failed instance search,
-- unsolved @_@) survives to backend time through two signals:
--
--   * /Interfaces/ (imported modules, whose open metas
--     @openMetasToPostulates@ turned into @unsolved#meta.*@ markers):
--     @warningHighlighting@ folded an 'UnsolvedMeta' aspect over each
--     silent meta's range into 'iHighlighting' *before* postulation, and
--     interaction metas got no aspect — so a marker is silent iff its
--     binding site falls inside an 'UnsolvedMeta' span of its file.
--   * /Live state/ (the main module, which is never postulated): open
--     metas minus 'getInteractionMetas'.

-- | Merged character-offset spans (half-open, 1-based 'posPos' space)
-- carrying the given aspect in an interface's stored highlighting.
aspectSpans :: OtherAspect -> HighlightingInfo -> [(Int, Int)]
aspectSpans asp hi = mergeSpans
  [ (HR.from r, HR.to r)
  | (r, m) <- RangeMap.toList hi
  , asp `S.member` otherAspects m
  ]

-- | Sort and coalesce overlapping/adjacent spans. One meta's range can be
-- split across several 'RangeMap' entries when token highlighting merged
-- into it, so raw entry counts are meaningless; merged spans support the
-- membership test and per-line reporting.
mergeSpans :: [(Int, Int)] -> [(Int, Int)]
mergeSpans = go . sort
  where
    go ((a1, b1) : (a2, b2) : rest)
      | a2 <= b1  = go ((a1, max b1 b2) : rest)
    go (s : rest) = s : go rest
    go []         = []

-- | Source file → 'UnsolvedMeta' spans, over every visited interface.
-- Built once per process on first demand (backend hooks run only after all
-- modules are checked, so the visited set is complete). A file appears
-- only when it has at least one silent span; its path is recovered from
-- the binding site of any of the interface's own definitions (always
-- available when the module has an @unsolved#meta.*@ marker to test —
-- the marker itself carries the meta's range).
getSilentSpansByFile :: TCM (Map FilePath [(Int, Int)])
getSilentSpansByFile = do
  cached <- liftIO (readIORef silentSpansCacheRef)
  case cached of
    Just m  -> return m
    Nothing -> do
      visited <- getVisitedModules
      let m = M.fromList
            [ (f, spans)
            | mi <- M.elems visited
            , let iface = miInterface mi
                  spans = aspectSpans UnsolvedMeta (iHighlighting iface)
            , not (null spans)
            , f <- take 1 (ifaceFiles iface)
            ]
      liftIO (writeIORef silentSpansCacheRef (Just m))
      return m

-- | Candidate source paths of an interface, from its signature defs'
-- binding sites (a def's binding site is always in its own file).
ifaceFiles :: Interface -> [FilePath]
ifaceFiles iface =
  [ f
  | q <- HMap.keys (iSignature iface ^. sigDefinitions)
  , (f, _) <- maybeToList (srcLocOfQ q)
  ]

{-# NOINLINE silentSpansCacheRef #-}
silentSpansCacheRef :: IORef (Maybe (Map FilePath [(Int, Int)]))
silentSpansCacheRef = unsafePerformIO (newIORef Nothing)

-- | MetaIds of unsolved interaction points, memoised once per process
-- (like 'getSilentSpansByFile', the set is final by backend time).
getInteractionMetaSet :: TCM (Set MetaId)
getInteractionMetaSet = do
  cached <- liftIO (readIORef interactionMetaSetRef)
  case cached of
    Just s  -> return s
    Nothing -> do
      s <- S.fromList <$> getInteractionMetas
      liftIO (writeIORef interactionMetaSetRef (Just s))
      return s

{-# NOINLINE interactionMetaSetRef #-}
interactionMetaSetRef :: IORef (Maybe (Set MetaId))
interactionMetaSetRef = unsafePerformIO (newIORef Nothing)

-- | Whether an @unsolved#meta.*@ marker stands for a /silent/ unsolved
-- meta (as opposed to an honest interaction @?@): its binding site — the
-- original meta's range — falls inside an 'UnsolvedMeta' highlighting span
-- of its file. Unresolvable locations default to 'False' (never a false
-- alarm on an honest hole).
markerIsSilent :: QName -> TCM Bool
markerIsSilent qn = do
  spansByFile <- getSilentSpansByFile
  return $ fromMaybe False $ do
    let bindRange = nameBindingSite (qnameName qn)
    rf <- case rangeFile bindRange of
            Strict.Just rf -> Just rf
            Strict.Nothing -> Nothing
    p  <- rStart bindRange
    spans <- M.lookup (filePath (rangeFilePath rf)) spansByFile
    let off = fromIntegral (posPos p)
    pure (any (\(a, b) -> off >= a && off < b) spans)

-- | Per-interface rollup: @(silent unsolved-meta lines, unsolved-constraint
-- lines)@, both ascending and 1-indexed. Meta lines are exact — one entry
-- per silent @unsolved#meta.*@ marker in the interface's signature (the
-- main module has none; its live metas come from 'liveSilentMetaLines').
-- Constraint lines are the lines opening each 'UnsolvedConstraint'
-- highlighting span (deduplicated; a span count would be distorted by
-- range coalescing).
unsolvedInterfaceLines :: Interface -> TCM ([Int], [Int])
unsolvedInterfaceLines iface = do
  let markers = [ q | q <- HMap.keys (iSignature iface ^. sigDefinitions)
                    , isUnsolvedMetaName q ]
  silent <- filterM markerIsSilent markers
  let metaLs = sort [ fromIntegral ln | q <- silent
                                      , (_, ln) <- maybeToList (srcLocOfQ q) ]
      conLs  = dedupOrd
        [ offsetToLine (iSource iface) a
        | (a, _) <- aspectSpans UnsolvedConstraint (iHighlighting iface)
        ]
  return (metaLs, conLs)

-- | 1-indexed line containing a 1-based character offset of a source text.
offsetToLine :: TL.Text -> Int -> Int
offsetToLine src off =
  1 + fromIntegral (TL.count (TL.singleton '\n') (TL.take (fromIntegral off - 1) src))

-- | Source lines of the /live/ silent unsolved metas: open metas that are
-- not interaction points, read from TCM state. Non-empty only for the main
-- module (imports were postulated into markers before their state was
-- discarded), so the caller attributes these to the entry module.
liveSilentMetaLines :: TCM [Int]
liveSilentMetaLines = do
  rs <- getUnsolvedMetas
  return $ sort [ fromIntegral (posLine p) | r <- rs, p <- maybeToList (rStart r) ]

-- ** filtering

ignoreDependency :: QName -> TCM Bool
ignoreDependency qn = do
  def <- getConstInfo qn
  return $ ignoreDef def

-- | True for the defs Agda synthesises for a @variable@ block (the
-- @GeneralizeTel@ record, its @mkGeneralizeTel@ constructor, and
-- @generalizedField-*@ projections) — none user-written, all dropped.
--
-- 2.8/2.9 delta: 2.9 prefixes each with a @NoName@ segment 'prettyShow'
-- renders as a leading @.@ (name contains @..@); 2.8 spells
-- @GeneralizeTel@/@mkGeneralizeTel@ without it. Matching the base name on
-- 'qnameName' catches both; the @..@ test covers other @NoName@-qualified
-- generated defs. Pinned by @test/Test.agda@'s @variable a b : Set@.
isGeneralizeName :: QName -> Bool
isGeneralizeName qn =
     ".." `isInfixOf` prettyShow qn
  || "GeneralizeTel" `isInfixOf` n
  || "generalizedField-" `isInfixOf` n
  where n = prettyShow (qnameName qn)

ignoreDef :: Definition -> Bool
-- Module-instantiation copies ('defCopy'): alias nodes re-exporting the
-- real def under an importing module. Short-circuits before 'theDef', so it
-- catches all kinds (Function/Record/Datatype/Constructor), not just the
-- Function case 'funInline' covers.
ignoreDef Defn{..} | defCopy = True
-- Auto-generated @variable@-block names (see 'isGeneralizeName').
ignoreDef Defn{..} | isGeneralizeName defName = True
ignoreDef Defn{..} = case theDef of

  -- Pattern-lambda / with-generated / Kan-op functions.
  Function{..} | isJust funExtLam || isWithFun funWith || isJust funIsKanOp -> True
  -- Do NOT remove: drops user @{-# INLINE #-}@ functions. Agda inlines every
  -- call site during type-checking, so an INLINE function has zero incoming
  -- edges by hook time — keeping it adds a false-"dead" orphan.
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
