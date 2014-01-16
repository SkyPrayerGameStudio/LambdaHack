-- | Semantics of 'HumanCmd' client commands that do not return
-- server commands. None of such commands takes game time.
-- TODO: document
module Game.LambdaHack.Client.HumanLocal
  ( -- * Semantics of serverl-less human commands
    moveCursor, retargetLeader
  , pickLeaderHuman, memberCycleHuman, memberBackHuman, inventoryHuman
  , tgtFloorHuman, tgtEnemyHuman, tgtUnknownHuman, tgtAscendHuman
  , epsIncrHuman, selectActorHuman, selectNoneHuman
  , cancelHuman, displayMainMenu, acceptHuman, clearHuman
   ,repeatHuman, recordHuman
  , historyHuman, humanMarkVision, humanMarkSmell, humanMarkSuspect
  , helpHuman
    -- * Helper functions useful also elsewhere
  , targetAccept, floorItemOverlay, itemOverlay
  , viewedLevel, pickLeader, lookAt
  ) where

-- Cabal
import qualified Paths_LambdaHack as Self (version)

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Function
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Monoid hiding ((<>))
import Data.Ord
import Data.Text (Text)
import qualified Data.Text as T
import Data.Version
import Game.LambdaHack.Frontend (frontendName)
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.Action
import Game.LambdaHack.Client.Binding
import qualified Game.LambdaHack.Client.HumanCmd as HumanCmd
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Animation
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Key as K
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.TileKind

failWith :: MonadClientUI m => Msg -> m Slideshow
failWith msg = do
  modifyClient $ \cli -> cli {slastKey = Nothing}
  stopPlayBack
  assert (not $ T.null msg) $ promptToSlideshow msg

-- * Move and Run

moveCursor :: MonadClientUI m => Vector -> Int -> m Slideshow
moveCursor dir n = do
  leader <- getLeaderUI
  lpos <- getsState $ bpos . getActorBody leader
  scursor <- getsClient scursor
  Level{lxsize, lysize} <- cursorLevel
  let cpos = fromMaybe lpos scursor
      shiftB pos = shiftBounded lxsize lysize pos dir
      newPos = iterate shiftB cpos !! n
  if newPos == cpos then failWith "never mind"
  else do
    modifyClient $ \cli -> cli {scursor = Just newPos}
    doLook

cursorLevel :: MonadClient m => m Level
cursorLevel = do
  dungeon <- getsState sdungeon
  stgtMode <- getsClient stgtMode
  cli <- getClient
  let tgtId = maybe (assert `failure` "not targetting right now"
                            `twith` cli) tgtLevelId stgtMode
  return $! dungeon EM.! tgtId

viewedLevel :: MonadClientUI m => m (LevelId, Level)
viewedLevel = do
  arena <- getArenaUI
  dungeon <- getsState sdungeon
  stgtMode <- getsClient stgtMode
  let tgtId = maybe arena tgtLevelId stgtMode
  return (tgtId, dungeon EM.! tgtId)

-- TODO: probably move somewhere (Level?)
-- | Produces a textual description of the terrain and items at an already
-- explored position. Mute for unknown positions.
-- The detailed variant is for use in the targeting mode.
lookAt :: MonadClientUI m
       => Bool       -- ^ detailed?
       -> Bool       -- ^ can be seen right now?
       -> Point      -- ^ position to describe
       -> ActorId    -- ^ the actor that looks
       -> Text       -- ^ an extra sentence to print
       -> m Text
lookAt detailed canSee pos aid msg = do
  Kind.COps{coitem, cotile=cotile@Kind.Ops{okind}} <- getsState scops
  (_, lvl) <- viewedLevel
  subject <- partAidLeader aid
  s <- getState
  let is = lvl `atI` pos
      verb = MU.Text $ if canSee then "see" else "remember"
  disco <- getsClient sdisco
  let nWs (iid, k) = partItemWs coitem disco k (getItemBody iid s)
      isd = case detailed of
              _ | EM.size is == 0 -> ""
              _ | EM.size is <= 2 ->
                makeSentence [ MU.SubjectVerbSg subject verb
                             , MU.WWandW $ map nWs $ EM.assocs is]
              True -> "Objects:"
              _ -> "Objects here."
      tile = lvl `at` pos
      obscured | tile /= hideTile cotile lvl pos = "partially obscured"
               | otherwise = ""
      tileDesc = [obscured, MU.Text $ tname $ okind tile]
  if not (null (Tile.causeEffects cotile tile)) then
    return $! makeSentence ("activable:" : tileDesc)
              <+> msg <+> isd
  else if detailed then
    return $! makeSentence tileDesc
              <+> msg <+> isd
  else return $! msg <+> isd

-- | Perform look around in the current position of the cursor.
-- Assumes targeting mode and so assumes that a leader is picked.
doLook :: MonadClientUI m => m Slideshow
doLook = do
  scursor <- getsClient scursor
  (lid, lvl) <- viewedLevel
  per <- getPerFid lid
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  target <- getsClient $ getTarget leader
  tgtPos <- targetToPos
  let p = fromMaybe (bpos b) scursor
      canSee = ES.member p (totalVisible per)
  inhabitants <- if canSee
                 then getsState $ posToActors p lid
                 else return []
  let enemyMsg = case inhabitants of
        [] -> ""
        _ -> -- Even if it's the leader, give his proper name, not 'you'.
             let subjects = map (partActor . snd . fst) inhabitants
                 subject = MU.WWandW subjects
                 verb = "be here"
             in makeSentence [MU.SubjectVerbSg subject verb]
      vis | not canSee = "(not visible)"
          | actorSeesPos per leader p = ""
          | otherwise = "(not seen)"
      -- TODO: move elsewhere and recalcuate only when neeed or even less often
  distance <- case tgtPos of
    _ | lid /= blid b -> return Nothing
    Nothing -> return Nothing
    Just tgtP -> accessCacheBfs leader tgtP
  let delta = maybe "" (\d -> ", delta" <+> showT d) distance
      mode = case target of
               Just TEnemy{} -> "[targeting foe" <+> vis <> delta <> "]"
               Just TPoint{} -> "[targeting spot" <+> vis <> delta <> "]"
               Just TVector{} -> "[targeting position" <+> vis <> delta <> "]"
               Nothing -> "[targeting cursor" <+> vis <> delta <> "]"
      -- Check if there's something lying around at current position.
      is = lvl `atI` p
  -- Show general info about current position.
  lookMsg <- lookAt True canSee p leader enemyMsg
  modifyClient $ \cli -> cli {slastKey = Nothing}
  if EM.size is <= 2 then
    promptToSlideshow (mode <+> lookMsg)
  else do
    io <- floorItemOverlay is
    overlayToSlideshow (mode <+> lookMsg) io

-- | Create a list of item names.
floorItemOverlay :: MonadClient m => ItemBag -> m Overlay
floorItemOverlay bag = do
  Kind.COps{coitem} <- getsState scops
  s <- getState
  disco <- getsClient sdisco
  let is = zip (EM.assocs bag) (allLetters ++ repeat (InvChar ' '))
      pr ((iid, k), l) =
         makePhrase [ letterLabel l
                    , partItemWs coitem disco k (getItemBody iid s) ]
         <> " "
  return $ toOverlay $ map pr is

-- | Create a list of item names.
itemOverlay :: MonadClient m => ItemBag -> ItemInv -> m Overlay
itemOverlay bag inv = do
  Kind.COps{coitem} <- getsState scops
  s <- getState
  disco <- getsClient sdisco
  let pr (l, iid) =
         makePhrase [ letterLabel l
                    , partItemWs coitem disco (bag EM.! iid)
                                 (getItemBody iid s) ]
         <> " "
  return $ toOverlay $ map pr $ EM.assocs inv

-- * Project

retargetLeader :: MonadClientUI m => m Slideshow
retargetLeader = do
  stopPlayBack
  arena <- getArenaUI
  tgtPos <- targetToPos
  if isNothing tgtPos
  -- TODO: do not save to history:
    then msgAdd "Last target invalid."
    else msgAdd "Cannot aim at oneself."
  modifyClient $ \cli -> cli {scursor = Nothing, seps = 0}
  tgtEnemyLeader $ TgtAuto arena

-- * PickLeader

pickLeaderHuman :: MonadClientUI m => Int -> m Slideshow
pickLeaderHuman k = do
  side <- getsClient sside
  s <- getState
  case tryFindHeroK s side k of
    Nothing  -> failWith "No such member of the party."
    Just (aid, _) -> do
      void $ pickLeader aid
      return mempty

-- * MemberCycle

-- | Switches current member to the next on the level, if any, wrapping.
memberCycleHuman :: MonadClientUI m => m Slideshow
memberCycleHuman = do
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  hs <- partyAfterLeader leader
  case filter (\(_, b) -> blid b == blid body) hs of
    [] -> failWith "Cannot pick any other member on this level."
    (np, b) : _ -> do
      success <- pickLeader np
      assert (success `blame` "same leader" `twith` (leader, np, b)) skip
      return mempty

partyAfterLeader :: MonadActionRO m => ActorId -> m [(ActorId, Actor)]
partyAfterLeader leader = do
  faction <- getsState $ bfid . getActorBody leader
  allA <- getsState $ EM.assocs . sactorD
  s <- getState
  let hs9 = mapMaybe (tryFindHeroK s faction) [0..9]
      factionA = filter (\(_, body) ->
        not (bproj body) && bfid body == faction) allA
      hs = hs9 ++ deleteFirstsBy ((==) `on` fst) factionA hs9
      i = fromMaybe (-1) $ findIndex ((== leader) . fst) hs
      (lt, gt) = (take i hs, drop (i + 1) hs)
  return $ gt ++ lt

-- | Select a faction leader. False, if nothing to do.
pickLeader :: MonadClientUI m => ActorId -> m Bool
pickLeader actor = do
  leader <- getLeaderUI
  stgtMode <- getsClient stgtMode
  if leader == actor
    then return False -- already picked
    else do
      pbody <- getsState $ getActorBody actor
      assert (not (bproj pbody) `blame` "projectile chosen as the leader"
                                `twith` (actor, pbody)) skip
      -- Even if it's already the leader, give his proper name, not 'you'.
      let subject = partActor pbody
      msgAdd $ makeSentence [subject, "picked as a leader"]
      -- Update client state.
      s <- getState
      modifyClient $ updateLeader actor s
      -- Move the cursor, if active, to the new level...
      case stgtMode of
        Nothing -> return ()
        Just tgtMode -> do
          setTgtId $ blid pbody
          -- ... and to the new position, if the new leader targets
          -- enemy or position.
          target <- getsClient $ getTarget actor
          when (isJust target) $ setCursor tgtMode
      -- Inform about items, etc.
      lookMsg <- lookAt False True (bpos pbody) actor ""
      msgAdd lookMsg
      return True

-- * MemberBack

-- | Switches current member to the previous in the whole dungeon, wrapping.
memberBackHuman :: MonadClientUI m => m Slideshow
memberBackHuman = do
  leader <- getLeaderUI
  hs <- partyAfterLeader leader
  case reverse hs of
    [] -> failWith "No other member in the party."
    (np, b) : _ -> do
      success <- pickLeader np
      assert (success `blame` "same leader" `twith` (leader, np, b)) skip
      return mempty

-- * Inventory

-- TODO: When inventory is displayed, let TAB switch the leader (without
-- announcing that) and show the inventory of the new leader (unless
-- we have just a single inventory in the future).
-- | Display inventory
inventoryHuman :: MonadClientUI m => m Slideshow
inventoryHuman = do
  leader <- getLeaderUI
  subject <- partAidLeader leader
  bag <- getsState $ getActorBag leader
  invRaw <- getsState $ getActorInv leader
  if EM.null bag
    then promptToSlideshow $ makeSentence
      [ MU.SubjectVerbSg subject "be"
      , "not carrying anything" ]
    else do
      let blurb = makePhrase
            [MU.Capitalize $ MU.SubjectVerbSg subject "be carrying:"]
          inv = EM.filter (`EM.member` bag) invRaw
      io <- itemOverlay bag inv
      overlayToSlideshow blurb io

-- * TgtFloor

tgtFloorHuman :: MonadClientUI m => m Slideshow
tgtFloorHuman = do
  arena <- getArenaUI
  tgtFloorLeader (TgtExplicit arena)

-- | Start floor targeting mode or reset the cursor position to the leader.
-- Note that the origin of a command (the hero that performs it) is unaffected
-- by targeting. For example, not the targeted door, but one adjacent
-- to the leader is closed by him.
tgtFloorLeader :: MonadClientUI m => TgtMode -> m Slideshow
tgtFloorLeader stgtModeNew = do
  leader <- getLeaderUI
  target <- getsClient $ getTarget leader
  b <- getsState $ getActorBody leader
  mcursor <- getsClient scursor
  stgtMode <- getsClient stgtMode
  tgtPos <- targetToPos
  let cursor = fromMaybe (bpos b) mcursor
      (tgt, newCursor) = case target of
        Just TEnemy{} ->  -- forget enemy target, keep the cursor
          (Nothing, cursor)
        _ | not $ isJust stgtMode ->
          -- first key press: keep target and cursor
          (target, cursor)
        Just TVector{} | tgtPos == mcursor ->
          -- double key press at this position: forget position, reset cursor
          (Nothing, bpos b)
        _ ->
          -- any other not first key press: target position, keep the cursor
          (Just $ TVector $ displacement (bpos b) cursor, cursor)
  -- Register that we want to target positions or cursor.
  modifyClient $ updateTarget leader (const tgt)
  modifyClient $ \cli -> cli {scursor = Just newCursor}
  setCursor stgtModeNew
  doLook

-- | Set and activate cursor.
setCursor :: MonadClientUI m => TgtMode -> m ()
setCursor stgtModeNew = do
  stgtModeOld <- getsClient stgtMode
  scursorOld <- getsClient scursor
  sepsOld <- getsClient seps
  scursor <- targetToPos
  let seps = if scursor == scursorOld then sepsOld else 0
      stgtMode = if isNothing stgtModeOld
                 then Just stgtModeNew
                 else stgtModeOld
  modifyClient $ \cli -> cli {scursor, seps, stgtMode}

-- * TgtEnemy

tgtEnemyHuman :: MonadClientUI m => m Slideshow
tgtEnemyHuman = do
  arena <- getArenaUI
  tgtEnemyLeader (TgtExplicit arena)

-- | Start the enemy targeting mode. Cycle between enemy targets.
tgtEnemyLeader :: MonadClientUI m => TgtMode -> m Slideshow
tgtEnemyLeader stgtModeNew = do
  leader <- getLeaderUI
  ppos <- getsState (bpos . getActorBody leader)
  (lid, _) <- viewedLevel
  per <- getPerFid lid
  scursor <- getsClient scursor
  target <- getsClient $ getTarget leader
  stgtMode <- getsClient stgtMode
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  bs <- getsState $ actorNotProjAssocs (isAtWar fact) lid
  let ordPos (_, b) = (chessDist ppos $ bpos b, bpos b)
      dbs = sortBy (comparing ordPos) bs
      (lt, gt) = case target of
            Just (TEnemy n _) | isJust stgtMode ->  -- pick next enemy
              let i = fromMaybe (-1) $ findIndex ((== n) . fst) dbs
              in splitAt (i + 1) dbs
            Just (TEnemy n _) ->  -- first key press, retarget old enemy
              let i = fromMaybe (-1) $ findIndex ((== n) . fst) dbs
              in splitAt i dbs
            _ ->  -- first key press, switch to the enemy under cursor, if any
              let i = fromMaybe (-1)
                      $ findIndex ((== scursor) . Just . bpos . snd) dbs
              in splitAt i dbs
      gtlt = gt ++ lt
      seen (_, b) =
        let mpos = bpos b                -- it is remembered by faction
        in actorSeesPos per leader mpos  -- is it visible by actor?
      lf = filter seen gtlt
      tgt = case lf of
              [] -> target  -- no enemies in sight, stick to last target
              (na, nm) : _ -> Just (TEnemy na (bpos nm))  -- pick the next
  -- Register the chosen enemy, to pick another on next invocation.
  modifyClient $ updateTarget leader (const tgt)
  setCursor stgtModeNew
  doLook

-- * TgtUnknown

tgtUnknownHuman :: MonadClientUI m => m Slideshow
tgtUnknownHuman = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  tgtPos <- targetToPos
  let target = case tgtPos of
        Nothing -> bpos b
        Just c -> c
  (bfs, _) <- getCacheBfs leader target
  let closestUnknownPos = PointArray.minIndexA bfs
      dist = bfs PointArray.! closestUnknownPos
  if dist >= minKnown
    then failWith "no unknown spot left"
    else do
      let tgt = Just $ TPoint closestUnknownPos
      modifyClient $ updateTarget leader (const tgt)
      return mempty

-- * TgtAscend

-- | Change the displayed level in targeting mode to (at most)
-- k levels shallower. Enters targeting mode, if not already in one.
tgtAscendHuman :: MonadClientUI m => Int -> m Slideshow
tgtAscendHuman k = do
  Kind.COps{cotile=cotile@Kind.Ops{okind}} <- getsState scops
  dungeon <- getsState sdungeon
  cursor <- getsClient scursor
  (tgtId, lvl) <- viewedLevel
  let rightStairs = case cursor of
        Nothing -> Nothing
        Just cpos ->
          let tile = lvl `at` cpos
          in if Tile.hasFeature cotile (F.Cause $ Effect.Ascend k) tile
             then Just cpos
             else Nothing
  case rightStairs of
    Just cpos -> do  -- stairs, in the right direction
      (nln, npos) <- getsState $ whereTo tgtId cpos k
      assert (nln /= tgtId `blame` "stairs looped" `twith` nln) skip
      -- Do not freely reveal the other end of the stairs.
      let ascDesc (F.Cause (Effect.Ascend _)) = True
          ascDesc _ = False
          scursor =
            if any ascDesc $ tfeature $ okind (lvl `at` npos)
            then Just npos  -- already known as an exit, focus on it
            else cursor     -- unknown, do not reveal
      modifyClient $ \cli -> cli {scursor}
      setTgtId nln
      doLook
    Nothing ->  -- no stairs in the right direction
      case ascendInBranch dungeon tgtId k of
        [] -> failWith "no more levels in this direction"
        nln : _ -> do
          setTgtId nln
          doLook

setTgtId :: MonadClient m => LevelId -> m ()
setTgtId nln = do
  stgtMode <- getsClient stgtMode
  case stgtMode of
    Just (TgtAuto _) ->
      modifyClient $ \cli -> cli {stgtMode = Just (TgtAuto nln)}
    _ ->
      modifyClient $ \cli -> cli {stgtMode = Just (TgtExplicit nln)}

-- * EpsIncr

-- | Tweak the @eps@ parameter of the targeting digital line.
epsIncrHuman :: MonadClientUI m => Bool -> m Slideshow
epsIncrHuman b = do
  stgtMode <- getsClient stgtMode
  if isJust stgtMode
    then do
      modifyClient $ \cli -> cli {seps = seps cli + if b then 1 else -1}
      return mempty
    else failWith "never mind"  -- no visual feedback, so no sense

-- * SelectActor

-- TODO: make the message (and for selectNoneHuman, pickLeader, etc.)
-- optional, since they have a clear representation in the UI elsewhere.
selectActorHuman ::MonadClientUI m => m Slideshow
selectActorHuman = do
  mleader <- getsClient _sleader
  case mleader of
    Nothing -> failWith "no leader picked, can't select"
    Just leader -> do
      body <- getsState $ getActorBody leader
      wasMemeber <- getsClient $ ES.member leader . sselected
      let upd = if wasMemeber
                then ES.delete leader  -- already selected, deselect instead
                else ES.insert leader
      modifyClient $ \cli -> cli {sselected = upd $ sselected cli}
      let subject = partActor body
      msgAdd $ makeSentence [subject, if wasMemeber
                                      then "deselected"
                                      else "selected"]
      return mempty

-- * SelectNone

selectNoneHuman :: (MonadClientUI m, MonadClient m) => m ()
selectNoneHuman = do
  side <- getsClient sside
  (lid, _) <- viewedLevel
  oursAssocs <- getsState $ actorNotProjAssocs (== side) lid
  let ours = ES.fromList $ map fst oursAssocs
  oldSel <- getsClient sselected
  let wasNone = ES.null $ ES.intersection ours oldSel
      upd = if wasNone
            then ES.union  -- already all deselected; select all instead
            else ES.difference
  modifyClient $ \cli -> cli {sselected = upd (sselected cli) ours}
  let subject = "all party members on the level"
  msgAdd $ makeSentence [subject, if wasNone
                                  then "selected"
                                  else "deselected"]

-- * Cancel

-- | Cancel something, e.g., targeting mode, resetting the cursor
-- to the position of the leader. Chosen target is not invalidated.
cancelHuman :: MonadClientUI m => m Slideshow -> m Slideshow
cancelHuman h = do
  stgtMode <- getsClient stgtMode
  if isJust stgtMode
    then targetReject
    else h  -- nothing to cancel right now, treat this as a command invocation

-- TODO: merge with the help screens better
-- | Display the main menu.
displayMainMenu :: MonadClientUI m => m Slideshow
displayMainMenu = do
  Kind.COps{corule} <- getsState scops
  Binding{krevMap} <- askBinding
  sdifficulty <- getsClient sdifficulty
  DebugModeCli{sdifficultyCli} <- getsClient sdebugCli
  let stripFrame t = map (T.tail . T.init) $ tail . init $ T.lines t
      pasteVersion art =
        let pathsVersion = rpathsVersion $ Kind.stdRuleset corule
            version = " Version " ++ showVersion pathsVersion
                      ++ " (frontend: " ++ frontendName
                      ++ ", engine: LambdaHack " ++ showVersion Self.version
                      ++ ") "
            versionLen = length version
        in init art ++ [take (80 - versionLen) (last art) ++ version]
      kds =  -- key-description pairs
        let showKD cmd km = (K.showKM km, HumanCmd.cmdDescription cmd)
            revLookup cmd = maybe ("", "") (showKD cmd) $ M.lookup cmd krevMap
            cmds = [ HumanCmd.GameExit
                   , HumanCmd.GameRestart "campaign"
                   , HumanCmd.GameRestart "skirmish"
                   , HumanCmd.GameRestart "PvP"
                   , HumanCmd.GameRestart "Coop"
                   , HumanCmd.GameRestart "defense"
                   ]
        in [ (fst (revLookup HumanCmd.Cancel), "back to playing")
           , (fst (revLookup HumanCmd.Accept), "see more help") ]
           ++ map revLookup cmds
           ++ [ (fst ( revLookup HumanCmd.GameDifficultyCycle)
                     , "next game difficulty" <+> showT (5 - sdifficultyCli)
                       <+> "(current" <+> showT (5 - sdifficulty) <> ")" ) ]
      bindingLen = 25
      bindings =  -- key bindings to display
        let fmt (k, d) = T.justifyLeft bindingLen ' '
                         $ T.justifyLeft 7 ' ' k <> " " <> d
        in map fmt kds
      overwrite =  -- overwrite the art with key bindings
        let over [] line = ([], T.pack line)
            over bs@(binding : bsRest) line =
              let (prefix, lineRest) = break (=='{') line
                  (braces, suffix)   = span  (=='{') lineRest
              in if length braces == 25
                 then (bsRest, T.pack prefix <> binding
                               <> T.drop (T.length binding - bindingLen)
                                         (T.pack suffix))
                 else (bs, T.pack line)
        in snd . mapAccumL over bindings
      mainMenuArt = rmainMenuArt $ Kind.stdRuleset corule
      menuOverlay =  -- TODO: switch to Text and use T.justifyLeft
        overwrite $ pasteVersion $ map T.unpack $ stripFrame mainMenuArt
  case menuOverlay of
    [] -> assert `failure` "empty Main Menu overlay" `twith` mainMenuArt
    hd : tl -> overlayToSlideshow hd (toOverlay tl)
               -- TODO: keys don't work if tl/=[]

-- * Accept

-- | Accept something, e.g., targeting mode, keeping cursor where it was.
-- Or perform the default action, if nothing needs accepting.
acceptHuman :: MonadClientUI m => m Slideshow -> m Slideshow
acceptHuman h = do
  stgtMode <- getsClient stgtMode
  if isJust stgtMode
    then do
      targetAccept
      return mempty
    else h  -- nothing to accept right now, treat this as a command invocation

-- | End targeting mode, accepting the current position.
targetAccept :: MonadClientUI m => m ()
targetAccept = do
  endTargeting
  endTargetingMsg
  modifyClient $ \cli -> cli {stgtMode = Nothing}

-- | End targeting mode, rejecting the current position.
targetReject :: MonadClientUI m => m Slideshow
targetReject = do
  modifyClient $ \cli -> cli {stgtMode = Nothing}
  failWith "targeting canceled"

-- | End targeting mode, accepting the current position.
endTargeting :: MonadClientUI m => m ()
endTargeting = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  scursor <- getsClient scursor
  (lid, _) <- viewedLevel
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  bs <- getsState $ actorNotProjAssocs (isAtWar fact) lid
  let newTarget oldTarget = case oldTarget of
        Just TEnemy{} ->
          -- If in enemy targeting mode, switch to the enemy under
          -- the current cursor position, if any.
          case find (\(_im, m) -> Just (bpos m) == scursor) bs of
            Just (im, m) -> Just $ TEnemy im (bpos m)
            Nothing -> oldTarget
        Just TPoint{} ->
          case scursor of
            Nothing -> oldTarget
            Just cpos -> Just $ TPoint cpos
        Just TVector{} ->
          case scursor of
            Nothing -> oldTarget
            Just cpos -> Just $ TVector $ displacement (bpos b) cpos
        Nothing -> oldTarget
  modifyClient $ updateTarget leader newTarget

endTargetingMsg :: MonadClientUI m => m ()
endTargetingMsg = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  target <- getsClient $ getTarget leader
  s <- getState
  tgtPos <- targetToPos
  let targetMsg = case target of
                    Just (TEnemy a _ll) ->
                      if memActor a (blid b) s
                      -- Never equal to leader, hence @partActor@.
                      then partActor $ getActorBody a s
                      else "a fear of the past"
                    Just TPoint{} ->
                      MU.Text $ "spot" <+> T.pack (show tgtPos)
                    Just TVector{} ->
                      MU.Text $ "position" <+> T.pack (show tgtPos)
                    Nothing -> "current cursor position continuously"
  subject <- partAidLeader leader
  msgAdd $ makeSentence [MU.SubjectVerbSg subject "target", targetMsg]

-- * Clear

-- | Clear current messages, show the next screen if any.
clearHuman :: Monad m => m ()
clearHuman = return ()

-- * Repeat

-- Note that walk followed by repeat should not be equivalent to run,
-- because the player can really use a command that does not stop
-- at terrain change or when walking over items.
repeatHuman :: MonadClientUI m => Int -> m ()
repeatHuman n = do
  (_, seqPrevious, k) <- getsClient slastRecord
  let macro = concat $ replicate n $ reverse seqPrevious
  modifyClient $ \cli -> cli {slastPlay = macro ++ slastPlay cli}
  let slastRecord = ([], [], if k == 0 then 0 else maxK)
  modifyClient $ \cli -> cli {slastRecord}

maxK :: Int
maxK = 100

-- * Record

recordHuman :: MonadClientUI m => m Slideshow
recordHuman = do
  modifyClient $ \cli -> cli {slastKey = Nothing}
  (_seqCurrent, seqPrevious, k) <- getsClient slastRecord
  case k of
    0 -> do
      let slastRecord = ([], [], maxK)
      modifyClient $ \cli -> cli {slastRecord}
      promptToSlideshow $ "Macro will be recorded for up to"
                          <+> showT maxK <+> "steps."
    _ -> do
      let slastRecord = (seqPrevious, [], 0)
      modifyClient $ \cli -> cli {slastRecord}
      promptToSlideshow $ "Macro recording interrupted after"
                          <+> showT (maxK - k - 1) <+> "steps."

-- * History

historyHuman :: MonadClientUI m => m Slideshow
historyHuman = do
  history <- getsClient shistory
  arena <- getArenaUI
  local <- getsState $ getLocalTime arena
  global <- getsState stime
  let  msg = makeSentence
        [ "You survived for"
        , MU.CarWs (global `timeFit` timeTurn) "half-second turn"
        , "(this level:"
        , MU.Text (showT (local `timeFit` timeTurn)) MU.:> ")" ]
        <+> "Past messages:"
  overlayToSlideshow msg $ renderHistory history

-- * MarkVision, MarkSmell, MarkSuspect

humanMarkVision :: MonadClientUI m => m ()
humanMarkVision = do
  modifyClient toggleMarkVision
  cur <- getsClient smarkVision
  msgAdd $ "Visible area display toggled" <+> if cur then "on." else "off."

humanMarkSmell :: MonadClientUI m => m ()
humanMarkSmell = do
  modifyClient toggleMarkSmell
  cur <- getsClient smarkSmell
  msgAdd $ "Smell display toggled" <+> if cur then "on." else "off."

humanMarkSuspect :: MonadClientUI m => m ()
humanMarkSuspect = do
  modifyClient toggleMarkSuspect
  cur <- getsClient smarkSuspect
  msgAdd $ "Suspect terrain display toggled" <+> if cur then "on." else "off."

-- * Help

-- | Display command help.
helpHuman :: MonadClientUI m => m Slideshow
helpHuman = do
  keyb <- askBinding
  return $ keyHelp keyb
