{-# LANGUAGE RankNTypes #-}
{- |
   Module      : GHC.Vis.View.List
   Copyright   : (c) Dennis Felsing
   License     : 3-Clause BSD-style
   Maintainer  : dennis@felsin9.de

 -}
module GHC.Vis.View.List (
  export,
  redraw,
  click,
  move,
  updateObjects
  )
  where
import Graphics.UI.Gtk hiding (Box, Signal, Rectangle)
import qualified Graphics.UI.Gtk as Gtk
import Graphics.Rendering.Cairo

import Control.Concurrent
import Control.Monad

import Data.IORef
import System.IO.Unsafe

import GHC.Vis.Internal
import GHC.Vis.Types hiding (State, View(..))
import GHC.Vis.View.Common

import GHC.HeapView (Box)

type Rectangle = (Double, Double, Double, Double)

data State = State
  { objects :: [(Box, String, [VisObject])]
  , bounds  :: [(String, Rectangle)]
  , hover   :: Maybe String
  }

type RGB = (Double, Double, Double)

state :: IORef State
state = unsafePerformIO $ newIORef $ State [] [] Nothing

layout' :: IORef (Maybe PangoLayout)
layout' = unsafePerformIO $ newIORef Nothing

fontName :: String
fontName = "Sans"
--fontName = "Times Roman"
--fontName = "DejaVu Sans"
--fontName = "Lucida Grande"

fontSize :: Double
fontSize = 15

colorName :: RGB
colorName = (0.5,1,0.5)

colorNameHighlighted :: RGB
colorNameHighlighted = (0,1,0)

colorLink :: RGB
colorLink = (0.5,0.5,1)

colorLinkHighlighted :: RGB
colorLinkHighlighted = (0.25,0.25,1)

colorThunk :: RGB
colorThunk = (1,0.5,0.5)

colorThunkHighlighted :: RGB
colorThunkHighlighted = (1,0,0)

colorFunction :: RGB
colorFunction = (1,1,0.5)

colorFunctionHighlighted :: RGB
colorFunctionHighlighted = (1,1,0)

padding :: Double
padding = 5

-- | Draw visualization to screen, called on every update or when it's
--   requested from outside the program.
redraw :: WidgetClass w => w -> IO ()
redraw canvas = do
  s <- readIORef state
  Gtk.Rectangle _ _ rw2 rh2 <- widgetGetAllocation canvas

  boundingBoxes <- render canvas (draw s rw2 rh2)
  modifyIORef state (\s' -> s' {bounds = boundingBoxes})

-- | Export the visualization to an SVG file
export :: DrawFunction -> String -> IO ()
export drawFn file = do
  s <- readIORef state

  drawFn file (fromIntegral xSize) (fromIntegral ySize)
    (\surface -> renderWith surface (draw s xSize ySize))

  return ()

  where xSize = 500 :: Int
        ySize = 500 :: Int

draw :: State -> Int -> Int -> Render [(String, Rectangle)]
draw s rw2 rh2 = do
  let os = objects s
      objs  = map (\(_,_,x) -> x) os
      --boxes = map (\(x,_,_) -> x) os
      names = map ((++ ": ") . (\(_,x,_) -> x)) os

  layout <- pangoEmptyLayout
  liftIO $ writeIORef layout' $ Just layout

  nameWidths <- mapM (width . Unnamed) names
  pos <- mapM height objs
  widths <- mapM (mapM width) objs

  let rw = fromIntegral rw2
      rh = fromIntegral rh2

      maxNameWidth = maximum nameWidths
      widths2 = 1 : map (\ws -> maxNameWidth + sum ws) widths

      sw = maximum widths2
      sh = sum (map (+ 30) pos) - 15

      sx = min (rw / sw) (rh / sh)
      sy = sx
      ox = 0
      oy = 0

  scale sx sy

  let rpos = scanl (\a b -> a + b + 30) 30 pos
  result <- mapM (drawEntry s maxNameWidth) (zip3 objs rpos names)

  return $ map (\(o, (x,y,w,h)) -> (o, (x*sx+ox,y*sy+oy,w*sx,h*sy))) $ concat result

render :: WidgetClass w => w -> Render b -> IO b
render canvas r = do
  win <- widgetGetDrawWindow canvas
  renderWithDrawable win r

-- | Handle a mouse click. If an object was clicked an 'UpdateSignal' is sent
--   that causes the object to be evaluated and the screen to be updated.
click :: IO ()
click = do
  s <- readIORef state

  case hover s of
     Just t -> do
       evaluate t
       -- Without forkIO it would hang indefinitely if some action is currently
       -- executed
       void $ forkIO $ putMVar visSignal UpdateSignal
     _ -> return ()

-- | Handle a mouse move. Causes an 'UpdateSignal' if the mouse is hovering a
--   different object now, so the object gets highlighted and the screen
--   updated.
move :: WidgetClass w => w -> IO ()
move canvas = do
  vS <- readIORef visState
  oldS <- readIORef state
  let oldHover = hover oldS

  modifyIORef state $ \s' -> (
    let (mx, my) = mousePos vS
        check (o, (x,y,w,h)) =
          if x <= mx && mx <= x + w &&
             y <= my && my <= y + h
          then Just o else Nothing
    in s' {hover = msum $ map check (bounds s')}
    )
  s <- readIORef state
  unless (oldHover == hover s) $ widgetQueueDraw canvas

-- | Something might have changed on the heap, update the view.
updateObjects :: [(Box, String)] -> IO ()
updateObjects boxes = do
  os <- parseBoxes boxes
  let objs = zipWith (\(x,y) z -> (x,y,z)) boxes os
  modifyIORef state (\s -> s {objects = objs, hover = Nothing})

drawEntry :: State -> Double -> ([VisObject], Double, String) -> Render [(String, Rectangle)]
drawEntry s nameWidth (obj, pos, name) = do
  save
  translate 0 pos
  moveTo 0 0
  drawBox s $ Unnamed name
  translate nameWidth 0
  moveTo 0 0
  boundingBoxes <- mapM (drawBox s) obj
  restore
  return $ map (\(o, (x,y,w,h)) -> (o, (x+nameWidth,y+pos,w,h))) $ concat boundingBoxes

drawBox :: State -> VisObject -> Render [(String, Rectangle)]
drawBox _ o@(Unnamed content) = do
  (x,_) <- getCurrentPoint
  wc <- width o

  (layout, metrics) <- pangoLayout content
  let fa = ascent metrics

  moveTo (x + padding/2) (-fa)
  setSourceRGB 0 0 0
  showLayout layout
  moveTo (x + wc) 0

  return []

drawBox s o@(Thunk target) =
  drawFunctionLink s o target colorThunk colorThunkHighlighted

drawBox s o@(Function target) =
  drawFunctionLink s o target colorFunction colorFunctionHighlighted

drawBox s o@(Link target) =
  drawFunctionLink s o target colorLink colorLinkHighlighted

drawBox s o@(Named name content) = do
  (x,_) <- getCurrentPoint

  hc <- height content
  wc <- width o

  (layout, metrics) <- pangoLayout name
  (_, PangoRectangle _ _ xa fh) <- liftIO $ layoutGetExtents layout
  let fa = ascent metrics

  let (ux, uy, uw, uh) =
        ( x
        , -fa - padding
        , wc
        , fh + 10 + hc
        )

  setLineCap LineCapRound
  roundedRect ux uy uw uh

  setColor s name colorName colorNameHighlighted

  fillAndSurround

  moveTo ux (hc + 5 - fa - padding)
  lineTo (ux + uw) (hc + 5 - fa - padding)
  stroke

  save
  moveTo (x + padding) 0
  bb <- mapM (drawBox s) content
  restore

  moveTo (x + uw/2 - xa/2) (hc + 7.5 - padding - fa)
  showLayout layout
  moveTo (x + wc) 0

  return $ concat bb ++ [(name, (ux, uy, uw, uh))]

pangoLayout :: String -> Render (PangoLayout, FontMetrics)
pangoLayout text = do
  --layout <- createLayout text
  Just layout'' <- liftIO $ readIORef layout'
  layout <- liftIO $ layoutCopy layout''
  liftIO $ layoutSetText layout text
  context <- liftIO $ layoutGetContext layout

  --fo <- liftIO $ cairoContextGetFontOptions context

  --fontOptionsSetAntialias fo AntialiasDefault
  --fontOptionsSetHintStyle fo HintStyleNone
  --fontOptionsSetHintMetrics fo HintMetricsOff
  --liftIO $ cairoContextSetFontOptions context fo

  --liftIO $ layoutContextChanged layout

  -- This does not work with "Times Roman", but it works with a font that is
  -- installed on the system
  --font <- liftIO fontDescriptionNew
  --liftIO $ fontDescriptionSetFamily font "Nimbus Roman No9 L, Regular"
  --liftIO $ fontDescriptionSetFamily font "Times Roman"
  --liftIO $ fontDescriptionSetSize font fontSize'

  -- Only fontDescriptionFromString works as expected, choosing a similar
  -- alternative font when the selected one is not available
  font <- liftIO $ fontDescriptionFromString fontName
  liftIO $ fontDescriptionSetSize font fontSize
  --liftIO $ layoutSetFontDescription layout (Just font)

  language <- liftIO $ contextGetLanguage context
  metrics <- liftIO $ contextGetMetrics context font language

  return (layout, metrics)

pangoEmptyLayout = do
  layout <- createLayout ""
  context <- liftIO $ layoutGetContext layout

  font <- liftIO $ fontDescriptionFromString fontName
  liftIO $ fontDescriptionSetSize font fontSize
  liftIO $ layoutSetFontDescription layout (Just font)

  language <- liftIO $ contextGetLanguage context
  metrics <- liftIO $ contextGetMetrics context font language

  return layout

  --font <- fontDescriptionFromString fontName
  --cairoCreateContext Nothing

drawFunctionLink :: State -> VisObject -> String -> RGB -> RGB -> Render [(String, Rectangle)]
drawFunctionLink s o target color1 color2 = do
  (x,_) <- getCurrentPoint
  (layout, metrics) <- pangoLayout target
  (_, PangoRectangle _ _ _ fh) <- liftIO $ layoutGetExtents layout
  let fa = ascent metrics

  wc <- width o

  let (ux, uy, uw, uh) =
        (  x
        ,  (-fa) -  padding
        ,  wc
        ,  fh   +  10
        )

  setLineCap LineCapRound
  roundedRect ux uy uw uh

  setColor s target color1 color2

  fillAndSurround

  moveTo (x + padding) (-fa)
  showLayout layout
  moveTo (x + wc) 0

  return [(target, (ux, uy, uw, uh))]

setColor :: State -> String -> RGB -> RGB -> Render ()
setColor s name (r,g,b) (r',g',b') = case hover s of
  Just t -> if t == name then setSourceRGB r' g' b'
                         else setSourceRGB r  g  b
  _ -> setSourceRGB r g b

fillAndSurround :: Render ()
fillAndSurround = do
  fillPreserve
  setSourceRGB 0 0 0
  stroke

roundedRect :: Double -> Double -> Double -> Double -> Render ()
roundedRect x y w h = do
  moveTo       x            (y + pad)
  lineTo       x            (y + h - pad)
  arcNegative (x + pad)     (y + h - pad) pad pi      (pi/2)
  lineTo      (x + w - pad) (y + h)
  arcNegative (x + w - pad) (y + h - pad) pad (pi/2)  0
  lineTo      (x + w)       (y + pad)
  arcNegative (x + w - pad) (y + pad)     pad 0       (-pi/2)
  lineTo      (x + pad)      y
  arcNegative (x + pad)     (y + pad)     pad (-pi/2) (-pi)
  closePath

  --where pad = 1/10 * min w h
  where pad = 5

height :: [VisObject] -> Render Double
height xs = do
  (layout, _) <- pangoLayout ""
  (_, PangoRectangle _ _ _ ya) <- liftIO $ layoutGetExtents layout
  let go (Named _ ys) = (ya + 15) + maximum (map go ys)
      go (Unnamed _)  = ya
      go (Link _)     = ya + 2 * padding
      go (Thunk _) = ya + 2 * padding
      go (Function _) = ya + 2 * padding
  return $ maximum $ map go xs

width :: VisObject -> Render Double
width (Named x ys) = do
  nameWidth <- simpleWidth x $ 2 * padding
  w2s <- mapM width ys
  return $ max nameWidth $ sum w2s + 2 * padding

width (Unnamed x) = simpleWidth x padding

width (Link x) = simpleWidth x $ 2 * padding

width (Thunk x) = simpleWidth x $ 2 * padding

width (Function x) = simpleWidth x $ 2 * padding

simpleWidth :: String -> Double -> Render Double
simpleWidth x pad = do
  (layout, _) <- pangoLayout x
  (_, PangoRectangle _ _ xa _) <- liftIO $ layoutGetExtents layout
  return $ xa + pad
