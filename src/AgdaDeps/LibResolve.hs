-- | Resolve the project's @.agda-lib@ dependency closure using Agda's
-- own parser, registry discovery and version matching. Only a complete
-- success may replace library discovery with explicit include paths.
module AgdaDeps.LibResolve
  ( resolveProjectDepsDirs
  ) where

import Control.Exception ( IOException, displayException, try )
import Control.Monad ( forM_ )
import Data.Containers.ListUtils ( nubOrd )
import System.IO ( hPutStrLn, stderr )

import Agda.Interaction.Library
  ( AgdaLibFile(..), LibM, getAgdaLibFile, getInstalledLibraries
  , libraryIncludePaths )
import Agda.Interaction.Library.Base ( runLibM, formatLibErrors )
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
