{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
-- General clause evidence. This is inspection data, never a reduction oracle.
module AgdaDeps.TermExport
  ( initializeTermExport, captureTermDefinition, readTermEvidence ) where

import Control.DeepSeq (NFData,force)
import Control.Exception (evaluate)
import GHC.Generics (Generic)
import Control.Monad (forM, forM_, when)
import Control.Monad.Except (catchError)
import Control.Monad.IO.Class (liftIO)
import qualified Control.Monad.State.Strict as ST
import qualified Data.Aeson as A
import qualified Data.Aeson.Encoding as AE
import Data.Aeson ((.=))
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import System.IO.Unsafe (unsafePerformIO)
import Agda.Syntax.Common (Arg(..), Named(..), getArgInfo)
import Agda.Syntax.Literal (Literal(..))
import Agda.Syntax.Internal
  ( Term(..), pattern Var, Elim'(..), Clause(..), Pattern'(..), PatternInfo(..), PatOrigin(..), DBPatVar(..), DeBruijnPattern
  , conName, clausePats )
#if MIN_VERSION_Agda(2,9,0)
import Agda.Syntax.Internal (ClauseRecursive(..))
#endif
import Agda.TypeChecking.Monad
  ( TCM, Definition(..), pattern Function, funClauses, funProjection, funWith, funExtLam
  , pattern Primitive, primClauses, pattern Constructor, conPars
  , Projection(..), getConstInfo, defAbstract, defOpaque
  , inTopContext, addContext, localTCState )
import qualified Agda.TypeChecking.CheckInternal as Internal
import qualified Agda.TypeChecking.Monad as TC
import Agda.Syntax.Internal.Names (namesIn)
import Agda.Utils.Hash (hashString)
import AgdaDeps.Util (withFunParent,boundedQueryTCM,definitionSectionParameters)
import AgdaDeps.NodeKey
import AgdaDeps.Options
import AgdaDeps.TermCodec

data PatternTree a=PatternTree String String [String] (Maybe Int) (Maybe a) [PatternTree a] deriving Generic
instance NFData a => NFData (PatternTree a)
data CapturedClause a=CapturedClause [a] [PatternTree a] (Maybe a) (Maybe a) (Maybe Bool) (Maybe Bool) [([Int],a)] deriving Generic
instance NFData a => NFData (CapturedClause a)
data Captured a=Captured String String (Maybe Int) (Maybe FilePath) Int a [CapturedClause a] String (Maybe Int) (Maybe Int) String String (Maybe String) deriving Generic
instance NFData a => NFData (Captured a)

data ExportState=ExportState Bool (M.Map String (Captured Int)) (S.Set String) (M.Map String String) (M.Map String Int) Intern (M.Map String (S.Set String))
{-# NOINLINE exportRef #-}
exportRef :: IORef ExportState
exportRef=unsafePerformIO (newIORef (ExportState False M.empty S.empty M.empty M.empty (M.empty,M.empty) M.empty))
initializeTermExport :: Bool -> IO ()
initializeTermExport enabled=writeIORef exportRef (ExportState enabled M.empty S.empty M.empty M.empty (M.empty,M.empty) M.empty)

rootNodeLimit, auxiliaryLimit, closureDepth :: Int
rootNodeLimit=10000
auxiliaryLimit=512
closureDepth=2

captureTermDefinition :: Options -> Bool -> Maybe FilePath -> Definition -> TCM ()
captureTermDefinition opts ignored file def=do
  let owner=moduleKeyOfQ (defName def)
      selected=null (optTermScopes opts) || any (\scope->owner==scope || (scope++".") `isPrefixOf` owner) (optTermScopes opts)
  when (optWithTerms opts && not ignored) $ do
    if selected then do
      liftIO $ modifyIORef' exportRef $ \(ExportState e ds roots omitted depths pool refs)->ExportState e ds (S.insert (nodeKeyOfQ $ defName def) roots) omitted depths pool refs
      capture closureDepth True file def
    else when (not (optNoExternals opts) && equalitySignature (typeTree $ defType def)) $ capture (-1) False file def
  where
    treeNodes (Tree _ _ _ _ children)=():concatMap treeNodes children
    variablePattern arg=case unArg arg of VarP{}->True;_->False
    excluded d=any (\scope->let owner=moduleKeyOfQ (defName d) in owner==scope || (scope++".") `isPrefixOf` owner) (optExcludeModules opts)
    omission key reason=liftIO $ modifyIORef' exportRef $ \(ExportState e ds roots omitted depths pool refs)->ExportState e ds roots (M.insert key reason omitted) depths pool refs
    capture depth isRoot location d@Defn{..}=do
      ExportState _ existing roots _ depths _ _<-liftIO $ readIORef exportRef
      let key=nodeKeyOfQ defName
          root=isRoot
          signatureOnly=depth<0
          isSignature (Captured _ _ _ _ _ _ _ _ _ _ p _ _)=p=="equation-signature"
      if excluded d then omission key "excluded-module" else
        if M.member key existing && M.findWithDefault (-2) key depths>=depth then do
          -- Closure capture may have already collected this declaration at
          -- the required depth. Upgrade ownership/location without repeating
          -- contextual inference and interning when its own hook is visited.
          when root $ liftIO $ modifyIORef' exportRef $ \(ExportState e ds rs omitted dsDepths pool refs)->
            let upgrade (Captured n m l oldFile section sig clauses transparency constructor projection _ origin parent)=
                  Captured n m l (case location of Just _->location;_->oldFile) section sig clauses transparency constructor projection "selected-root" origin parent
            in ExportState e (M.adjust upgrade key ds) rs omitted dsDepths pool refs
        else
          if signatureOnly && M.notMember key existing && M.size (M.filter isSignature existing)>=2048 then omission key "equation-signature-limit" else
          if not signatureOnly && not root && M.notMember key existing && S.size (M.keysSet (M.filter (not . isSignature) existing) S.\\ roots)>=auxiliaryLimit then omission key "auxiliary-limit" else do
            signature<-removeCopies defType
            let encodedSignature=limitedTree rootNodeLimit (typeTree signature)
                captureCut (Tree tag name _ _ children)=tag=="unsupported" && name=="capture-node-limit" || any captureCut children
            if captureCut encodedSignature then omission key (if signatureOnly then "equation-signature-node-limit" else "signature-node-limit") else do
              section<-definitionSectionParameters d
              -- Supporting declarations follow the bounded closure. Hidden
              -- implementations (copies/inline/helpers) stay separate from graph
              -- nodes; bounded closure follows their bodies when selected roots
              -- reference them. Provenance does not change dependency extraction.
              let clauses=if signatureOnly then [] else case theDef of
                    Function{..}->funClauses
                    Primitive{..}->primClauses
                    _->[]
              bodies<-forM clauses $ \cl->do
                telescope<-removeCopies (clauseTel cl)
                body<-mapM removeCopies (clauseBody cl)
                result<-mapM (removeCopies . unArg) (clauseType cl)
                patterns<-mapM patternTree (clausePats cl)
                annotations<-case body of
                  Nothing->pure []
                  Just term->localTCState $ inTopContext $ addContext telescope $
                    fmap concat $ forM (take 128 $ filter (\(path,value)->not (null path) && length (take 501 $ treeNodes $ termTree value)<=500) $ neutralOccurrences [] term) $ \(path,value)->
                      -- Optional typing must not discard an otherwise useful
                      -- clause when Agda's internal inference API rejects it.
                      -- Force the bounded tree inside restored state and a
                      -- 100 ms deadline; inference can enter costly conversion.
                      fmap (maybe [] id) $ boundedQueryTCM 100000 $ do
                        allowed<-case value of
                          Def q _->do entry<-getConstInfo q;pure $ case TC.theDef entry of Function{funProjection=Right _}->False;_->True
                          Var{}->pure True
                          _->pure False
                        if not allowed then pure [] else do
                          ty<-Internal.infer value >>= removeCopies
                          let tree=limitedTree 2000 (typeTree ty)
                          pure [(path,tree)]
                let encodedBody=limitedTree rootNodeLimit . termTree <$> body
                    -- A bounded body or unsupported modality can cut away a
                    -- neutral term that was present in Agda's full clause.
                    -- Never publish an annotation outside the emitted tree.
                    present [] _=True
                    present (i:is) (Tree tag _ _ binds children)=i>=0 && i<length children &&
                      not (binds && (tag=="lam" || tag=="pi" && i==1)) && present is (children!!i)
                    retainedAnnotations=[entry | entry@(path,_)<-annotations,maybe False (present path) encodedBody]
                pure $ CapturedClause (map (limitedTree rootNodeLimit) $ contextTrees telescope) patterns
                  encodedBody (limitedTree rootNodeLimit . typeTree <$> result)
                  (recursiveStatus cl) (clauseUnreachable cl) retainedAnnotations
              let constructor=case theDef of Constructor{..}->Just conPars;_->Nothing
                  projection=case theDef of Function{funProjection=Right p}->Just (projIndex p);_->Nothing
                  transparency=if show (defOpaque d)/="TransparentDef" then "opaque" else case show (defAbstract d) of "AbstractDef"->"abstract";_->"transparent"
                  parent=case theDef of Function{..}->nodeKeyOfQ <$> withFunParent funWith;_->Nothing
                  origin=case theDef of
                    Function{..} | isJust parent->"with-function"
                                 | isJust funExtLam->"extended-lambda"
                    _->"declaration"
                  entry=Captured key (moduleKeyOfQ defName) (bindingLineOfQ defName) location section
                    encodedSignature bodies transparency constructor projection
                    (if root then "selected-root" else if signatureOnly then "equation-signature" else if null clauses then "support-signature" else "reachable-implementation") origin parent
              -- Intern before retaining the entry: large libraries share
              -- telescopes/types extensively. Keeping expanded trees until
              -- final serialization makes memory grow with their expansion.
              liftIO $ do
                ExportState e ds rs omitted depths pool references<-readIORef exportRef
                let (packed,nextPool)=ST.runState (internCaptured entry) pool
                    used=capturedReferences entry
                _<-evaluate (M.size $ snd nextPool)
                _<-evaluate (force packed)
                _<-evaluate (S.size used)
                writeIORef exportRef (ExportState e (M.insert key packed ds) rs omitted (M.insert key depth depths) nextPool (M.insert key used references))
              let refs=S.toAscList $ S.fromList $ namesIn signature++concatMap (\cl->namesIn (namedClausePats cl)++maybe [] namesIn (clauseBody cl)) clauses
              -- A signature-only equation can mention a small abstraction
              -- (composition, for example) that is absent from selected bodies.
              -- Capture only bounded variable-clause computation, never the
              -- theorem proof, so its endpoints can be compared without hints.
              when signatureOnly $ forM_ refs $ \q->catchError (do
                ExportState _ current selectedRoots _ _ _ _<-liftIO $ readIORef exportRef
                let supportCount=S.size (M.keysSet (M.filter (not . isSignature) current) S.\\ selectedRoots)
                when (supportCount<64) $ do
                  candidate<-getConstInfo q
                  case TC.theDef candidate of
                    Function{funClauses=[cl]} | all variablePattern (clausePats cl),
                      Just body<-clauseBody cl,length (take 129 $ treeNodes $ termTree body)<=128,
                      not (equalitySignature $ typeTree $ TC.defType candidate)->capture 0 False Nothing candidate
                    _->pure ()) (\_->pure ())
              forM_ (if signatureOnly then [] else refs) $ \q->do
                if depth<=0 then omission (nodeKeyOfQ q) "closure-depth" else do
                  catchError (getConstInfo q >>= capture (depth-1) False Nothing) (\_->omission (nodeKeyOfQ q) "unavailable-definition")
              pure ()

recursiveStatus :: Clause -> Maybe Bool
#if MIN_VERSION_Agda(2,9,0)
recursiveStatus cl=case clauseRecursive cl of
  YesRecursive->Just True
  NotRecursive->Just False
  MaybeRecursive->Nothing
#else
recursiveStatus=clauseRecursive
#endif

patternTree :: Arg DeBruijnPattern -> TCM (PatternTree Tree)
patternTree arg=do
  let info=binderInfo (getArgInfo arg)
      node tag name index term children=PatternTree tag name info index term children
  case unArg arg of
    VarP p v->pure $ node (if patOrigin p==PatOAbsurd then "absurd" else "var") (dbPatVarName v) (Just $ dbPatVarIndex v) Nothing []
    DotP _ t->do term<-removeCopies t;pure $ node "dot" "" Nothing (Just $ limitedTree rootNodeLimit $ termTree term) []
    ConP c _ ps->node "con" (nodeKeyOfQ $ conName c) Nothing Nothing <$> mapM (patternTree . fmap namedThing) ps
    LitP _ l->pure $ node "lit" (case l of LitQName q->"LitQName "++nodeKeyOfQ q;_->show l) Nothing Nothing []
    ProjP _ q->pure $ node "proj" (nodeKeyOfQ q) Nothing Nothing []
    _->pure $ node "unsupported" "cubical-or-defined-pattern" Nothing Nothing []

-- Traverse once at the producer boundary. The retained representation and
-- reference closure contain only DAG indices and canonical declaration keys.
internCaptured :: Captured Tree -> ST.State Intern (Captured Int)
internCaptured (Captured name owner line file section signature clauses transparency constructor projection provenance origin parent)=do
  sig<-intern signature
  cs<-mapM clause clauses
  pure $ Captured name owner line file section sig cs transparency constructor projection provenance origin parent
  where
    pattern' (PatternTree tag name info index term children)=PatternTree tag name info index <$> mapM intern term <*> mapM pattern' children
    clause (CapturedClause context patterns body result recursive unreachable types)=
      CapturedClause <$> mapM intern context <*> mapM pattern' patterns <*> mapM intern body <*> mapM intern result
        <*> pure recursive <*> pure unreachable <*> mapM (\(path,ty)->do r<-intern ty;pure (path,r)) types

capturedReferences :: Captured Tree -> S.Set String
capturedReferences (Captured _ _ _ _ _ signature clauses _ _ _ _ _ _)=S.unions $
  refs signature:[S.unions (map refs ctx++map patternRefs ps++maybe [] (\t->[refs t]) body++maybe [] (\t->[refs t]) result)
    | CapturedClause ctx ps body result _ _ _<-clauses]
  where
    patternRefs (PatternTree tag name _ _ term children)=S.unions ((if tag `elem` ["con","proj"] then S.singleton name else S.empty):maybe [] (\t->[refs t]) term++map patternRefs children)
    refs (Tree tag name _ _ cs)=S.unions ((if tag `elem` ["def","con","proj"] then S.singleton name else S.empty):map refs cs)

encodePattern :: PatternTree Int -> ST.State Intern A.Value
encodePattern (PatternTree tag name info index term children)=do
  root<-pure term
  nested<-mapM encodePattern children
  pure $ A.object ["tag" .= tag,"name" .= name,"info" .= info,"index" .= index,"term" .= root,"children" .= nested]
encodeDefinition :: String -> Captured Int -> ST.State Intern (A.Value,[A.Value],[A.Value])
encodeDefinition environment (Captured name owner line file section signature clauses transparency constructor projection provenance origin parent)=do
  sig<-pure signature
  rows<-forM (zip [0::Int ..] clauses) $ \(index,CapturedClause telescope patterns body result recursive unreachable types)->do
    ctx<-pure telescope
    ps<-mapM encodePattern patterns
    b<-pure body
    ty<-pure result
    subterms<-forM types $ \(path,value)->do
      r<-pure value
      pure $ A.object ["definition" .= name,"clause" .= index,"path" .= path,"context" .= ctx,"type" .= r,"environment" .= environment]
    let annotations=case (b,ty) of
          (Just _,Just r)->[A.object ["definition" .= name,"clause" .= index,"path" .= ([]::[Int]),"context" .= ctx,"type" .= r,"environment" .= environment]]
          _->[]
    pure (A.object ["index" .= index,"context" .= ctx,"patterns" .= ps,"body" .= b,"resultType" .= ty,
      "unfolding" .= False,"recursive" .= recursive,"unreachable" .= unreachable],annotations,subterms)
  pure (A.object ["name" .= name,"module" .= owner,"file" .= file,"line" .= line,"signature" .= sig,
    "sectionParameters" .= section,"clauses" .= [a | (a,_,_)<-rows],"transparency" .= transparency,
    "sourceKind" .= origin,"sourceParent" .= parent,
    "constructorParameters" .= constructor,"projectionIndex" .= projection,"provenance" .= provenance,"environment" .= environment],concat [a | (_,a,_)<-rows],concat [a | (_,_,a)<-rows])

readTermEvidence :: [String] -> [String] -> [String] -> A.Value -> IO (Maybe TL.Text)
readTermEvidence retained inventory scopes environment=do
  ExportState enabled entries roots omitted _ pool referenceIndex<-readIORef exportRef
  if not enabled then pure Nothing else do
    let kept=S.fromList retained
        selected=S.intersection roots kept
        close seen []=seen
        close seen (x:xs) | S.member x seen=close seen xs
                          | otherwise=close (S.insert x seen) (S.toList (M.findWithDefault S.empty x referenceIndex)++xs)
        reachable=close S.empty (S.toAscList selected++M.keys (M.filter equation entries))
        equation (Captured _ _ _ _ _ _ _ _ _ _ p _ _)=p=="equation-signature"
        available=if S.null selected then M.empty else M.union (M.restrictKeys entries reachable) (M.filter equation entries)
        envKey=show $ hashString (show environment)
        (encoded,(_,nodes))=ST.runState (mapM (encodeDefinition envKey) $ M.elems available) pool
        names=M.keys available
        graphNames=S.fromList inventory
        equationNames=M.keysSet (M.filter equation available)
        primary=[value | (name,(value,_,_))<-zip names encoded,S.member name graphNames,S.notMember name equationNames]
        auxiliary=[value | (name,(value,_,_))<-zip names encoded,S.notMember name graphNames,S.notMember name equationNames]
        equations=[value | (name,(value,_,_))<-zip names encoded,S.member name equationNames]
        omissions=M.union (M.restrictKeys omitted (S.difference reachable (M.keysSet available))) (M.fromSet (const "unavailable-reference") (reachable S.\\ M.keysSet available))
        unsupported=S.toAscList $ S.fromList [reason | ("unsupported",reason,_,_,_)<-M.elems nodes]
        coverage=A.object ["selectedRoots" .= S.toAscList selected,"scopes" .= scopes,
          "omittedDefinitions" .= omissions,
          "unavailableSelectedDefinitions" .= S.toAscList (S.filter (\name->null scopes || any (\scope->(scope++".") `isPrefixOf` name) scopes) (graphNames S.\\ M.keysSet entries)),"unavailableBodies" .= [name | (name,Captured _ _ _ _ _ _ cs _ _ _ _ _ _)<-M.toAscList available,null cs],
          "capabilities" .= ["signatures","clauses","patterns","clause-root-types"::String],
          "occurrenceTyping" .= ("clause-roots-and-bounded-neutral-subterms"::String),"subtermTypeLimit" .= (128::Int),"subtermInputNodeLimit" .= (500::Int),"subtermQueryMicros" .= (100000::Int),"subtermTypingComplete" .= False,"equationSignatureLimit" .= (2048::Int),"equationSignatures" .= length equations,"equationSignatureOmissions" .= M.filter ("equation-" `isPrefixOf`) omitted,"unfolding" .= False,
          "unsupportedReasons" .= unsupported,"rootNodeLimit" .= rootNodeLimit,"auxiliaryLimit" .= auxiliaryLimit,"closureDepth" .= closureDepth]
    -- Consume the capture side channel after freezing the slices. The lookup
    -- half of the intern table is no longer needed while streaming JSON.
    writeIORef exportRef (ExportState False M.empty S.empty M.empty M.empty (M.empty,M.empty) M.empty)
    pure $ Just $ TLE.decodeUtf8 $ AE.encodingToLazyByteString $ A.pairs
      ("v" .= (1::Int) <> AE.pair "nodes" (AE.list encodeInternNode (M.elems nodes)) <>
       "definitions" .= primary <> "auxiliaryDefinitions" .= auxiliary <> "equationSignatures" .= equations <>
       "occurrenceTypes" .= concat [a | (_,a,_)<-encoded] <> "subtermTypes" .= concat [a | (_,_,a)<-encoded] <>
       "environment" .= M.singleton envKey environment <> "coverage" .= [coverage])

-- Paths mirror TermCodec's application/projection tree exactly. Stop at
-- binders: subterms here retain the original clause telescope. Only neutral
-- terms are passed to Agda's inference API, whose contract excludes lambdas
-- and constructors. This bounded evidence never authorizes a rewrite.
neutralOccurrences :: [Int] -> Term -> [([Int],Term)]
neutralOccurrences path term=case term of
  Var i es->spineTerms (Var i) es
  Def q es->spineTerms (Def q) es
  Con c o es->children (Con c o) es
  _->[]
  where
    spineTerms make es=(path,make es):children make es
    children _ []=[]
    children make es=case last es of
      Apply arg->neutralOccurrences (path++[0]) (make $ init es)++neutralOccurrences (path++[1]) (unArg arg)
      Proj{}->neutralOccurrences (path++[0]) (make $ init es)
      IApply{}->[]

-- Only classify signatures here; the consumer interprets and instantiates the
-- equality. Bodies outside requested scopes are not captured for this catalogue.
equalitySignature :: Tree -> Bool
equalitySignature (Tree "type" _ _ _ (body:_))=equalitySignature body
equalitySignature (Tree "pi" _ _ _ [_,body])=equalitySignature body
equalitySignature term=case headOf term of Tree "def" name _ _ _->name=="Agda.Builtin.Equality._≡_";_->False
  where headOf (Tree "app" _ _ _ (f:_))=headOf f
        headOf x=x
