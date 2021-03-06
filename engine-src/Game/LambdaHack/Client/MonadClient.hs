-- | Basic client monad and related operations.
module Game.LambdaHack.Client.MonadClient
  ( -- * Basic client monads
    MonadClientRead ( getsClient
                    , liftIO  -- exposed only to be implemented, not used
                    )
  , MonadClient(modifyClient)
    -- * Assorted primitives
  , getClient, putClient
  , debugPossiblyPrint, createTabBFS, rndToAction
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Control.Monad.ST.Strict (stToIO)
import qualified Control.Monad.Trans.State.Strict as St
import qualified Data.Primitive.PrimArray as PA
import qualified Data.Text.IO as T
import           System.IO (hFlush, stdout)

import Game.LambdaHack.Client.ClientOptions
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Kind
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Core.Random

-- | Monad for reading client state.
class MonadStateRead m => MonadClientRead m where
  getsClient :: (StateClient -> a) -> m a
  -- We do not provide a MonadIO instance, so that outside
  -- nobody can subvert the action monads by invoking arbitrary IO.
  liftIO :: IO a -> m a

-- | Monad for writing to client state.
class MonadClientRead m => MonadClient m where
  modifyClient :: (StateClient -> StateClient) -> m ()

getClient :: MonadClientRead m => m StateClient
getClient = getsClient id

putClient :: MonadClient m => StateClient -> m ()
putClient s = modifyClient (const s)

debugPossiblyPrint :: MonadClient m => Text -> m ()
debugPossiblyPrint t = do
  sdbgMsgCli <- getsClient $ sdbgMsgCli . soptions
  when sdbgMsgCli $ liftIO $ do
    T.hPutStrLn stdout t
    hFlush stdout

createTabBFS :: MonadClient m => m (PA.PrimArray PointI)
createTabBFS = do
  COps{corule=RuleContent{rXmax, rYmax}} <- getsState scops
  liftIO $ stToIO $ do
    tabAMutable <- PA.newPrimArray (rXmax * rYmax)  -- always enough
    PA.unsafeFreezePrimArray tabAMutable

-- | Invoke pseudo-random computation with the generator kept in the state.
rndToAction :: MonadClient m => Rnd a -> m a
rndToAction r = do
  gen1 <- getsClient srandom
  let (a, gen2) = St.runState r gen1
  modifyClient $ \cli -> cli {srandom = gen2}
  return a
