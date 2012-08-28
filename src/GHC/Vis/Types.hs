{- |
   Module      : GHC.Vis.Types
   Copyright   : (c) Dennis Felsing
   License     : 3-Clause BSD-style
   Maintainer  : dennis@felsin9.de

 -}
module GHC.Vis.Types (
  Signal(..),
  ViewType(..),
  State(..),
  HeapEntry,
  HeapMap,
  PrintState,
  VisObject(..)
  )
  where

import GHC.HeapView

import Graphics.XDot.Types

import qualified Control.Monad.State as MS

-- | Signals that are sent to the GUI to signal changes
data Signal = NewSignal Box String -- ^ Add a new Box to be visualized
            | UpdateSignal  -- ^ Redraw
            | ClearSignal   -- ^ Remove all Boxes
            | SwitchSignal  -- ^ Switch to alternative view

-- | Visualization views
data ViewType = ListView
              | GraphView
              deriving (Enum, Eq, Bounded)

-- | The global state used for the visualizations.
data State = State
  { mousePos :: Point -- ^ Current position of the mouse, updated with every movement
  , view     :: ViewType -- ^ What kind of visualization is currently running
  }

-- | An entry in a 'HeapMap', consisting of an identifier and a parsed GHC heap entry
type HeapEntry =
  ( Maybe String
  , Closure
  )
-- | A map of heap objects.
--
--   We're using a slow, eq-based list instead of a proper map because
--   StableNames' hash values aren't stable enough
type HeapMap   = [(Box, HeapEntry)]

-- | The second HeapMap includes BCO pointers, needed for list visualization
type PrintState = MS.State (Integer, HeapMap, HeapMap)

-- | Simple representation of objects on the heap, so they can be arranged linearly
data VisObject = Unnamed String
               | Named String [VisObject]
               | Link String
               | Function String
               deriving Eq

instance Show VisObject where
  show (Unnamed x) = x
  show (Named x ys) = x ++ "=(" ++ show ys ++ ")"
  show (Link x) = x
  show (Function x) = x

  showList = foldr ((.) . showString . show) (showString "")
