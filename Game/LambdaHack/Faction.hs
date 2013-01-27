{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Factions taking part in the game: e.g., two human players controlling
-- the hero faction battling the monster and the animal factions.
module Game.LambdaHack.Faction
  ( FactionId, FactionDict, Faction(..), Status(..)
  , isHumanFact, isSpawningFact, invalidFactionId
  ) where

import Data.Binary
import qualified Data.EnumMap.Strict as EM
import Data.Text (Text)
import Data.Maybe

import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Content.StrategyKind
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.FactionId

-- | All factions in the game, indexed by faction identifier.
type FactionDict = EM.EnumMap FactionId Faction

data Faction = Faction
  { gkind     :: !(Kind.Id FactionKind)   -- ^ the kind of the faction
  , gname     :: !Text                    -- ^ individual name
  , gAiLeader :: !(Maybe (Kind.Id StrategyKind))
                                          -- ^ AI for the leaders;
                                          -- Nothing means human-controlled
  , gAiMember :: !(Kind.Id StrategyKind)  -- ^ AI to use for other actors
  , genemy    :: ![FactionId]  -- ^ currently in war with these factions
  , gally     :: ![FactionId]  -- ^ currently allied with these factions
  , gquit     :: !(Maybe (Bool, Status))  -- ^ cause of game end/exit
  }
  deriving Show

-- | Current result of the game.
data Status =
    Killed !LevelId  -- ^ the player lost the game on the given level
  | Camping          -- ^ game is supended
  | Victor           -- ^ the player won
  | Restart          -- ^ the player quits and starts a new game
  deriving (Show, Eq, Ord)

-- | Tell whether the faction is human player-controlled.
isHumanFact :: Faction -> Bool
isHumanFact fact = isNothing $ gAiLeader fact

-- | Tell whether the faction can spawn actors.
isSpawningFact :: Kind.COps -> Faction -> Bool
isSpawningFact Kind.COps{cofact=Kind.Ops{okind}} fact =
  fspawn (okind $ gkind $ fact) > 0

instance Binary Status where
  put (Killed ln) = putWord8 0 >> put ln
  put Camping     = putWord8 1
  put Victor      = putWord8 2
  put Restart     = putWord8 3
  get = do
    tag <- getWord8
    case tag of
      0 -> fmap Killed get
      1 -> return Camping
      2 -> return Victor
      3 -> return Restart
      _ -> fail "no parse (Status)"

instance Binary Faction where
  put Faction{..} = do
    put gkind
    put gname
    put gAiLeader
    put gAiMember
    put genemy
    put gally
    put gquit
  get = do
    gkind <- get
    gname <- get
    gAiLeader <- get
    gAiMember <- get
    genemy <- get
    gally <- get
    gquit <- get
    return Faction{..}
