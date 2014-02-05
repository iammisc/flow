{-# LANGUAGE GeneralizedNewtypeDeriving, RecordWildCards, DoAndIfThenElse #-}
module Language.Flow.Execution.GMachine
    (
     runGMachine,
     newGMachine,
     newGMachineStateWithGCodeProgram,

     getUserState,

     continue,

     throwError,
     throwError',
     trace,

     allocGraphCell,
     writeGraph,
     readGraph,
     findReachablePoints,
     findNonReachablePoints,
     gEvaluate,

     pushDump,
     popDump,

     pushStack,
     popStack,
     topOfStack,

     freezeState,
     thawState
    ) where

import Control.Monad
import Control.Monad.State
import Control.Monad.Trans
import Control.Applicative

import qualified Data.Map as Map
import qualified Data.IntSet as IntSet
import qualified Data.Text as T
import Data.Either
import Data.List
import Data.Dynamic
import Data.Typeable
import Data.Array.IO
import Data.Array as AS

import Text.Printf

import Language.Flow.Execution.Types

import System.Log.Logger
import System.IO

moduleName = "Language.Flow.Execution.GMachine"

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

fromLeft :: Either a b -> a
fromLeft (Left x) = x
fromLeft _ = error "Right"

newGMachineStateWithGCodeProgram :: Typeable a => Int -> a -> [(GMachineAddress, GenericGData)] -> GCodeProgram -> IO GMachineState
newGMachineStateWithGCodeProgram cells userState initData prog =
    let context = GMachineContext {
                    gmcModules = progModules prog,
                    gmcTypes = progTypes prog}
    in newGMachine cells userState context (initCode prog) (initData ++ initialData prog) (progDebug prog) (progTrace prog)

newGMachine :: Typeable a => Int -> a -> GMachineContext ->
               GCodeSequence -> [(GMachineAddress, GenericGData)] ->
               Bool -> Bool -> IO GMachineState
newGMachine graphSize userState gmc initCode initData debug trace =
    do
      graph <- newArray (GMachineAddress 0, GMachineAddress $ graphSize - 1) Hole
      let gmachine = GMachineState { gmachineStack = [], -- create initial gmachine, so we can run allocGraphCells
                                     gmachineGraph = graph,
                                     gmachineCode = initCode,
                                     gmachineDump = [],
                                     gmachineInitData = initData,
                                     gmachineFreeCells = IntSet.fromList [0..graphSize - 1],
                                     gmachineIndent = 0,
                                     gmachineDebug = debug,
                                     gmachineTracing = trace,
                                     gmachineUserState = toDyn userState,
                                     gmachineContext = gmc}

      res <- runGMachine (forM_ initData $
                            (\(addr, dat) -> do
                               writeGraph addr dat
                               modify (\st -> st { gmachineFreeCells = IntSet.delete (fromIntegral addr) $ gmachineFreeCells st }))) gmachine
      let Right (gmachine', _) = res

      (gmachine'', code) <- gshow' gmachine' initCode
      (gmachine''', dat) <- gshow' gmachine'' initData
      infoM moduleName $ "Initial code: " ++ code
      infoM moduleName $ "Initial data: " ++ dat

      return gmachine'''

      -- -- allocate space for globals and builtins
      -- res <- runGMachine (replicateM globalCount allocGraphCell) gmachine
      -- when (isLeft res) $ fail (show $ fromLeft res)
      -- let Right (gmachine', globalCells) = res

      -- -- now builtins
      -- res <- runGMachine (replicateM builtinCount allocGraphCell) gmachine'
      -- when (isLeft res) $ fail (show $ fromLeft res)
      -- let Right (gmachine'', builtinCells) = res

      -- -- now write the builtins and globals into the graph
      -- res <- runGMachine (do
      --          -- write globals
      --          forM_ (zip globalCells $ map snd globals) $ uncurry writeGraph
      --          forM_ (zip builtinCells $ map snd builtins) $ uncurry writeGraph) gmachine''
      -- when (isLeft res) $ fail (show $ fromLeft res)
      -- let Right (gmachine''', _) = res
      -- return gmachine

getUserState :: Typeable a => GMachine a
getUserState = do
  dyn <- liftM gmachineUserState get
  return $ fromDyn dyn undefined

pushStack :: GMachineAddress -> GMachine ()
pushStack addr = modify (\state -> state { gmachineStack = addr : (gmachineStack state) })

popStack :: GMachine GMachineAddress
popStack = do
  state <- get
  let ret:newStack = gmachineStack state
  put $ state { gmachineStack = newStack }
  return ret

getStackEntry :: StackOffset -> GMachine GMachineAddress
getStackEntry (StackOffset i) = do
  st <- get
  trace $ "getStackEntry " ++ show i ++ " of " ++ (show $ gmachineStack st)
  return $ (gmachineStack st) !! i

topOfStack :: GMachine GMachineAddress
topOfStack = do
  GMachineState { gmachineStack = x:_ } <- get
  return x

replaceStack :: GMachineStack -> GMachine ()
replaceStack newStack = modify (\state -> state { gmachineStack = newStack })

pushDump :: GMachineStack -> GCodeSequence -> GMachine ()
pushDump newStack newCodeSequence = do
    code <- liftM gmachineCode get
    trace $ "Push dump with code sequence " ++ show newCodeSequence
    trace $ "  On pop, we will be executing " ++ show code
    modify (\state -> state { gmachineStack = newStack, gmachineCode = newCodeSequence,
                              gmachineDump = (gmachineStack state, gmachineCode state):(gmachineDump state),
                              gmachineIndent = 4 + gmachineIndent state})

popDump :: GMachine ()
popDump = do
  (newStack,newCode) <- liftM (head.gmachineDump) get
  trace $ "Popping. Will now execute " ++ show newCode
  modify (\state ->
              let (newStack, newCode):newDump = gmachineDump state
              in
                state { gmachineStack = newStack, gmachineCode = newCode,
                        gmachineDump = newDump,
                        gmachineIndent = (gmachineIndent state) - 4})

gEvaluate :: GMachineAddress -> GMachine ()
gEvaluate a = do
  pushDump [a] [Eval, ProgramDone]
  continue
  popDump

pushInstr :: GCode -> GMachine ()
pushInstr instr = modify (\state -> state { gmachineCode = instr:(gmachineCode state) })

popInstr :: GMachine GCode
popInstr = do
  state <- get
  let ret:newInstrs = gmachineCode state
  put $ state { gmachineCode = newInstrs }
  return ret

replaceInstrs :: GCodeSequence -> GMachine ()
replaceInstrs newCode = modify (\state -> state { gmachineCode = newCode })

allocGraphCell :: GMachine GMachineAddress
allocGraphCell = do
  freeCells <- liftM gmachineFreeCells get
  case IntSet.toList freeCells of
    x:_ -> do
      modify (\state -> state { gmachineFreeCells = IntSet.delete x freeCells })
      return $ GMachineAddress x
    [] -> garbageCollect >> allocGraphCell
  where
    garbageCollect :: GMachine ()
    garbageCollect = do
                   -- Simple mark and sweep garbage collector
                   -- First, collect all reachable points
                   state <- get
                   trace "Garbage collectting..."
                   let reachablePoints = gmachineStack state ++ -- All elements on the stack
                                         (concat $ map fst $ gmachineDump state) ++ -- All elements in the saved stack
                                         (map fst $ gmachineInitData state)
                   allReachablePoints <- liftM (IntSet.fromList . map fromIntegral) $
                                         findReachablePoints reachablePoints

                   (_,upperBound) <- liftIO $ getBounds $ gmachineGraph state
                   let freeCells' = (IntSet.fromList [0..fromIntegral upperBound]) `IntSet.difference` allReachablePoints
                   trace $ "Garbage collection found " ++ (show $ IntSet.size freeCells')
                   trace $ "The roots were: " ++ (show reachablePoints)
                   trace $ "The following cells were used: " ++ show allReachablePoints
                   trace $ "The following are free: " ++ show freeCells'
                   when (IntSet.null freeCells') $ do -- if we couldn't free anything, then bail out
                       throwError "Out of memory"
                   modify (\state -> state { gmachineFreeCells = freeCells' })

findNonReachablePoints :: [GMachineAddress] -> GMachine [GMachineAddress]
findNonReachablePoints pts = do
  reachable <- findReachablePoints pts
  state <- get
  (_, upperBound) <- liftIO $ getBounds $ gmachineGraph state
  let reachableSet = IntSet.fromList $ map fromIntegral reachable
      nonReachable = (IntSet.fromList [0 .. fromIntegral upperBound]) `IntSet.difference` reachableSet
  return $ map fromIntegral $ IntSet.toList nonReachable

findReachablePoints :: [GMachineAddress] -> GMachine [GMachineAddress]
findReachablePoints reachablePoints = do
    let reachablePointSet = IntSet.fromList $ map fromIntegral reachablePoints
    allReachablePoints <- findReachablePoints' reachablePointSet reachablePointSet
    return $ map fromIntegral $ IntSet.toList allReachablePoints
  where
    findReachablePoints' searchSpace accum = do
                   reachablePoints <- liftM concat $ forM (IntSet.toList searchSpace)
                                      (\reachablePointI -> do
                                         dat <- readGraph $ GMachineAddress reachablePointI
                                         return $ map fromIntegral $ AS.elems $ withGenericData constrArgs dat
                                      )
                   let reachablePointsSet = IntSet.fromList reachablePoints
                       accum' = reachablePointsSet `IntSet.union` accum
                   if (IntSet.size accum') == (IntSet.size accum) then
                       return accum'
                    else
                       findReachablePoints' reachablePointsSet accum'

gmachineCheck :: String -> (GMachineState -> Bool) -> GMachine ()
gmachineCheck errorMsg predicate = do
  st <- get
  if predicate st then
      return ()
   else
      throwError errorMsg

step :: GMachine ()
step = do
  instr <- popInstr
  is <- liftM gmachineCode get
  stack <- liftM gmachineStack get
  trace "-------"
  trace $ "Evaluating " ++ show instr ++ " of " ++ show is
  trace $ "    with Stack "
  zip stack <$> mapM readGraph stack >>=
      mapM (\(s, e) -> gshow e >>= \e -> trace ("      " ++ show s ++ ": " ++ e ++ ""))
  waitForStep
  case instr of
    Eval -> doEval
    Unwind -> doUnwind
    Return -> doReturn
    Jump l -> doJump l
    JFalse l -> doJFalse l

    Examine c a offs -> doExamine c a offs

    Push i -> doPush i
    PushInt i -> do
               graphAddr <- allocGraphCell
               writeGraph graphAddr (mkGeneric $ IntConstant i)
               pushStack graphAddr
    PushString s -> do
               graphAddr <- allocGraphCell
               writeGraph graphAddr (mkGeneric $ StringConstant s)
               pushStack graphAddr
    PushDouble d -> do
               graphAddr <- allocGraphCell
               writeGraph graphAddr (mkGeneric $ DoubleConstant d)
               pushStack graphAddr
    PushLocation i -> doPushLocation i
    Pop i -> doPop i
    Slide i -> doSlide i
    Update i -> doUpdate i
    Alloc i -> doAlloc i
    MkAp -> doMkAp

    CallBuiltin -> doCallBuiltin

continue :: GMachine GenericGData
continue = do
  programDone <- checkProgramDone
  if programDone then returnTOS else (step >> continue)
    where checkProgramDone = do
             state <- get
             case gmachineCode state of
               ProgramDone:_ ->
                   do
                     trace $ "Program Done!"
                     popInstr
                     return True
               _ -> return False
          returnTOS = do
             tosAddr <- topOfStack
             readGraph tosAddr

-- | Runtime checks
checkSingleElementStack, checkCodeEmpty :: String -> GMachine ()
checkSingleElementStack error = gmachineCheck error
                                (\st -> case st of
                                          GMachineState { gmachineStack = [_] } -> True
                                          _ -> False)
checkCodeEmpty error = gmachineCheck error
                       (\st -> case st of
                                 GMachineState { gmachineCode = [] } -> True
                                 _ -> False)
checkStackIndex :: StackOffset -> String -> GMachine ()
checkStackIndex (StackOffset index) e = do
  stack <- liftM gmachineStack get
  let stackLength = length stack
  if index >= stackLength then throwError e else return ()

doEval :: GMachine ()
doEval = do
  vAddr <- topOfStack
  vGeneric <- readGraph vAddr
  trace $ "Evaluating " ++ show vGeneric
  usingGenericData vGeneric $
      (\v -> if isBuiltin v then
                 case (asBuiltin v) of
                   Ap v' n -> do
                          popStack
                          pushDump [vAddr] [Unwind]
                   Fun 0 c' -> do
                          popStack
                          pushDump [vAddr] c'
                   BuiltinFun 0 _ _ _ -> do
                          popStack
                          pushDump [vAddr] [CallBuiltin]
                   _ -> return () -- Already evauated to the max
             else return ())

doUnwind :: GMachine ()
doUnwind = do
  vAddr <- topOfStack
  vGeneric <- readGraph vAddr
  trace $ "Unwinding " ++ show vGeneric
  usingGenericData vGeneric $
      (\v ->
           if (isBuiltin v) then
               case asBuiltin v of
                 Ap v' n -> do
                        checkCodeEmpty "In the case of an Ap at the top of stack during Unwind, the remaining code must be empty"

                        -- Check the type of v' to see if it's a valid function type
                        vDataGeneric' <- readGraph v'
                        usingGenericData vDataGeneric' $
                            (\vData' ->
                                 if isBuiltin vData' then
                                     case asBuiltin vData' of
                                       Ap _ _ -> return () -- these are the valid types
                                       Fun _ _ -> return ()
                                       BuiltinFun _ _ _ _-> return ()
                                 else do
                                   d <- gshow vData'
                                   throwError $ "Cannot apply non-function value " ++ d ++ " to arguments"-- invalid type
                            )

                        pushStack v'
                        pushInstr Unwind
                 Fun k c -> callFunction k c
                 BuiltinFun k _ _ _ -> callFunction k [PushLocation vAddr, CallBuiltin]
           else do
             checkSingleElementStack "In the case of a constant at the top of stack during Unwind, the stack must contain only that constant"
             checkCodeEmpty "In the case of a constant at the top of stack during Unwind, the remaining code must be empty"
             popDump
             pushStack vAddr
             c <- liftM gmachineCode get
             trace $ "Still going to execute " ++ show c
      )
  where
    callFunction k c =
        do
          checkCodeEmpty "In the case of a Fun at the top of stack during Unwind, the remaining code must be empty"
          lastStackEntry <- liftM (last . gmachineStack) get -- save this now, just in case
          fnAddr <- popStack -- remove the function node from the top of the stack
          -- See if there are enough arguments for this function

          let countApsAtTopOfStack prevAddr  = do
                stack <- liftM gmachineStack get
                count <- countApsAtTopOfStack' 0 prevAddr stack
                return count

              countApsAtTopOfStack' accum prevAddr (addr:xs) =
                  do
                    vGeneric <- readGraph addr
                    usingGenericData vGeneric $
                        (\v ->
                             if isBuiltin v then
                                 case asBuiltin v of
                                   Ap v n
                                     | v == prevAddr ->
                                         countApsAtTopOfStack' (accum + 1) addr xs
                                     | otherwise -> return accum
                                   _ -> return accum
                             else return accum)
              countApsAtTopOfStack' accum _ [] = return accum

          -- Find how many Ap nodes are at the top of the stack
          tosApCount <- countApsAtTopOfStack fnAddr

          if tosApCount >= k && k >= 1 then
              do
                -- we can apply f
                apAddrs <- replicateM k popStack -- pop all the aps we want off the stack
                aps' <- mapM readGraph apAddrs
                let aps = map (withGenericData asBuiltin) aps'
                pushStack $ last $ apAddrs -- push the address of the last Ap node

                mapM (\(Ap _ n) -> pushStack n) $ reverse aps
                replaceInstrs c
           else do
            popDump
            pushStack lastStackEntry

doReturn :: GMachine ()
doReturn = do
  checkCodeEmpty "Return must not be followed by instructions"
  lastStackElement <- liftM (last.gmachineStack) get
  popDump
  pushStack lastStackElement

doJump, doJFalse :: Label -> GMachine ()
doJump offs = modify (\st -> st { gmachineCode = drop offs $ gmachineCode st })
doJFalse _ = throwError "not implemented"

doExamine :: T.Text -> Int -> Label -> GMachine ()
doExamine expectedName arity offs = do
  vAddr <- topOfStack
  gEvaluate vAddr
  vGeneric <- readGraph vAddr
  let actualName = withGenericData constr vGeneric
      actualArgs = AS.elems $ withGenericData constrArgs vGeneric
      actualArity = length actualArgs

  trace $ "Examining " ++ show actualName ++ " vs " ++ show expectedName
  trace $ " Expected arity " ++ show arity ++ " vs " ++ show actualArity

  when (actualName == expectedName && actualArity == arity) $ do
      popStack -- pull value off of stack
      -- head off to the label
      mapM pushStack actualArgs
      doJump offs

doPush :: StackOffset -> GMachine ()
doPush offset = do
  checkStackIndex offset "Stack not large enough for push"
  x <- getStackEntry offset
  pushStack x

doPushLocation :: GMachineAddress -> GMachine ()
doPushLocation = pushStack

doPop :: StackOffset -> GMachine ()
doPop (StackOffset i) = replicateM_ i popStack

doSlide :: StackOffset -> GMachine ()
doSlide i = do
  sliding <- popStack
  replicateM_ (fromIntegral i) popStack
  pushStack sliding

doUpdate :: StackOffset -> GMachine ()
doUpdate i = do
  checkStackIndex i "Invalid index given to update"
  newLocation <- getStackEntry i
  newValueAddr <- popStack
  newValue <- readGraph newValueAddr
  writeGraph newLocation newValue

doAlloc :: Int -> GMachine ()
doAlloc i = do
  graphCells <- replicateM i allocGraphCell
  mapM_ pushStack graphCells

doMkAp :: GMachine ()
doMkAp = do
  n <- allocGraphCell -- Allocate before popping stack to make sure it knows that n1 and n2 are still reachable
  n1 <- popStack
  n2 <- popStack
  writeGraph n $ mkGeneric $ Ap n1 n2
  pushStack n

doCallBuiltin :: GMachine ()
doCallBuiltin = do
  -- trace "Calling builtin.."
  addr <- popStack
  updateAddr <- liftM (last . gmachineStack) get
  st <- liftM gmachineStack get
  trace $ "Stack " ++ show st
  b@(BuiltinFun arity _ _ (GCodeBuiltin builtin)) <- liftM (withGenericData asBuiltin) $ readGraph addr

  arguments <- replicateM arity popStack
  res <- builtin arguments
  case res of
    Just retval -> do
              writeGraph updateAddr retval -- update
    Nothing -> do -- impure function
             popStack -- get rid of old node so as not to change it
             holeAddr <- allocGraphCell -- TODO: We shouldn't need to allocate each time
             writeGraph holeAddr Hole
             pushStack holeAddr
  pushInstr Unwind

trace :: String -> GMachine ()
trace s = do
  st <- get
  if gmachineDebug st then
      liftIO $ putStrLn $ (replicate (gmachineIndent st) ' ') ++ s
   else return ()

waitForStep :: GMachine ()
waitForStep = do
  st <- get
  let prompt = do
                liftIO $ putStr "(s)tep, (a)bort, (c)ontinue? "
                liftIO $ hFlush stdout
                i <- liftIO $ getLine
                case i of
                  "s" -> liftIO (putStrLn "") >> return ()
                  "a" -> fail "aborted"
                  "c" -> do
                         put st { gmachineTracing = False }
                  "gr" -> do
                         assocs <- liftIO $ getAssocs (gmachineGraph st)
                         forM_ assocs $ \(addr, d) ->
                             case d of
                               Hole -> return ()
                               _ -> do
                                 ds <- gshow d
                                 liftIO $ putStrLn (show addr ++ ": " ++ ds)
                         prompt
                  'd':args -> case reads args of
                                [(addr, "")] -> do
                                                fn <- readGraph (GMachineAddress addr)
                                                if withGenericData isBuiltin fn
                                                then case withGenericData asBuiltin fn of
                                                       Fun arity seq -> prettyPrintFn arity seq >> prompt
                                                       _ -> liftIO (putStrLn "Not a function") >> prompt
                                                else liftIO (putStrLn "Not a builtin type") >> prompt
                                _ -> liftIO (putStrLn "") >> prompt
                  _ -> liftIO (putStrLn "") >> prompt

      prettyPrintFn arity seq = liftIO $ do
                                  let maxDigits = length (show (length seq - 1))

                                      offsLabels = map (printf (concat ["%0", show maxDigits, "d"]) :: Int -> String) [0..]
                                  putStrLn (concat ["Function with ", show arity, " argument(s)"])
                                  forM_ (zip offsLabels seq) $ \(offs, instr) -> do
                                           putStrLn (concat ["    ", offs, ": ", show instr])
                                  return ()
  when (gmachineTracing st) prompt

freezeState :: GMachineState -> IO GMachineFrozenState
freezeState GMachineState {..} = do
  graph <- freeze gmachineGraph
  return GMachineFrozenState {
                         gmachineFrozenStack = gmachineStack,
                         gmachineFrozenGraph = graph // gmachineInitData, -- restore initial data
                         gmachineFrozenCode = gmachineCode,
                         gmachineFrozenDump = gmachineDump,
                         gmachineFrozenInitData = map fst gmachineInitData,
                         gmachineFrozenFreeCells = gmachineFreeCells,
                         gmachineFrozenDebug = gmachineDebug,
                         gmachineFrozenTracing = gmachineTracing}

thawState :: Typeable a => a -> GMachineFrozenState -> IO GMachineState
thawState userSt GMachineFrozenState {..} = do
  ioGraph <- thaw gmachineFrozenGraph
  return GMachineState {
               gmachineStack = gmachineFrozenStack,
               gmachineGraph = ioGraph,
               gmachineCode = gmachineFrozenCode,
               gmachineDump = gmachineFrozenDump,
               gmachineInitData = zip gmachineFrozenInitData $ map (gmachineFrozenGraph !) gmachineFrozenInitData,
               gmachineFreeCells = gmachineFrozenFreeCells,
               gmachineIndent = 0,
               gmachineDebug = gmachineFrozenDebug,
               gmachineTracing = gmachineFrozenTracing,
               gmachineUserState = toDyn userSt,
               gmachineContext = GMachineContext {
                                   gmcModules = Map.empty,
                                   gmcTypes = Map.empty}}