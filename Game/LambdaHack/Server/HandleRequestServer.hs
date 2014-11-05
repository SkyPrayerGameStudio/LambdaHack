{-# LANGUAGE GADTs #-}
-- | Semantics of request.
-- A couple of them do not take time, the rest does.
-- Note that since the results are atomic commands, which are executed
-- only later (on the server and some of the clients), all condition
-- are checkd by the semantic functions in the context of the state
-- before the server command. Even if one or more atomic actions
-- are already issued by the point an expression is evaluated, they do not
-- influence the outcome of the evaluation.
-- TODO: document
module Game.LambdaHack.Server.HandleRequestServer
  ( handleRequestAI, handleRequestUI, reqMove
  ) where

import Control.Applicative
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.Maybe
import Data.Text (Text)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.ModeKind
import qualified Game.LambdaHack.Content.TileKind as TK
import Game.LambdaHack.Server.CommonServer
import Game.LambdaHack.Server.HandleEffectServer
import Game.LambdaHack.Server.ItemServer
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.State

-- | The semantics of server commands. The resulting actor id
-- is of the actor that carried out the request.
handleRequestAI :: (MonadAtomic m, MonadServer m)
                => FactionId -> ActorId -> RequestAI -> m (ActorId, m ())
handleRequestAI fid aid cmd = case cmd of
  ReqAITimed cmdT -> return (aid, handleRequestTimed aid cmdT)
  ReqAILeader aidNew mtgtNew cmd2 -> do
    switchLeader fid aidNew mtgtNew
    handleRequestAI fid aidNew cmd2
  ReqAIPong -> return (aid, skip)

-- | The semantics of server commands. The resulting actor id
-- is of the actor that carried out the request. @Nothing@ means
-- the command took no time.
handleRequestUI :: (MonadAtomic m, MonadServer m)
                => FactionId -> RequestUI -> m (Maybe ActorId, m ())
handleRequestUI fid cmd = case cmd of
  ReqUITimed cmdT -> do
    fact <- getsState $ (EM.! fid) . sfactionD
    let (aid, _) = fromMaybe (assert `failure` fact) $ gleader fact
    return (Just aid, handleRequestTimed aid cmdT)
  ReqUILeader aidNew mtgtNew cmd2 -> do
    switchLeader fid aidNew mtgtNew
    handleRequestUI fid cmd2
  ReqUIGameRestart aid t d names ->
    return (Nothing, reqGameRestart aid t d names)
  ReqUIGameExit aid d -> return (Nothing, reqGameExit aid d)
  ReqUIGameSave -> return (Nothing, reqGameSave)
  ReqUITactic toT -> return (Nothing, reqTactic fid toT)
  ReqUIAutomate -> return (Nothing, reqAutomate fid)
  ReqUIPong _ -> return (Nothing, skip)

handleRequestTimed :: (MonadAtomic m, MonadServer m)
                   => ActorId -> RequestTimed a -> m ()
handleRequestTimed aid cmd = case cmd of
  ReqMove target -> reqMove aid target
  ReqMelee target iid cstore -> reqMelee aid target iid cstore
  ReqDisplace target -> reqDisplace aid target
  ReqAlter tpos mfeat -> reqAlter aid tpos mfeat
  ReqWait -> reqWait aid
  ReqMoveItem iid k fromCStore toCStore ->
    reqMoveItem aid iid k fromCStore toCStore
  ReqProject p eps iid cstore -> reqProject aid p eps iid cstore
  ReqApply iid cstore -> reqApply aid iid cstore
  ReqTrigger mfeat -> reqTrigger aid mfeat

switchLeader :: (MonadAtomic m, MonadServer m)
             => FactionId -> ActorId -> Maybe Target -> m ()
switchLeader fid aidNew mtgtNew = do
  fact <- getsState $ (EM.! fid) . sfactionD
  bPre <- getsState $ getActorBody aidNew
  let mleader = gleader fact
      actorChanged = fmap fst mleader /= Just aidNew
  assert (Just (aidNew, mtgtNew) /= mleader
          && not (bproj bPre)
          `blame` (aidNew, mtgtNew, bPre, fid, fact)) skip
  assert (bfid bPre == fid
          `blame` "client tries to move other faction actors"
          `twith` (aidNew, mtgtNew, bPre, fid, fact)) skip
  let (autoDun, autoLvl) = autoDungeonLevel fact
  arena <- case mleader of
    Nothing -> return $! blid bPre
    Just (leader, _) -> do
      b <- getsState $ getActorBody leader
      return $! blid b
  if actorChanged && blid bPre /= arena && autoDun
  then execFailure aidNew ReqWait{-hack-} NoChangeDunLeader
  else if actorChanged && autoLvl
  then execFailure aidNew ReqWait{-hack-} NoChangeLvlLeader
  else execUpdAtomic $ UpdLeadFaction fid mleader (Just (aidNew, mtgtNew))

-- * ReqMove

-- TODO: let only some actors/items leave smell, e.g., a Smelly Hide Armour
-- and then remove the efficiency hack below that only heroes leave smell
-- | Add a smell trace for the actor to the level. For now, only heroes
-- leave smell.
addSmell :: (MonadAtomic m, MonadServer m) => ActorId -> m ()
addSmell aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  smellRadius <- sumOrganEqpServer IK.EqpSlotAddSmell aid
  -- TODO: right now only humans leave smell and content should not
  -- give humans the ability to smell (dominated monsters are rare enough).
  -- In the future smells should be marked by the faction that left them
  -- and actors shold only follow enemy smells.
  unless (bproj b || not (fhasGender $ gplayer fact) || smellRadius > 0) $ do
    time <- getsState $ getLocalTime $ blid b
    lvl <- getLevel $ blid b
    let oldS = EM.lookup (bpos b) . lsmell $ lvl
        newTime = timeShift time smellTimeout
    execUpdAtomic $ UpdAlterSmell (blid b) (bpos b) oldS (Just newTime)

-- | Actor moves or attacks.
-- Note that client may not be able to see an invisible monster
-- so it's the server that determines if melee took place, etc.
-- Also, only the server is authorized to check if a move is legal
-- and it needs full context for that, e.g., the initial actor position
-- to check if melee attack does not try to reach to a distant tile.
reqMove :: (MonadAtomic m, MonadServer m) => ActorId -> Vector -> m ()
reqMove source dir = do
  cops <- getsState scops
  sb <- getsState $ getActorBody source
  let lid = blid sb
  lvl <- getLevel lid
  let spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
  -- We start by checking actors at the the target position.
  tgt <- getsState $ posToActor tpos lid
  case tgt of
    Just ((target, tb), _) | not (bproj sb && bproj tb) -> do  -- visible or not
      -- Projectiles are too small to hit each other.
      -- Attacking does not require full access, adjacency is enough.
      -- Here the only weapon of projectiles is picked, too.
      mweapon <- pickWeaponServer source
      case mweapon of
        Nothing -> reqWait source
        Just (wp, cstore) -> reqMelee source target wp cstore
    _
      | accessible cops lvl spos tpos -> do
          -- Movement requires full access.
          execUpdAtomic $ UpdMoveActor source spos tpos
          addSmell source
      | otherwise ->
          -- Client foolishly tries to move into blocked, boring tile.
          execFailure source (ReqMove dir) MoveNothing

-- * ReqMelee

-- | Resolves the result of an actor moving into another.
-- Actors on blocked positions can be attacked without any restrictions.
-- For instance, an actor embedded in a wall can be attacked from
-- an adjacent position. This function is analogous to projectGroupItem,
-- but for melee and not using up the weapon.
-- No problem if there are many projectiles at the spot. We just
-- attack the one specified.
reqMelee :: (MonadAtomic m, MonadServer m)
         => ActorId -> ActorId -> ItemId -> CStore -> m ()
reqMelee source target iid cstore = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  let adj = checkAdjacent sb tb
      req = ReqMelee target iid cstore
  if source == target then execFailure source req MeleeSelf
  else if not adj then execFailure source req MeleeDistant
  else do
    let sfid = bfid sb
        tfid = bfid tb
    sfact <- getsState $ (EM.! sfid) . sfactionD
    hurtBonus <- armorHurtBonus source target
    let isFightImpaired = hurtBonus <= -10
        block = braced tb
        hitA = if block && isFightImpaired
               then HitBlock 2
               else if block || isFightImpaired
                    then HitBlock 1
                    else HitClear
    execSfxAtomic $ SfxStrike source target iid hitA
    -- Deduct a hitpoint for a pierce of a projectile
    -- or due to a hurled actor colliding with another or a wall.
    case btrajectory sb of
      Nothing -> return ()
      Just (tra, speed) -> do
        execUpdAtomic $ UpdRefillHP source minusM
        unless (bproj sb || null tra) $
          -- Non-projectiles can't pierce, so terminate their flight.
          execUpdAtomic
          $ UpdTrajectory source (btrajectory sb) (Just ([], speed))
    let c = CActor source cstore
    -- Msgs inside itemEffect describe the target part.
    itemEffectAndDestroy source target iid c
    -- The only way to start a war is to slap an enemy. Being hit by
    -- and hitting projectiles count as unintentional friendly fire.
    let friendlyFire = bproj sb || bproj tb
        fromDipl = EM.findWithDefault Unknown tfid (gdipl sfact)
    unless (friendlyFire
            || isAtWar sfact tfid  -- already at war
            || isAllied sfact tfid  -- allies never at war
            || sfid == tfid) $
      execUpdAtomic $ UpdDiplFaction sfid tfid fromDipl War

-- * ReqDisplace

-- | Actor tries to swap positions with another.
reqDisplace :: (MonadAtomic m, MonadServer m) => ActorId -> ActorId -> m ()
reqDisplace source target = do
  cops <- getsState scops
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  tfact <- getsState $ (EM.! bfid tb) . sfactionD
  let spos = bpos sb
      tpos = bpos tb
      adj = checkAdjacent sb tb
      atWar = isAtWar tfact (bfid sb)
      req = ReqDisplace target
  activeItems <- activeItemsServer target
  dEnemy <- getsState $ dispEnemy source target activeItems
  if not adj then execFailure source req DisplaceDistant
  else if atWar && not dEnemy
  then do
    mweapon <- pickWeaponServer source
    case mweapon of
      Nothing -> reqWait source
      Just (wp, cstore)  -> reqMelee source target wp cstore
        -- DisplaceDying, DisplaceSupported
  else do
    let lid = blid sb
    lvl <- getLevel lid
    -- Displacing requires full access.
    if accessible cops lvl spos tpos then do
      tgts <- getsState $ posToActors tpos lid
      case tgts of
        [] -> assert `failure` (source, sb, target, tb)
        [_] -> do
          execUpdAtomic $ UpdDisplaceActor source target
          addSmell source
          addSmell target
        _ -> execFailure source req DisplaceProjectiles
    else do
      -- Client foolishly tries to displace an actor without access.
      execFailure source req DisplaceAccess

-- * ReqAlter

-- | Search and/or alter the tile.
--
-- Note that if @serverTile /= freshClientTile@, @freshClientTile@
-- should not be alterable (but @serverTile@ may be).
reqAlter :: (MonadAtomic m, MonadServer m)
         => ActorId -> Point -> Maybe TK.Feature -> m ()
reqAlter source tpos mfeat = do
  cops@Kind.COps{cotile=cotile@Kind.Ops{okind, opick}} <- getsState scops
  sb <- getsState $ getActorBody source
  let lid = blid sb
      spos = bpos sb
      req = ReqAlter tpos mfeat
  if not $ adjacent spos tpos then execFailure source req AlterDistant
  else do
    lvl <- getLevel lid
    let serverTile = lvl `at` tpos
        freshClientTile = hideTile cops lvl tpos
        changeTo tgroup = do
          -- No @SfxAlter@, because the effect is obvious (e.g., opened door).
          toTile <- rndToAction $ fmap (fromMaybe $ assert `failure` tgroup)
                                  $ opick tgroup (const True)
          unless (toTile == serverTile) $ do
            execUpdAtomic $ UpdAlterTile lid tpos serverTile toTile
            case (Tile.isExplorable cotile serverTile,
                  Tile.isExplorable cotile toTile) of
              (False, True) -> execUpdAtomic $ UpdAlterClear lid 1
              (True, False) -> execUpdAtomic $ UpdAlterClear lid (-1)
              _ -> return ()
        feats = case mfeat of
          Nothing -> TK.tfeature $ okind serverTile
          Just feat2 | Tile.hasFeature cotile feat2 serverTile -> [feat2]
          Just _ -> []
        toAlter feat =
          case feat of
            TK.OpenTo tgroup -> Just tgroup
            TK.CloseTo tgroup -> Just tgroup
            TK.ChangeTo tgroup -> Just tgroup
            _ -> Nothing
        groupsToAlterTo = mapMaybe toAlter feats
    as <- getsState $ actorList (const True) lid
    if null groupsToAlterTo && serverTile == freshClientTile then
      -- Neither searching nor altering possible; silly client.
      execFailure source req AlterNothing
    else do
      if EM.notMember tpos $ lfloor lvl then
        if unoccupied as tpos then do
          when (serverTile /= freshClientTile) $ do
            -- Search, in case some actors (of other factions?)
            -- don't know this tile.
            execUpdAtomic $ UpdSearchTile source tpos freshClientTile serverTile
          maybe skip changeTo $ listToMaybe groupsToAlterTo
            -- TODO: pick another, if the first one void
          -- Perform an effect, if any permitted.
          void $ triggerEffect source tpos feats
        else execFailure source req AlterBlockActor
      else execFailure source req AlterBlockItem

-- * ReqWait

-- | Do nothing.
--
-- Something is sometimes done in 'LoopAction.setBWait'.
reqWait :: MonadAtomic m => ActorId -> m ()
reqWait _ = return ()

-- * ReqMoveItem

reqMoveItem :: (MonadAtomic m, MonadServer m)
            => ActorId -> ItemId -> Int -> CStore -> CStore -> m ()
reqMoveItem aid iid k fromCStore toCStore = do
  b <- getsState $ getActorBody aid
  activeItems <- activeItemsServer aid
  let fromC = CActor aid fromCStore
      toC = CActor aid toCStore
  bagBefore <- getsState $ getCBag toC
  let moveItem = do
        when (fromCStore == CGround) $ do
          seed <- getsServer $ (EM.! iid) . sitemSeedD
          execUpdAtomic $ UpdDiscoverSeed (blid b) (bpos b) iid seed
        upds <- generalMoveItem iid k fromC toC
        mapM_ execUpdAtomic upds
      req = ReqMoveItem iid k fromCStore toCStore
  if k < 1 || fromCStore == toCStore then execFailure aid req ItemNothing
  else if toCStore == CEqp
          && eqpOverfull b k then execFailure aid req EqpOverfull
  else if fromCStore /= CSha && toCStore /= CSha then moveItem
  else do
    if calmEnough b activeItems then moveItem
    else execFailure aid req ItemNotCalm
  -- Reset timeout for equipped periodic items.
  when (toCStore `elem` [CEqp, COrgan]
        && fromCStore `notElem` [CEqp, COrgan]) $ do
    localTime <- getsState $ getLocalTime (blid b)
    discoEffect <- getsServer sdiscoEffect
    mrndTimeout <- rndToAction $ computeRndTimeout localTime discoEffect iid
    let beforeIt = case iid `EM.lookup` bagBefore of
          Nothing -> []  -- no such items before move
          Just (_, it2) -> it2
    -- The moved item set (not the whole stack) has its timeout
    -- reset to a random value between timeout and twice timeout.
    -- This prevents micromanagement via swapping items in and out of eqp
    -- and via exact prediction of first timeout after equip.
    case mrndTimeout of
      Just rndT -> do
        bagAfter <- getsState $ getCBag toC
        let afterIt = case iid `EM.lookup` bagAfter of
              Nothing -> assert `failure` (iid, bagAfter, toC)
              Just (_, it2) -> it2
            resetIt = beforeIt ++ replicate k rndT
        when (afterIt /= resetIt) $
          execUpdAtomic $ UpdTimeItem iid toC afterIt resetIt
      Nothing -> return ()  -- no Periodic or Timeout aspect; don't touch

computeRndTimeout :: Time -> DiscoveryEffect -> ItemId -> Rnd (Maybe Time)
computeRndTimeout localTime discoEffect iid = do
  let timeoutAspect :: IK.Aspect Int -> Maybe Int
      timeoutAspect (IK.Timeout t) = Just t
      timeoutAspect _ = Nothing
  case EM.lookup iid discoEffect of
    Just ItemAspectEffect{jaspects} -> do
      case mapMaybe timeoutAspect jaspects of
        [t] | IK.Periodic `elem` jaspects -> do
          rndT <- randomR (0, t)
          let rndTurns = timeDeltaScale (Delta timeTurn) rndT
          return $ Just $ timeShift localTime rndTurns
        _ -> return Nothing
    _ -> assert `failure` (iid, discoEffect)

-- * ReqProject

reqProject :: (MonadAtomic m, MonadServer m)
           => ActorId    -- ^ actor projecting the item (is on current lvl)
           -> Point      -- ^ target position of the projectile
           -> Int        -- ^ digital line parameter
           -> ItemId     -- ^ the item to be projected
           -> CStore     -- ^ whether the items comes from floor or inventory
           -> m ()
reqProject source tpxy eps iid cstore = assert (cstore /= CSha) $ do
  mfail <- projectFail source tpxy eps iid cstore False
  let req = ReqProject tpxy eps iid cstore
  maybe skip (execFailure source req) mfail

-- * ReqApply

reqApply :: (MonadAtomic m, MonadServer m)
         => ActorId  -- ^ actor applying the item (is on current level)
         -> ItemId   -- ^ the item to be applied
         -> CStore   -- ^ the location of the item
         -> m ()
reqApply aid iid cstore = assert (cstore /= CSha) $ do
  let req = ReqApply iid cstore
  bag <- getsState $ getActorBag aid cstore
  case EM.lookup iid bag of
    Nothing -> execFailure aid req ApplyOutOfReach
    Just kit -> do
      itemToF <- itemToFullServer
      b <- getsState $ getActorBody aid
      activeItems <- activeItemsServer aid
      actorBlind <- radiusBlind
                    <$> sumOrganEqpServer IK.EqpSlotAddSight aid
      let itemFull = itemToF iid kit
          calm10 = calmEnough10 b activeItems
          legal = permittedApply " " actorBlind calm10 itemFull
      case legal of
        Left reqFail -> execFailure aid req reqFail
        Right _ -> applyItem aid iid cstore

-- * ReqTrigger

-- | Perform the effect specified for the tile in case it's triggered.
reqTrigger :: (MonadAtomic m, MonadServer m)
           => ActorId -> Maybe TK.Feature -> m ()
reqTrigger aid mfeat = do
  Kind.COps{cotile=cotile@Kind.Ops{okind}} <- getsState scops
  sb <- getsState $ getActorBody aid
  let lid = blid sb
  lvl <- getLevel lid
  let tpos = bpos sb
      serverTile = lvl `at` tpos
      feats = case mfeat of
        Nothing -> TK.tfeature $ okind serverTile
        Just feat2 | Tile.hasFeature cotile feat2 serverTile -> [feat2]
        Just _ -> []
      req = ReqTrigger mfeat
  go <- triggerEffect aid tpos feats
  unless go $ execFailure aid req TriggerNothing

triggerEffect :: (MonadAtomic m, MonadServer m)
              => ActorId -> Point -> [TK.Feature] -> m Bool
triggerEffect aid tpos feats = do
  let triggerFeat feat =
        case feat of
          TK.Cause ef -> itemEffectCause aid tpos ef
          _ -> return False
  goes <- mapM triggerFeat feats
  return $! or goes

-- * ReqGameRestart

-- TODO: implement a handshake and send hero names there,
-- so that they are available in the first game too,
-- not only in subsequent, restarted, games.
reqGameRestart :: (MonadAtomic m, MonadServer m)
               => ActorId -> GroupName ModeKind -> Int -> [(Int, (Text, Text))] -> m ()
reqGameRestart aid groupName d configHeroNames = do
  modifyServer $ \ser ->
    ser {sdebugNxt = (sdebugNxt ser) { sdifficultySer = d
                                     , sdebugCli = (sdebugCli (sdebugNxt ser))
                                                     {sdifficultyCli = d}
                                     }}
  b <- getsState $ getActorBody aid
  let fid = bfid b
  oldSt <- getsState $ gquit . (EM.! fid) . sfactionD
  modifyServer $ \ser ->
    ser { squit = True  -- do this at once
        , sheroNames = EM.insert fid configHeroNames $ sheroNames ser }
  revealItems Nothing Nothing
  execUpdAtomic $ UpdQuitFaction fid (Just b) oldSt
                $ Just $ Status Restart (fromEnum $ blid b) (Just groupName)

-- * ReqGameExit

reqGameExit :: (MonadAtomic m, MonadServer m) => ActorId -> Int -> m ()
reqGameExit aid d = do
  modifyServer $ \ser ->
    ser {sdebugNxt = (sdebugNxt ser) { sdifficultySer = d
                                     , sdebugCli = (sdebugCli (sdebugNxt ser))
                                                     {sdifficultyCli = d}
                                     }}
  b <- getsState $ getActorBody aid
  let fid = bfid b
  oldSt <- getsState $ gquit . (EM.! fid) . sfactionD
  modifyServer $ \ser -> ser {swriteSave = True}
  modifyServer $ \ser -> ser {squit = True}  -- do this at once
  execUpdAtomic $ UpdQuitFaction fid (Just b) oldSt
                $ Just $ Status Camping (fromEnum $ blid b) Nothing

-- * ReqGameSave

reqGameSave :: MonadServer m => m ()
reqGameSave = do
  modifyServer $ \ser -> ser {swriteSave = True}
  modifyServer $ \ser -> ser {squit = True}  -- do this at once

-- * ReqTactic

reqTactic :: (MonadAtomic m, MonadServer m) => FactionId -> Tactic -> m ()
reqTactic fid toT = do
  fromT <- getsState $ ftactic . gplayer . (EM.! fid) . sfactionD
  execUpdAtomic $ UpdTacticFaction fid toT fromT

-- * ReqAutomate

reqAutomate :: (MonadAtomic m, MonadServer m) => FactionId -> m ()
reqAutomate fid = execUpdAtomic $ UpdAutoFaction fid True
