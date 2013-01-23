-- | The main code file of LambdaHack. Here the knot of engine
-- code pieces and the LambdaHack-specific content defintions is tied,
-- resulting in an executable game.
module Main ( main ) where

import qualified Content.ActorKind
import qualified Content.CaveKind
import qualified Content.FactionKind
import qualified Content.ItemKind
import qualified Content.PlaceKind
import qualified Content.RuleKind
import qualified Content.StrategyKind
import qualified Content.TileKind
import Game.LambdaHack.Client
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Server
import Game.LambdaHack.Start

-- | Fire up the frontend with the engine fueled by content.
-- The action monad types to be used are determined by the 'executorSer'
-- and 'executorCli' calls. If other functions are used in their place
-- the types are different and so the whole pattern of computation
-- is different. Which of the frontends is run depends on the flags supplied
-- when compiling the engine library.
main :: IO ()
main = do
  let copsSlow = Kind.COps
        { coactor = Kind.createOps Content.ActorKind.cdefs
        , cocave  = Kind.createOps Content.CaveKind.cdefs
        , cofact  = Kind.createOps Content.FactionKind.cdefs
        , coitem  = Kind.createOps Content.ItemKind.cdefs
        , coplace = Kind.createOps Content.PlaceKind.cdefs
        , corule  = Kind.createOps Content.RuleKind.cdefs
        , costrat = Kind.createOps Content.StrategyKind.cdefs
        , cotile  = Kind.createOps Content.TileKind.cdefs
        }
      cops = speedupCOps copsSlow
      loopServer = loopSer cmdSer
      exeServer = executorSer loopServer
      loopHuman :: (MonadClientUI m, MonadClientChan m) => m ()
      loopHuman = loopCli4 cmdUpdateCli cmdQueryCli cmdUpdateUI cmdQueryUI
      loopComputer :: MonadClientChan m => m ()
      loopComputer = loopCli2 cmdUpdateCli cmdQueryCli
      exeClient True sess = executorCli loopHuman sess
      -- This is correct, because the implicit contract ensures
      -- @MonadClientChan@ never tries to access the client UI session
      -- (unlike @MonadClientUI@).
      exeClient False _ = executorCli loopComputer undefined
      loopFrontend = connServer cops exeServer
  exeFrontend cops exeClient launchClients loopFrontend
  waitForChildren
