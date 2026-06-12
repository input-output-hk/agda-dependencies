{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
-- | Graphviz DOT renderer.
module AgdaDeps.Backend.Dot
  ( renderDot
  ) where

import Data.Map ( Map )
import qualified Data.Map as M
import Data.Set ( Set )
import qualified Data.Set as S
import qualified Data.Text.Lazy as TL

import Agda.Utils.Hash ( hashString )
import Data.Graph.Inductive.Graph ( LNode, mkGraph )
import Data.Graph.Inductive.PatriciaTree ( Gr )

import Data.GraphViz
import Data.GraphViz.Attributes.Colors ( Color(RGB), toWC )
import Data.GraphViz.Attributes.Complete
  ( Attribute(FillColor, Style), StyleItem(SItem), StyleName(Filled) )

import Agda.Syntax.Abstract.Name ( ModuleName, QName )
import Agda.Syntax.Internal ( qnameName, qnameModule )
import Agda.Syntax.Common.Pretty ( prettyShow )

import Data.Graph.Inductive.Graph ( Node, UEdge )

import AgdaDeps.Deps    ( ADDef(..), hashQName )
import AgdaDeps.Options ( ColorPalette, DefState(..), colorFor )
import AgdaDeps.Util    ( parseHexColor )

-- | Render the dependency graph as a DOT 'TL.Text', ready to write to
-- disk or stream to stdout. The 'Map' carries each node's classification
-- for colour lookup; dependency-only nodes (no 'ADDef' of their own)
-- default to 'Defined'. Failed module names get a synthetic singleton
-- node coloured by 'colorFailed'.
renderDot :: ColorPalette -> Map QName DefState -> Set String -> [ADDef] -> TL.Text
renderDot palette stateMap failed defs =
  printDotGraph $ buildDotGraph palette stateMap failed defs

-- | DOT node label used for failed-module markers. Stored as the label
-- so the cluster id and renderer share a single string.
data DotLabel = DotQ QName | DotFailedModule String

dotLabelText :: DotLabel -> String
dotLabelText (DotQ qn)             = prettyShow (qnameName qn)
dotLabelText (DotFailedModule mod_) = mod_

dotLabelModule :: DotLabel -> Maybe ModuleName
dotLabelModule (DotQ qn)             = Just (qnameModule qn)
dotLabelModule (DotFailedModule _)   = Nothing

-- | Stable, namespaced node IDs for failed-module synthetic nodes so
-- they can't collide with 'hashQName' outputs.
failedModuleId :: String -> Node
failedModuleId m = fromIntegral (hashString ("failed-module:" ++ m))

buildDotGraph :: ColorPalette -> Map QName DefState -> Set String -> [ADDef] -> DotGraph Node
buildDotGraph palette stateMap failed defs =
  let
    mkNode' :: QName -> LNode DotLabel
    mkNode' qn = (hashQName qn, DotQ qn)

    mkNodes' :: ADDef -> [LNode DotLabel]
    mkNodes' ADDef{..} = mkNode' _name : map mkNode' (S.toList _deps)

    failedNodes :: [LNode DotLabel]
    failedNodes =
      [ (failedModuleId m, DotFailedModule m) | m <- S.toAscList failed ]

    lnodeList :: [LNode DotLabel]
    lnodeList = concatMap mkNodes' defs ++ failedNodes

    mkEdges' :: ADDef -> [UEdge]
    mkEdges' ADDef{..} =
      map (\dep -> (hashQName _name, hashQName dep, ())) (S.toList _deps)

    ledgeList :: [UEdge]
    ledgeList = concatMap mkEdges' defs

    failedAttrs :: [Attribute]
    failedAttrs =
      let (r, g, b) = parseHexColor (colorFor palette Failed)
      in  [ FillColor [toWC (RGB r g b)], Style [SItem Filled []] ]

    -- DOT fill-colour attributes for a node, based on its 'DefState'.
    stateAttrs :: DotLabel -> [Attribute]
    stateAttrs (DotFailedModule _) = failedAttrs
    stateAttrs (DotQ qn) =
      let st       = M.findWithDefault Defined qn stateMap
          (r,g,b)  = parseHexColor (colorFor palette st)
      in [ FillColor [toWC (RGB r g b)]
         , Style [SItem Filled []]
         ]

    graphVizParams :: GraphvizParams Node DotLabel () ModuleName DotLabel
    graphVizParams = defaultParams
      { fmtNode = \(_, l) -> toLabel (dotLabelText l) : stateAttrs l
      , clusterBy = \(n, l) -> case dotLabelModule l of
          Just m  -> C m (N (n, l))
          Nothing -> N (n, l)
      , clusterID = Str . TL.pack . prettyShow
      , fmtCluster = \mn -> [ GraphAttrs [toLabel $ prettyShow mn] ]
      }

    depGraph :: Gr DotLabel ()
    depGraph = mkGraph lnodeList ledgeList

  in graphToDot graphVizParams depGraph
