-- | Resolve the project's @.agda-lib@ dependency closure using Agda's
-- own parser, registry discovery and version matching. Only a complete
-- success may replace library discovery with explicit include paths.
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module AgdaDeps.LibResolve
  ( resolveProjectDepsDirs, sourceOwnership
  ) where

import Control.Exception ( IOException, displayException, try )
import Control.Monad ( forM_ )
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.Map.Strict as M
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath,getCurrentDirectory)
import System.FilePath
import Data.Containers.ListUtils ( nubOrd )
import System.IO ( hPutStrLn, stderr )

import Agda.Interaction.Library
  ( AgdaLibFile(..), LibM, getAgdaLibFile, getInstalledLibraries
  , libraryIncludePaths )
import Agda.Interaction.Library.Base ( runLibM, formatLibErrors, OptionsPragma(..) )
import Agda.Utils.Null ( empty )
import Agda.Syntax.Common.Pretty ( prettyShow, render )

-- | @Nothing@ selects Agda's default registry; @Just path@ honours the
-- CLI's @--library-file@ override. An empty result leaves argv unchanged,
-- including on any project/registry parse error, missing dependency, or
-- ambiguous match. Agda then handles its normal library-resolution errors.
resolveProjectDepsDirs
  :: (String -> IO ())  -- ^ info writer (e.g. 'AgdaDeps.Logging.info')
  -> Maybe FilePath     -- ^ optional --library-file override
  -> FilePath           -- ^ project root
  -> IO [FilePath]
resolveProjectDepsDirs say registryFile root = do
  -- Use a fresh, local library cache. Startup must not populate Agda's TCM
  -- state, and failures must not leak successfully resolved siblings.
  attempted <- try $ do
    ((result, warnings), _) <- runLibM resolve empty
    forM_ warnings $ say . ("agda-deps: --resolve-deps: " ++) . prettyShow
    pure result
  case attempted of
    Left exc -> fallback (displayException (exc :: IOException))
    Right (Left errors) -> fallback (render (formatLibErrors errors))
    Right (Right NoProject) -> do
      warn $ "no .agda-lib found from " ++ root ++ "; leaving argv unchanged."
      pure []
    Right (Right NoDependencies) -> do
      say "--resolve-deps: no transitive depends; leaving argv unchanged."
      pure []
    Right (Right (Resolved libPath [])) -> do
      say $ "--resolve-deps: no include paths in " ++ libPath ++ "; leaving argv unchanged."
      pure []
    Right (Right (Resolved libPath dirs)) -> do
      say $ "--resolve-deps: pinned " ++ show (length dirs)
         ++ " include dir(s) from " ++ libPath
      pure dirs
  where
    warn = hPutStrLn stderr . ("agda-deps: --resolve-deps: " ++)
    fallback reason = do
      warn $ "resolution failed:\n" ++ reason ++ "\nleaving argv unchanged."
      pure []

    resolve :: LibM Resolution
    resolve = do
      projects <- getAgdaLibFile root
      case projects of
        [] -> pure NoProject
        project : _ -> do
          let dependencies = concatMap _libDepends projects
          if null dependencies then pure NoDependencies else do
            installed <- getInstalledLibraries registryFile
            dirs <- libraryIncludePaths registryFile installed dependencies
            -- --no-libraries disables the project's implicit include paths
            -- as well as its dependency lookup, so retain both in the pin.
            pure $ Resolved (_libFile project)
              (nubOrd (concatMap _libIncludes projects ++ dirs))

data Resolution
  = NoProject
  | NoDependencies
  | Resolved FilePath [FilePath]

-- | Capture ownership next to term evidence so consumers need only the graph.
-- Use Agda's project parser and dependency resolver, including vendored/nested
-- registered libraries. Physical dependency paths override a containing project
-- root. Failed resolution is explicit; it never grants ownership to unknown files.
sourceOwnership :: Maybe FilePath -> Maybe FilePath -> [(String,FilePath)] -> IO A.Value
sourceOwnership registryFile entry files=do
  cwd<-canonicalizePath =<< getCurrentDirectory
  let start=maybe cwd takeDirectory entry
  attempted<-try $ do
    ((result,_),_)<-runLibM (do
      projects<-getAgdaLibFile start
      dependencies<-if null (concatMap _libDepends projects) then pure [] else do
        installed<-getInstalledLibraries registryFile
        libraryIncludePaths registryFile installed (concatMap _libDepends projects)
      pure (projects,dependencies)) empty
    pure result
  let projectFlags=case attempted of Right (Right (projects,_))->concatMap (pragmaStrings . _libPragmas) projects;_->[]
      (projectRoot,declared,dependencies,basis,warnings)=case attempted of
        Right (Right (first:rest,deps))->(takeDirectory $ _libFile first,concatMap _libIncludes (first:rest),deps,"agda-lib",[])
        Right (Right ([],_))->(cwd,[cwd],[],"invocation-root",[])
        Right (Left _)->(cwd,[cwd],[],"invocation-root",["Agda library ownership resolution failed"])
        Left (_::IOException)->(cwd,[cwd],[],"invocation-root",["Agda library ownership resolution unavailable"])
  root<-canonicalizePath projectRoot
  declared'<-mapM canonicalizePath declared
  dependencies'<-mapM canonicalizePath dependencies
  canonical<-mapM (\(name,file)->do path<-canonicalizePath file;pure (name,path)) files
  let outside=filter (not . within root) declared'
      imported=nubOrd (dependencies'++outside)
      owned=filter (\path->within root path && not (any (`within` path) imported)) declared'
      role file | any (`within` file) imported="library"
                | any (`within` file) owned="project"
                | otherwise="library"
      physicalRoot name file=case [iterate takeDirectory file!!k |
          let parts=splitOnDot name,k<-[length parts,length parts-1..1],ext<-[".agda",".lagda",".lagda.md",".lagda.rst",".lagda.tex",".lagda.org",".lagda.typ"],
          let suffix=joinPath (take k parts)++ext,reverse suffix `isPrefixOf` reverse file] of
        path:_->path
        []->takeDirectory file
      libraryRoots=nubOrd $ imported++[physicalRoot name file | (name,file)<-canonical,role file=="library"]
  pure $ A.object ["v" .= (1::Int),"basis" .= (basis::String),"projectRoot" .= root,
    "projectRoots" .= owned,"libraryRoots" .= libraryRoots,"projectFlags" .= projectFlags,
    "moduleRoles" .= M.fromList [(name,role file::String) | (name,file)<-canonical],"warnings" .= (warnings::[String])]
  where
    within root file=let relative=makeRelative (normalise root) (normalise file)
      in not (isAbsolute relative) && ".." `notElem` splitDirectories relative
    splitOnDot []=[]
    splitOnDot value=let (part,rest)=break (=='.') value in part:case rest of []->[];_:xs->splitOnDot xs
