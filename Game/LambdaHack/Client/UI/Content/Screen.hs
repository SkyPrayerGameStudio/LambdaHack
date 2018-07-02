-- | The type of definitions of screen layout and features.
module Game.LambdaHack.Client.UI.Content.Screen
  ( ScreenContentData(..), makeData
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , validateSingle
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.Text as T

-- | Screen layout and features definition.
data ScreenContentData = ScreenContentData
  { rwidth       :: Int
  , rheight      :: Int
  , rmainMenuArt :: Text      -- ^ the ASCII art for the main menu
  , rintroScreen :: [String]  -- ^ the intro screen (first help screen) text
  }

-- | Catch invalid rule kind definitions.
validateSingle :: ScreenContentData -> [Text]
validateSingle ScreenContentData{rmainMenuArt} =
  let ts = T.lines rmainMenuArt
      tsNot80 = filter ((/= 80) . T.length) ts
  in case tsNot80 of
     [] -> [ "rmainMenuArt doesn't have 45 lines, but " <> tshow (length ts)
           | length ts /= 45]
     tNot80 : _ ->
       ["rmainMenuArt has a line with length other than 80:" <> tNot80]

makeData :: ScreenContentData -> ScreenContentData
makeData sc =
  let singleOffenders = validateSingle sc
  in assert (null singleOffenders
             `blame` "Screen Content" ++ ": some content items not valid"
             `swith` singleOffenders) $
     sc