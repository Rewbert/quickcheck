{-# OPTIONS_HADDOCK hide #-}
-- | The main test loop.
{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
#ifndef NO_TYPEABLE
{-# LANGUAGE DeriveDataTypeable #-}
#endif
#ifndef NO_SAFE_HASKELL
{-# LANGUAGE Trustworthy #-}
#endif
module Test.QuickCheck.Test where

--------------------------------------------------------------------------
-- imports

import Test.QuickCheck.Gen
import Test.QuickCheck.Property hiding ( Result( reason, theException, labels, classes, tables ), (.&.), IOException )
import qualified Test.QuickCheck.Property as P
import Test.QuickCheck.Text
import Test.QuickCheck.Exception
import Test.QuickCheck.Random
import System.Random(split)
#if defined(MIN_VERSION_containers)
#if MIN_VERSION_containers(0,5,0)
import qualified Data.Map.Strict as Map
#else
import qualified Data.Map as Map
#endif
#else
import qualified Data.Map as Map
#endif
import qualified Data.Set as Set
import Data.Set(Set)
import Data.Map(Map)
import Data.IORef

import Data.Char
  ( isSpace
  )

import Data.List
  ( sort
  , sortBy
  , group
  , intersperse
  , intercalate
  , zip3
  , zip4
  , zip5
  , zip6
  , partition
  )

import Data.Maybe(fromMaybe, isNothing, isJust, catMaybes)
import Data.Ord(comparing)
import Text.Printf(printf)
import Control.Monad
import Data.Bits

#ifndef NO_TYPEABLE
import Data.Typeable (Typeable)
#endif

import Control.Concurrent
import Control.Exception
import Control.Exception.Base
import Control.Monad.Fix

--------------------------------------------------------------------------
-- quickCheck

-- * Running tests

-- | Args specifies arguments to the QuickCheck driver
data Args
  = Args
  { replay           :: Maybe (QCGen,Int)
    -- ^ Should we replay a previous test?
    -- Note: saving a seed from one version of QuickCheck and
    -- replaying it in another is not supported.
    -- If you want to store a test case permanently you should save
    -- the test case itself.
  , maxSuccess       :: Int
    -- ^ Maximum number of successful tests before succeeding. Testing stops
    -- at the first failure. If all tests are passing and you want to run more tests,
    -- increase this number.
  , maxDiscardRatio  :: Int
    -- ^ Maximum number of discarded tests per successful test before giving up
  , maxSize          :: Int
    -- ^ Size to use for the biggest test cases
  , chatty           :: Bool
    -- ^ Whether to print anything
  , maxShrinks       :: Int
    -- ^ Maximum number of shrinks to before giving up. Setting this to zero
    --   turns shrinking off.
  , numTesters       :: Int
    -- ^ How many concurrent testers to run (uses @forkIO@ internally). A good number to
    --   use is as many as you have physical cores. Hyperthreading does not seem to add
    --   much value.
  , sizeStrategy     :: SizeStrategy
    -- ^ How to compute the number of successful tests so far to use when computing the
    --   size for a test.
  , rightToWorkSteal :: Bool
    -- ^ Should the testers try to steal the right to run more tests from each other if
    --   they run out?
  , parallelShrinking :: Bool
    -- ^ Shrink in parallel? Does nothing if numTesters == 1, and otherwise spawns numTesters
    --   workers.
  , parallelTesting :: Bool
    -- ^ Test in parallel? Default is True, but if you are replaying a seed with multiple cores,
    -- but you want the same counterexample evry time, setting this to False guarantee that
  , boundWorkers :: Bool
    -- ^ Use forkIO or forkOS? True = forkOS, False = forkIO
  }
 deriving ( Show, Read
#ifndef NO_TYPEABLE
  , Typeable
#endif
  )

-- | Result represents the test result
data Result
  -- | A successful test run
  = Success
    { numTests     :: Int
      -- ^ Number of tests performed
    , numDiscarded :: Int
      -- ^ Number of tests skipped
    , labels       :: !(Map [String] Int)
      -- ^ The number of test cases having each combination of labels (see 'label')
    , classes      :: !(Map String Int)
      -- ^ The number of test cases having each class (see 'classify')
    , tables       :: !(Map String (Map String Int))
      -- ^ Data collected by 'tabulate'
    , output       :: String
      -- ^ Printed output
    }
  -- | Given up
  | GaveUp
    { numTests     :: Int
    , numDiscarded :: Int
      -- ^ Number of tests skipped
    , labels       :: !(Map [String] Int)
    , classes      :: !(Map String Int)
    , tables       :: !(Map String (Map String Int))
    , output       :: String
    }
  | Aborted
    { numTests     :: Int
    , numDiscarded :: Int
      -- ^ Number of tests skipped
    , labels       :: !(Map [String] Int)
    , classes      :: !(Map String Int)
    , tables       :: !(Map String (Map String Int))
    , output       :: String
    }
  -- | A failed test run
  | Failure
    { numTests        :: Int
    , numDiscarded    :: Int
      -- ^ Number of tests skipped
    , numShrinks      :: Int
      -- ^ Number of successful shrinking steps performed
    , numShrinkTries  :: Int
      -- ^ Number of unsuccessful shrinking steps performed
    , numShrinkFinal  :: Int
      -- ^ Number of unsuccessful shrinking steps performed since last successful shrink
    , usedSeed        :: QCGen
      -- ^ What seed was used
    , usedSize        :: Int
      -- ^ What was the test size
    , reason          :: String
      -- ^ Why did the property fail
    , theException    :: Maybe AnException
      -- ^ The exception the property threw, if any
    , output          :: String
    , failingTestCase :: [String]
      -- ^ The test case which provoked the failure
    , failingLabels   :: [String]
      -- ^ The test case's labels (see 'label')
    , failingClasses  :: Set String
      -- ^ The test case's classes (see 'classify')
    }
  -- | A property that should have failed did not
  | NoExpectedFailure
    { numTests     :: Int
    , numDiscarded :: Int
      -- ^ Number of tests skipped
    , labels       :: !(Map [String] Int)
    , classes      :: !(Map String Int)
    , tables       :: !(Map String (Map String Int))
    , output       :: String
    }
 deriving ( Show )

-- | Check if the test run result was a success
isSuccess :: Result -> Bool
isSuccess Success{} = True
isSuccess _         = False

isFailure :: Result -> Bool
isFailure Failure{} = True
isFailure _         = False

isGaveUp :: Result -> Bool
isGaveUp GaveUp{} = True
isGaveUp _        = False

isAborted :: Result -> Bool
isAborted Aborted{} = True
isAborted _         = False

isNoExpectedFailure :: Result -> Bool
isNoExpectedFailure NoExpectedFailure{} = True
isNoExpectedFailure _                   = False

-- | The default test arguments
stdArgs :: Args
stdArgs = Args
  { replay            = Nothing
  , maxSuccess        = 100
  , maxDiscardRatio   = 10
  , maxSize           = 100
  , chatty            = True
  , maxShrinks        = maxBound
  , numTesters        = 1
  , sizeStrategy      = Stride
  , rightToWorkSteal  = True
  , parallelShrinking = False
  , parallelTesting   = True
  , boundWorkers      = False
  }

quickCheckPar' :: (Int -> IO a) -> IO a
quickCheckPar' test = do
  numHECs <- getNumCapabilities
  if numHECs == 1
    then do putStr warning
            test numHECs
    else test numHECs
  where
    warning :: String
    warning = unlines [ "[WARNING] You have requested parallel testing, but there appears to only be one HEC available"
                      , "[WARNING] please recompile with these ghc options"
                      , "[WARNING]   -threaded -feager-blackholing -rtsopts"
                      , "[WARNING] and run your program with this runtime flag"
                      , "[WARNING]   -N[x]"
                      , "[WARNING] where x indicates the number of workers you want"]

{- | Run a property in parallel. This is done by distributing the total number of tests
over all available HECs. If only one HEC is available, it reverts to the sequential
testing framework. -}
quickCheckPar :: Testable prop => prop -> IO ()
quickCheckPar p = quickCheckPar' $ \numhecs ->
  quickCheckInternal (stdArgs { numTesters = numhecs, parallelShrinking = True, parallelTesting = True }) p >> return ()
  -- do
  -- numHecs <- getNumCapabilities
  -- if numHecs == 1
  --   then do putStrLn $ concat [ "quickCheckPar called, but only one HEC available -- "
  --                             , "testing will be sequential..."
  --                             ]
  --           quickCheck p
  --   else quickCheckInternal (stdArgs { numTesters = numHECs }) p >> return ()

-- | The parallel version of `quickCheckWith`
quickCheckParWith :: Testable prop => Args -> prop -> IO ()
quickCheckParWith a p = quickCheckPar' $ \numhecs ->
  quickCheckInternal (a { numTesters = numhecs }) p >> return ()
  --quickCheckInternal a pa p >> return ()

-- -- | The parallel version of `quickCheckResult`
quickCheckParResult :: Testable prop => prop -> IO Result
quickCheckParResult p = quickCheckPar' $ \numhecs ->
  quickCheckInternal (stdArgs { numTesters = numhecs }) p
-- quickCheckParResult p = quickCheckInternal stdArgs stdParArgs p

-- -- | The parallel version of `quickCheckWithResult`
quickCheckParWithResult :: Testable prop => Args -> prop -> IO Result
quickCheckParWithResult a p = quickCheckPar' $ \numhecs ->
  quickCheckInternal (a { numTesters = numhecs }) p
  --quickCheckInternal a pa p

-- | Tests a property and prints the results to 'stdout'.
--
-- By default up to 100 tests are performed, which may not be enough
-- to find all bugs. To run more tests, use 'withMaxSuccess'.
--
-- If you want to get the counterexample as a Haskell value,
-- rather than just printing it, try the
-- <http://hackage.haskell.org/package/quickcheck-with-counterexamples quickcheck-with-counterexamples>
-- package.
quickCheck :: Testable prop => prop -> IO ()
quickCheck p = quickCheckWith stdArgs p

-- | Tests a property, using test arguments, and prints the results to 'stdout'.
quickCheckWith :: Testable prop => Args -> prop -> IO ()
quickCheckWith args p = quickCheckInternal args p >> return ()

-- | Tests a property, produces a test result, and prints the results to 'stdout'.
quickCheckResult :: Testable prop => prop -> IO Result
quickCheckResult p = quickCheckInternal stdArgs p

-- | Tests a property, produces a test result, and prints the results to 'stdout'.
quickCheckWithResult :: Testable prop => Args -> prop -> IO Result
quickCheckWithResult args p = quickCheckInternal args p

-- | Tests a property and prints the results and all test cases generated to 'stdout'.
-- This is just a convenience function that means the same as @'quickCheck' . 'verbose'@.
--
-- Note: for technical reasons, the test case is printed out /after/
-- the property is tested. To debug a property that goes into an
-- infinite loop, use 'within' to add a timeout instead.
verboseCheck :: Testable prop => prop -> IO ()
verboseCheck p = quickCheck (verbose p)

-- | Tests a property, using test arguments, and prints the results and all test cases generated to 'stdout'.
-- This is just a convenience function that combines 'quickCheckWith' and 'verbose'.
--
-- Note: for technical reasons, the test case is printed out /after/
-- the property is tested. To debug a property that goes into an
-- infinite loop, use 'within' to add a timeout instead.
verboseCheckWith :: Testable prop => Args -> prop -> IO ()
verboseCheckWith args p = quickCheckWith args (verbose p)

-- | Tests a property, produces a test result, and prints the results and all test cases generated to 'stdout'.
-- This is just a convenience function that combines 'quickCheckResult' and 'verbose'.
--
-- Note: for technical reasons, the test case is printed out /after/
-- the property is tested. To debug a property that goes into an
-- infinite loop, use 'within' to add a timeout instead.
verboseCheckResult :: Testable prop => prop -> IO Result
verboseCheckResult p = quickCheckResult (verbose p)

-- | Tests a property, using test arguments, produces a test result, and prints the results and all test cases generated to 'stdout'.
-- This is just a convenience function that combines 'quickCheckWithResult' and 'verbose'.
--
-- Note: for technical reasons, the test case is printed out /after/
-- the property is tested. To debug a property that goes into an
-- infinite loop, use 'within' to add a timeout instead.
verboseCheckWithResult :: Testable prop => Args -> prop -> IO Result
verboseCheckWithResult a p = quickCheckWithResult a (verbose p)

-- new testloop

-- | A 'message' of type TesterSignal will be communicated to the main thread by the concurrent
-- testers when testing is terminated
data TesterSignal
  = KillTesters ThreadId State QCGen P.Result [Rose P.Result] Int
  -- | A counterexample was found, and a killsignal should be sent to all concurrent testers
  | FinishedTesting
  -- | All tests were successfully executed
  | NoMoreDiscardBudget ThreadId
  -- | There is no more allowance to discard tests, so we should give up
  | Interrupted
  -- | User pressed CTRL-C (TODO: probably remove this)

-- | Tests a property, using test arguments, produces a test result, and prints the results to 'stdout'.
quickCheckInternal :: Testable prop => Args -> prop -> IO Result
quickCheckInternal a p = do
      -- either reuse the supplied seed, or generate a new one
      rnd <- case replay a of
               Nothing      -> newQCGen
               Just (rnd,_) -> return rnd

      let numtesters = if parallelTesting a then numTesters a else 1
      let numShrinkers = if parallelShrinking a then numTesters a else 1

      {- initial seeds for each tester. The original seed will be split like this:
                     rnd
                    /   \
                   r1    _
                  /     / \
                 r2    _    _
                /     / \  / \
               r3    _   __   _
              /
            ...
      The initial seeds for each tester will be [rnd,r1,r2,r3,...].

      This may look bad, as there is a clear relationship between them. However, during testing,
      the seed to use for each test case is acquired by splitting the seed like this

                rnd
               /   \
              _    s1
                  /  \
                 s2   _
      
      s1 will be used for the current test-case, and s2 will be fed into the next iteration of the loop
      i.e. it will take the role of rnd above
      Hopefully this yields good enough distribution of seeds
            -}
      let initialSeeds = snd $ foldr (\_ (rnd, a) -> let (r1,_) = split rnd
                                                     in (r1, a ++ [rnd]))
                                     (rnd, [])
                                     [0..numtesters - 1]

      -- how big to make each testers buffer
      let numTestsPerTester = maxSuccess a `div` numtesters

      -- returns a list indicating how many tests each tester can run, what their offset for size computation is, and how many
      -- tests they can discard
      let testsoffsetsanddiscards = snd $
            foldr (\_ ((numtests, offset, numdiscards), acc) ->
                      ((numTestsPerTester, offset+numtests, numTestsPerTester * maxDiscardRatio a), acc ++ [(numtests, offset, numdiscards)]))
                  (( numTestsPerTester + (maxSuccess a `rem` numtesters)
                   , 0
                   , numTestsPerTester * maxDiscardRatio a + ((maxSuccess a `rem` numtesters) * maxDiscardRatio a) 
                   ), [])
                  [0..numtesters - 1]

      -- the MVars that holds the test budget for each tester
      testbudgets <- sequence $ replicate numtesters (newIORef 0)

      -- the MVars that hold each testers discard budget
      budgets <- sequence $ replicate numtesters (newIORef 0)

      -- the MVars that hold each testers state
      states <- sequence $ replicate numtesters newEmptyMVar

      -- the components making up a tester
      -- lol zip6
      let testerinfo = zip6 states initialSeeds [0..numtesters - 1] testbudgets budgets testsoffsetsanddiscards
        
          -- this function tries to steal budget from an MVar Int, if any budget remains.
          -- used for stealing test budgets and discard budgets.
          tryStealBudget [] = return Nothing
          tryStealBudget (b:bs) = do
            v <- claimMoreBudget b 1
            case v of
              Nothing -> tryStealBudget bs
              Just n  -> return $ Just n

      -- parent thread will block on this mvar. When it is unblocked, testing should terminate
      signal <- newEmptyMVar
      numrunning <- newIORef numtesters

      -- initialize the states of each tester
      flip mapM_ testerinfo $ \(st, seed, testerID, tbudget, dbudget, (numtests, testoffset, numdiscards)) -> do
            mask_ $ (if chatty a then withStdioTerminal else withNullTerminal) $ \tm -> do 
              writeIORef tbudget (numtests - 1)
              writeIORef dbudget (numdiscards - 1)
              putMVar st $ (MkState { terminal           = tm
                                    , maxSuccessTests    = maxSuccess a
                                    , coverageConfidence = Nothing
                                    , maxDiscardedRatio  = maxDiscardRatio a
                                    , replayStartSize           = snd <$> replay a
                                    , maxTestSize               = maxSize a
                                    , numTotMaxShrinks          = maxShrinks a
                                    , numSuccessTests           = 0
                                    , numDiscardedTests         = 0
                                    , numRecentlyDiscardedTests = 0
                                    , stlabels                = Map.empty
                                    , stclasses               = Map.empty
                                    , sttables                = Map.empty
                                    , strequiredCoverage      = Map.empty
                                    , expected                  = True
                                    , randomSeed                = seed
                                    , numSuccessShrinks         = 0
                                    , numTryShrinks             = 0
                                    , numTotTryShrinks          = 0
           
                                    -- new
                                    -- there is a lot of callbacks here etc
                                    , testBudget                = tbudget
                                    , stealTests                = if rightToWorkSteal a
                                                                    then tryStealBudget $ filter ((/=) tbudget) testbudgets
                                                                    else return Nothing
                                    , numConcurrent             = numtesters
                                    , numSuccessOffset          = testoffset
                                    , discardBudget             = dbudget
                                    , stealDiscards             = if rightToWorkSteal a
                                                                    then tryStealBudget $ filter ((/=) dbudget) budgets
                                                                    else return Nothing
                                    , myId                      = testerID
                                    , signalGaveUp              = myThreadId >>= \id -> tryPutMVar signal (NoMoreDiscardBudget id) >> return()
                                    , signalTerminating         = do b <- atomicModifyIORef' numrunning $ \i -> (i-1, i-1 == 0)
                                                                     if b
                                                                      then tryPutMVar signal FinishedTesting >> return ()
                                                                      else return ()
                                    , signalFailureFound = \st seed res ts size -> do tid <- myThreadId
                                                                                      tryPutMVar signal (KillTesters tid st seed res ts size)
                                                                                      return ()
                                    , shouldUpdateAfterWithStar = True
                                    , stsizeStrategy            = sizeStrategy a
                                    })

      -- continuously print current state
      printerID <- if chatty a then Just <$> forkIO (withBuffering $ printer 200 states) else return Nothing

      -- the IO actions that run the test loops      
      let testers = map (\vst -> testLoop vst True (property p)) states

      -- spawn testers
      tids <- if numtesters > 1
                then let fork = if boundWorkers a then forkOS else forkIO
                     in zipWithM (\comp vst -> fork comp) testers states
                else do head testers >> return [] -- if only one worker, let the main thread run the tests

      -- wait for wakeup
      s <- readMVar signal `catch` (\UserInterrupt -> return Interrupted) -- catching Ctrl-C, Nick thinks this is bad, as users might have their own handlers
      mt <- case s of
        Interrupted -> mapM_ (\tid -> throwTo tid QCInterrupted) tids >> mapM_ killThread tids >> return Nothing
        KillTesters tid st seed res ts size -> do mapM_ (\tid -> throwTo tid QCInterrupted >> killThread tid) (filter ((/=) tid) tids)
                                                  return $ Just tid
        FinishedTesting -> return Nothing
        NoMoreDiscardBudget tid -> do mapM_ killThread (filter ((/=) tid) tids)
                                      return $ Just tid

      -- stop printing current progress
      case printerID of
        Just id -> killThread id
        Nothing -> return ()

      -- get report depending on what happened
      reports <- case s of
        KillTesters tid st seed res ts size -> do
          -- mvar states of all testers that are are aborted
          let abortedvsts = map snd $ filter (\(tid', _) -> tid /= tid') (zip tids states)
          -- read the states from those mvars
          abortedsts <- mapM readMVar abortedvsts
          -- complete number of tests that were run over all testers
          let  numsucc = numSuccessTests st + sum (map numSuccessTests abortedsts)
          failed <- withBuffering $ shrinkResult (chatty a) st numsucc seed numShrinkers res ts size -- shrink and return report from failed
          aborted <- mapM abortConcurrent abortedsts -- reports from aborted testers
          return (failed : aborted)
        NoMoreDiscardBudget tid          -> mapM (\vst -> readMVar vst >>= flip giveUp (property p)) states
        FinishedTesting                  -> mapM (\vst -> readMVar vst >>= flip doneTesting (property p)) states
        Interrupted                      -> mapM (\vst -> readMVar vst >>= abortConcurrent) states

      -- compute the required coverage (if any), and merge the individual tester reports
      sts <- mapM readMVar states
      let completeRequiredCoverage = Map.unionsWith max (map strequiredCoverage sts)
          finalReport              = mergeReports reports

      -- output the final outcome to the terminal, clearing the line before a new print is emitted
      putPart (terminal (head sts)) ""
      printFinal (terminal (head sts)) finalReport sts (coverageConfidence (head sts)) completeRequiredCoverage

      -- finally, return the report!
      return $ mergeReports reports

{-
See the function testLoop to see how we take replaying into account

          maxSuccessTests
                | maxTestSize
                |     maxDiscardedRation
                |      |      |numSuccessTests
                |      |      |      | numRecentlyDiscarded
                v      v      v      v      v                   -}
computeSize :: Int -> Int -> Int -> Int -> Int -> Int
computeSize ms mts md n d
    -- e.g. with maxSuccess = 250, maxSize = 100, goes like this:
    -- 0, 1, 2, ..., 99, 0, 1, 2, ..., 99, 0, 2, 4, ..., 98.
    | n `roundTo` mts + mts <= ms ||
      n >= ms ||
      ms `mod` mts == 0 = (n `mod` mts + d `div` dDenom) `min` mts
    | otherwise =
      ((n `mod` mts) * mts `div` (ms `mod` mts) + d `div` dDenom) `min` mts
  where
    -- The inverse of the rate at which we increase size as a function of discarded tests
    -- if the discard ratio is high we can afford this to be slow, but if the discard ratio
    -- is low we risk bowing out too early
    dDenom
      | md > 0 = (ms * md `div` 3) `clamp` (1, 10)
      | otherwise = 1 -- Doesn't matter because there will be no discards allowed
    n `roundTo` m = (n `div` m) * m

clamp :: Ord a => a -> (a, a) -> a
clamp x (l, h) = max l (min x h)

-- | Merge every individual testers report into one report containing the composite information.
mergeReports :: [Result] -> Result
mergeReports rs
  | not (null (filter isFailure rs)) =
      createFailed (filter (not . isFailure) rs) (head (filter isFailure rs))
  | null (filter (not . isSuccess) rs)           = createGeneric rs Success
  | null (filter (not . isGaveUp) rs)            = createGeneric rs GaveUp
  | null (filter (not . isAborted) rs)           = createGeneric rs Aborted
  | null (filter (not . isNoExpectedFailure) rs) = createGeneric rs NoExpectedFailure
  | otherwise = error $ concat ["don't know how to merge reports: ", intercalate "\n" $ map show rs]
  where
    -- | create a Result value by passing in a constructor as a parameter to this function
    createGeneric :: [Result]
                  -> (  Int
                     -> Int
                     -> Map [String] Int
                     -> Map String Int
                     -> Map String (Map String Int)
                     -> String
                     -> Result)
                  -> Result
    createGeneric rs f = f (sum $ map numTests rs)
                           (sum $ map numDiscarded rs)
                           (Map.unionsWith (+) $ map labels rs)
                           (Map.unionsWith (+) $ map classes rs)
                           (Map.unionsWith (Map.unionWith (+)) $ map tables rs)
                           (intercalate "\n" $ map output rs)

    {- | create a Result that indicates a failure happened
    NOTE: in this case, the labels and tables are dropped and not reported to the user. -}
    createFailed :: [Result] -> Result -> Result
    createFailed rs f = f { numTests     = sum $ map numTests (f:rs)
                          , numDiscarded = sum $ map numDiscarded (f:rs)
                          , output       = intercalate "\n" $ map output rs
                          }

{- | Given a ref with more budget (either test budget or discard budget), try to claim
- at most @maxchunk@ from it. -}
claimMoreBudget :: IORef Int -> Int -> IO (Maybe Int)
claimMoreBudget budgetioref maxchunk = do
  atomicModifyIORef' budgetioref $ \budget ->
    if budget <= 0
      then (0, Nothing)
      else let chunk = min budget maxchunk
           in (max 0 (budget - chunk), Just chunk)

{- | Update the state in an mvar with a new state.
NOTE: interrupts are masked during the actual update, so that if updatestate
begins evaluation, it will always be allowed to finish. -}
updateState :: MVar State -> State -> IO ()
updateState vst st = do
  modifyMVar_ vst $ \_ -> return st

-- TODO merge runOneMore and continueAfterDiscard into one function, they are identical with the
-- exception of the actual MVar and the stealing function

{- | Given a state, returns @True@ if another test should be executed, and @False@ if not.
If a specific tester thread has run out of testing 'budget', it will try to steal the
right to run more tests from other testers. -}
runOneMore :: State -> IO Bool
runOneMore st = do
  b <- claimMoreBudget (testBudget st) 1
  case b of
    Just _  -> return True
    Nothing -> do n <- stealTests st
                  case n of
                    Nothing -> return False
                    Just _  -> return True

{- | After a test has been discarded, calling this function will let the tester know if
it should stop trying to satisfy the test predicate, or if it should continue. If it has
run out of testing budget, it will try to steal the right to discard more from other
testers. -}
continueAfterDiscard :: State -> IO Bool
continueAfterDiscard st = do
  b <- claimMoreBudget (discardBudget st) 1
  case b of
    Just _ -> return True
    Nothing -> do n <- stealDiscards st
                  case n of
                    Nothing -> return False
                    Just _ -> return True

{- | The actual testing loop that each tester runs. TODO document more-}
testLoop :: MVar State -> Bool -> Property -> IO ()
testLoop vst False f = do
  st <- readMVar vst
  b <- runOneMore st
  if b
    then testLoop vst True f
    else signalTerminating st
testLoop vst True f = do
  st <- readMVar vst
  let (_,s2) = split (randomSeed st)
      (s1,_) = split s2
      numSuccSize = testSizeInput st
  res@(MkRose r ts) <- runTest st f s1 (size st)
  let (classification, st') = resultOf res st
      st''                  = st' { randomSeed = s2 }
  finst <- maybeUpdateAfterWithMaxSuccess res st''
  case classification of
    -- test was successful!
    OK | abort r -> updateState vst (updateStateAfterResult res finst) >> signalTerminating finst
    OK -> do
      updateState vst (updateStateAfterResult res finst)
      testLoop vst False f
    -- test was discarded, and we're out of discarded budget
    -- do not keep coverage information for discarded tests
    Discarded | abort r -> updateState vst finst >> signalTerminating finst
    Discarded -> do
      b <- continueAfterDiscard st -- should we keep going?
      if b
        then updateState vst finst >> testLoop vst True f
        else updateState vst finst >> signalGaveUp finst
    
    -- test failed, and we should abort concurrent testers and start shrinking the result
    Failed ->
      signalFailureFound st' st' (randomSeed st) r ts (size st)
  where
    -- | Compute the numSuccess-parameter to feed to the @computeSize@ function
    -- NOTE: if there is a size to replay, the computed size is offset by that much to make sure
    -- that we explore it first. In the parallel case we will explore the sizes [replay, replay+1, ...] etc,
    -- so we might actually end up with another counterexample. We are, however, guaranteed that one thread
    -- is going to explore the replayed size and seed.
    testSizeInput :: State -> Int
    testSizeInput st = case stsizeStrategy st of
      Offset -> (fromMaybe 0 (replayStartSize st)) + numSuccessOffset st + numSuccessTests st
      Stride -> (fromMaybe 0 (replayStartSize st)) + numSuccessTests st * numConcurrent st + myId st
    
    size :: State -> Int
    size st = computeSize (maxSuccessTests st)
                          (maxTestSize st)
                          (maxDiscardedRatio st)
                          (testSizeInput st)
                          (numRecentlyDiscardedTests st)

{- | Printing loop. It will read the current test state from the list of @MVar State@,
and print a summary to the terminal. It will do this every @delay@ microseconds.
NOTE: while the actual print is happening, interruptions are masked. This is so that if
the printer is terminated mid-print, the terminal is in an allowed state. -}
printer :: Int -> [MVar State] -> IO ()
printer delay vsts = do
  mask_ printStuff
  threadDelay delay
  printer delay vsts
  where
    -- | Does the actual compiling of the states and printing it to the terminal
    printStuff :: IO ()
    printStuff = do
      states <- sequence $ map readMVar vsts
      putTemp (terminal (head states)) ( concat ["(", summary states, ")"] )
      where
        summary states =
          number (sum (map numSuccessTests states)) "test" ++
          concat [ "; " ++ show (sum (map numDiscardedTests states)) ++ " discarded"
                 | sum (map numDiscardedTests states) > 0
                 ]

{- | This function inspects the final @Result@ of testing and prints a summary to the
terminal. The parameters to this function are

  1. The terminal to which to print
  2. The final @Result@ value
  3. The coverage confidence, if any
  4. The required coverage, if any (the map might be empty)

If @isFailure r = True@, where @r@ is the final @Result@, this function is a no-op.

-}
printFinal :: Terminal -> Result -> [State] -> Maybe Confidence -> Map.Map (Maybe String, String) Double -> IO ()
printFinal terminal r states coverageConfidence requiredCoverage
  | isSuccess r           = do
    putLine terminal ("+++ OK, passed " ++ testCount (numTests r) (numDiscarded r))
    individualTester
    printTheLabelsAndTables
  | isFailure r           = return ()
  | isGaveUp r            = do
    putLine terminal ( bold ("*** Gave up!") ++ " Passed only " ++ testCount (numTests r) (numDiscarded r) ++ " tests")
    individualTester
    printTheLabelsAndTables
  | isAborted r           = do
    putLine terminal ( bold ("*** Aborted prematurely!") ++ " Passed " ++ testCount (numTests r) (numDiscarded r) ++ " before interrupted")
    individualTester
    printTheLabelsAndTables
  | isNoExpectedFailure r = do
    putLine terminal ( bold ("*** Failed!") ++ " Passed " ++ testCount (numTests r) (numDiscarded r) ++ " (expected failure")
    individualTester
    printTheLabelsAndTables
  where
    -- | print the information collected via labels, tabels, coverage etc
    printTheLabelsAndTables :: IO ()
    printTheLabelsAndTables = do
      mapM_ (putLine terminal) (paragraphs [short, long])
    
    (short,long) = case labelsAndTables (labels r) (classes r) (tables r) requiredCoverage (numTests r) coverageConfidence of
      ([msg], long) -> ([" (" ++ dropWhile isSpace msg ++ ")."], long)
      ([], long)    -> ([], long)
      (short, long) -> (":":short, long)

    -- | Final count of successful tests, and discarded tests, rendered as a string
    testCount :: Int -> Int -> String
    testCount numTests numDiscarded =
      concat [ number numTests "test"
             , if numDiscarded > 0
                 then concat ["; ", show numDiscarded, " discarded"]
                 else ""
             ]
    
    individualTester :: IO ()
    individualTester =
      if length states > 1
        then mapM_ (\st -> putLine terminal $ concat ["  tester ", show (myId st), ": ", testCount (numSuccessTests st) (numDiscardedTests st)]) states
        else return ()

{- | This function will shrink the result of a failed test case (if possible), and then
return a final report. The parameters are

  1. The state associated with this test case
  2. The random seed used to generate the failing test case
  3. The result of running the failing test case
  4. The shrinking candidates
  5. The size fed to the test case

-}
shrinkResult :: Bool -> State -> Int -> QCGen -> Int -> P.Result -> [Rose P.Result] -> Int -> IO Result
shrinkResult chatty st numsucc rs n res ts size = do
  (numShrinks, totFailed, lastFailed, res) <- foundFailure chatty st numsucc n res ts
  theOutput <- terminalOutput (terminal st)
  if not (expect res) then
    return Success{ labels       = stlabels st,
                    classes      = stclasses st,
                    tables       = sttables st,
                    numTests     = numSuccessTests st+1,
                    numDiscarded = numDiscardedTests st,
                    output       = theOutput }
   else do
    testCase <- mapM showCounterexample (P.testCase res)
    return Failure{ usedSeed        = rs
                  , usedSize        = size
                  , numTests        = numSuccessTests st+1
                  , numDiscarded    = numDiscardedTests st
                  , numShrinks      = numShrinks
                  , numShrinkTries  = totFailed
                  , numShrinkFinal  = lastFailed
                  , output          = theOutput
                  , reason          = P.reason res
                  , theException    = P.theException res
                  , failingTestCase = testCase
                  , failingLabels   = P.labels res
                  , failingClasses  = Set.fromList (map fst $ filter snd $ P.classes res)
                  }

{- | Inspect the result of running a test, and return the next action to take as well as
an updated state. The parts of the state that might be updated are

  * @numSuccessTests@
  * @numRecentlyDiscardedTests@
  * @numDiscardedTests@

-}
resultOf :: Rose P.Result -> State -> (TestRes, State)
resultOf (MkRose res _) st
  -- successful test
  | ok res == Just True =
             ( OK
             , st { numSuccessTests           = numSuccessTests st + 1
                  , numRecentlyDiscardedTests = 0
                  }
             )
  -- discarded test
  | ok res == Nothing =
             ( Discarded
             , st { numDiscardedTests         = numDiscardedTests st + 1
                  , numRecentlyDiscardedTests = numRecentlyDiscardedTests st + 1
                  }
             )
  -- failed test
  | ok res == Just False = (Failed, st)

-- | The result of running a test
data TestRes
  = OK
  -- ^ The test was OK (successful)
  | Failed
  -- ^ The test failed
  | Discarded
  -- ^ The test was discarded, as it did not meet one of the preconditions

{- | Some test settings are attached to the property rather than the testing arguments,
and will thus only be visible after running a test. This function takes the @Rose Result@
of running a test and the @State@ associated with that test, and updates the state with
information about such settings. Settings affected are

  * @coverageConfidence@
  * @labels@
  * @classes@
  * @tables@
  * @requiredCoverage@ -- what are the coverage requirements?
  * @expected@ -- should the test fail?

-}
updateStateAfterResult :: Rose P.Result -> State -> State
updateStateAfterResult (MkRose res ts) st =
  st { coverageConfidence = maybeCheckCoverage res `mplus` coverageConfidence st
     , stlabels = Map.insertWith (+) (P.labels res) 1 (stlabels st)
     , stclasses = Map.unionWith (+) (stclasses st) (Map.fromList [ (s, if b then 1 else 0) | (s, b) <- P.classes res ])
     , sttables = foldr (\(tab, x) -> Map.insertWith (Map.unionWith (+)) tab (Map.singleton x 1))
                     (sttables st) (P.tables res)
     , strequiredCoverage = foldr (\(key, value, p) -> Map.insertWith max (key, value) p)
                     (strequiredCoverage st) (P.requiredCoverage res)
     , expected = expect res
     }

{- | A property might specify that a specific number of tests should be run (@withMaxSuccess@
 and/or that we should use a custom discard ratio when (@withDiscardRatio@). This function
will detect that and recompute the testing/discard budget and update them accordingly.
It will also set a flag in the state that makes it so that this stuff computed only once. -}
maybeUpdateAfterWithMaxSuccess :: Rose P.Result -> State -> IO State
maybeUpdateAfterWithMaxSuccess (MkRose res ts) st = do
  case (maybeNumTests res, maybeDiscardedRatio res) of
    (Nothing, Nothing) -> return st
    (mnt, mdr) ->
      if shouldUpdateAfterWithStar st
        then updateState (fromMaybe (maxSuccessTests st) mnt) (fromMaybe (maxDiscardedRatio st) mdr) st
        else return st
  where
    updateState :: Int -> Int -> State -> IO State
    updateState numTests' maxDiscarded' st = do
      let numTestsPerTester    =
            if myId st == 0
              then numTests' `div` numConcurrent st + (numTests' `rem` numConcurrent st)
              else numTests' `div` numConcurrent st

          newSuccessOffset     =
            if myId st == 0
              then 0
              else numTestsPerTester * myId st + (numTests' `rem` numConcurrent st)

          numDiscardsPerTester = numTestsPerTester * maxDiscarded'

      atomicModifyIORef' (testBudget st) $ \remainingbudget ->
        let newbudget = numTestsPerTester - 1 in (newbudget, ())
        
      atomicModifyIORef' (discardBudget st) $ \remainingbudget ->
        let newbudget = numDiscardsPerTester - 1 in (newbudget, ())

      return $ st { maxSuccessTests           = numTests'
                  , numSuccessOffset          = newSuccessOffset
                  , maxDiscardedRatio         = maxDiscarded'
                  , shouldUpdateAfterWithStar = False
                  }

-- | Run a test
{- | This function will generate and run a test case! The parameters are:

  1. The current @State@ of the tester responsible for running the test
  2. The property to test
  3. The random seed to use
  4. The size to use

-}
runTest :: State -> Property -> QCGen -> Int -> IO (Rose P.Result)
runTest st f seed size = do
  let f_or_cov = case coverageConfidence st of
                   Just confidence | confidenceTest -> addCoverageCheck
                                                         (stlabels st)
                                                         (stclasses st)
                                                         (sttables st)
                                                         (strequiredCoverage st)
                                                         (numSuccessTests st)
                                                         confidence
                                                         f
                   _                                -> f
  MkRose res ts <- protectRose (reduceRose (unProp (unGen (unProperty f_or_cov) seed size)))
  res <- callbackPostTest st res
  return (MkRose res ts)
  where
    powerOfTwo :: (Integral a, Bits a) => a -> Bool
    powerOfTwo n = n .&. (n - 1) == 0

    confidenceTest :: Bool
    confidenceTest = (1 + numSuccessTests st) `mod` 100 == 0 && powerOfTwo ((1 + numSuccessTests st) `div` 100)

{- | If a tester terminates without falsifying a property, this function converts the
testers @State@ to a @Result@ -}
doneTesting :: State -> Property -> IO Result
doneTesting st _f
  | expected st == False = do
      finished NoExpectedFailure
  | otherwise = do
      finished Success
  where
    finished k = do
      theOutput <- terminalOutput (terminal st)
      return (k (numSuccessTests st) (numDiscardedTests st) (stlabels st) (stclasses st) (sttables st) theOutput)

{- | If a tester terminates because it discarded too many test cases, this function
converts the testers @State@ to a @Result@ -}
giveUp :: State -> Property -> IO Result
giveUp st _f = do -- CALLBACK gave_up?
     theOutput <- terminalOutput (terminal st)
     return GaveUp{ numTests     = numSuccessTests st
                  , numDiscarded = numDiscardedTests st
                  , labels       = stlabels st
                  , classes      = stclasses st
                  , tables       = sttables st
                  , output       = theOutput
                  }

{- | If a tester terminates because it was aborted by the parent thread, this function
converts the testers @State@ to a @Result@ -}
abortConcurrent :: State -> IO Result
abortConcurrent st = do
     theOutput <- terminalOutput (terminal st)
     return Aborted{ numTests     = numSuccessTests st
                   , numDiscarded = numDiscardedTests st
                   , labels       = stlabels st
                   , classes      = stclasses st
                   , tables       = sttables st
                   , output       = theOutput
                   }

labelsAndTables :: Map.Map [String] Int
                 -> Map.Map String Int
                 -> Map.Map String (Map.Map String Int)
                 -> Map.Map (Maybe String, String) Double
                 -> Int -> Maybe Confidence
                 -> ([String], [String])
labelsAndTables labels classes tables requiredCoverage numTests coverageConfidence = (theLabels, theTables)
  where
    theLabels :: [String]
    theLabels =
      paragraphs $
        [showTable numTests Nothing m
        | m <- classes : Map.elems numberedLabels
        ]

    numberedLabels :: Map.Map Int (Map.Map String Int)
    numberedLabels =
      Map.fromListWith (Map.unionWith (+)) $
        [ (i, Map.singleton l n)
        | (labels, n) <- Map.toList labels
        , (i,l) <- zip [0..] labels
        ]

    theTables :: [String]
    theTables =
      paragraphs $
        [ showTable (sum (Map.elems m)) (Just table) m
        | (table, m) <- Map.toList tables
        ] ++
        [[ (case mtable of Nothing -> "Only"; Just table -> "Table '" ++ table ++ "' had only ")
         ++ lpercent n tot ++ " " ++ label ++ ", but expected " ++ lpercentage p tot
         | (mtable, label, tot, n, p) <- allCoverage classes tables requiredCoverage numTests,
         insufficientlyCovered (fmap certainty coverageConfidence) tot n p ]] -- TODO here

showTable :: Int -> Maybe String -> Map String Int -> [String]
showTable k mtable m =
  [table ++ " " ++ total ++ ":" | Just table <- [mtable]] ++
  (map format .
   -- Descending order of occurrences
   reverse . sortBy (comparing snd) .
   -- If #occurences the same, sort in increasing order of key
   -- (note: works because sortBy is stable)
   reverse . sortBy (comparing fst) $ Map.toList m)
  where
    format (key, v) =
      rpercent v k ++ " " ++ key

    total = printf "(%d in total)" k

--------------------------------------------------------------------------
-- main shrinking loop

foundFailure :: Bool -> State -> Int -> Int -> P.Result -> [Rose P.Result] -> IO (Int, Int, Int, P.Result)
foundFailure chatty st numsucc n res ts = do
  re@(n1,n2,n3,r) <- shrinker chatty st numsucc n res ts
  sequence_ [ putLine (terminal st) msg | msg <- snd $ failureSummaryAndReason2 (n1, n2, n3) numsucc r ]
  callbackPostFinalFailure st r
  return re

-- | State kept during shrinking, will live in an MVar to make all shrinkers able to modify it
-- NOTE: Having one shared resource like this can lead to contention -- don't use too many workers
data ShrinkSt = ShrinkSt
  { row :: Int
  -- ^ current row
  , col :: Int
  -- ^ current column
  , book :: Map.Map ThreadId (Int, Int)
  -- ^ map from @ThreadId@ to the candidate they are currently evaluating
  , path :: [(Int, Int)] -- TODO make this list be built in reverse order and then reverse it at the end
  -- ^ path taken when shrinking so far
  , selfTerminated :: Int
  -- ^ how many threads died on their own
  , blockUntilAwoken :: MVar ()
  -- ^ when you self terminate, block until you are awoken by taking this mvar
  , currentResult :: P.Result
  -- ^ current best candidate
  , candidates :: [Rose P.Result]
  -- ^ candidates yet to evaluate
  }

shrinker :: Bool -> State -> Int ->  Int -> P.Result -> [Rose P.Result] -> IO (Int, Int, Int, P.Result)
shrinker chatty st numsucc n res ts = do

  blocker    <- newEmptyMVar
  jobs       <- newMVar $ ShrinkSt 0 0 Map.empty [(-1,-1)] 0 blocker res ts
  stats      <- newIORef (0,0,0)
  signal     <- newEmptyMVar

  -- continuously print current state
  printerID <- if chatty
                 then Just <$> forkIO (shrinkPrinter (terminal st) stats numsucc res 200)
                 else return Nothing

  -- start shrinking
  tids <- spawnWorkers n jobs stats signal
  
  -- need to block here until completely done
  takeMVar signal

  -- stop printing
  maybe (return ()) killThread printerID
  withBuffering $ clearTemp (terminal st)

  -- make sure to kill the spawned shrinkers
  mapM_ killThread tids

  -- get res
  ShrinkSt _ _ _ p _ _ r _ <- readMVar jobs
  (_,nt,ntot) <- readIORef stats

  return (length p, ntot-nt, nt, r)
  where
    -- | The shrink loop evaluated by each individual worker
    worker :: MVar ShrinkSt -> IORef (Int, Int, Int) -> MVar () -> IO ()
    worker jobs stats signal = do
      -- try to get a candidate to evaluate
      j <- getJob jobs
      case j of
        -- no new candidate, removeFromMap will block this worker until new work exists
        Nothing -> removeFromMap jobs signal >> worker jobs stats signal 
        Just (r,c,parent,t) -> do
          mec <- evaluateCandidate t
          case mec of
            Nothing          -> do
              failedShrink stats -- shrinking failed, update counters and recurse
              worker jobs stats signal
            Just (res', ts') -> do
              successShrink stats -- shrinking succeeded, update counters and shared pool of work, and recurse
              updateWork res' ts' (r,c) parent jobs
              worker jobs stats signal

    -- | get a new candidate to evaluate
    getJob :: MVar ShrinkSt -> IO (Maybe (Int, Int, (Int, Int), Rose P.Result))
    getJob jobs = do
      tid <- myThreadId
      modifyMVar jobs $ \st ->
        case candidates st of
          []     -> return (st, Nothing)
          (t:ts) -> return (st { col        = col st + 1
                               , book       = Map.insert tid (row st, col st) (book st)
                               , candidates = ts
                               }, Just (row st, col st, head (path st), t))

    -- | this worker is idle. Indicate in the shared book that it is not working on anything, and block
    removeFromMap :: MVar ShrinkSt -> MVar () -> IO ()
    removeFromMap jobs signal = do
      tid <- myThreadId
      block <- modifyMVar jobs $ \st -> do
        let newst = selfTerminated st + 1
        if newst == n then putMVar signal () else return ()
        return ( st { book           = Map.delete tid (book st)
                    , selfTerminated = newst}
               , blockUntilAwoken st
               )
      takeMVar block

    evaluateCandidate :: Rose P.Result -> IO (Maybe (P.Result, [Rose P.Result]))
    evaluateCandidate t = do
      MkRose res' ts' <- protectRose (reduceRose t)
      res' <- callbackPostTest st res'
      if ok res' == Just False
        then return $ Just (res', ts')
        else return Nothing

    failedShrink :: IORef (Int, Int, Int) -> IO ()
    failedShrink stats = atomicModifyIORef' stats $ \(ns, nt, ntot) -> ((ns, nt + 1, ntot + 1), ())

    successShrink :: IORef (Int, Int, Int) -> IO ()
    successShrink stats = atomicModifyIORef' stats $ \(ns, nt, ntot) -> ((ns + 1, 0, ntot), ())

    -- | A new counterexample is found. Maybe update the shared resource
    updateWork :: P.Result              -- result of new counterexample
               -> [Rose P.Result]       -- new candidates
               -> (Int, Int)            -- 'coordinates' of the new counterexample
               -> (Int, Int)            -- 'coordinates' of the parent of the counterexample
               -> MVar ShrinkSt         -- shared resource
               -> IO ()
    updateWork res' ts' cand@(r',c') parent jobs = do
      tid <- myThreadId
      modifyMVar_ jobs $ \st ->
        if not $ parent `elem` path st -- in rare cases, 'stale' candidates could be delivered. Here we check if this candidate is to be considered
          then return st
          else do let (tids, wm') = toRestart tid (book st) 
                  interruptShrinkers tids
                  let n = selfTerminated st
                  if n > 0
                    then sequence_ (replicate n (putMVar (blockUntilAwoken st) ()))
                    else return ()
                  return $ st { row            = r' + 1
                              , col            = 0
                              , book           = wm'
                              , path           = path st <> [cand] -- path'
                              , currentResult  = res'
                              , candidates     = ts'
                              , selfTerminated = 0}
      where
        toRestart :: ThreadId -> Map.Map ThreadId (Int, Int) -> ([ThreadId], Map.Map ThreadId (Int, Int))
        toRestart tid wm = (filter ((/=) tid) $ Map.keys wm, Map.empty)

    -- TODO I tried adding my own kind of internal exception here, but I could not get it to work... piggybacking on this one
    -- for now, but it can not stay in the merge. Need to figure out what went wrong last time.
    -- I think the QCException type I added didn't work here for some reason, but I can't quite remember what that was now.
    interruptShrinkers :: [ThreadId] -> IO ()
    interruptShrinkers tids = mapM_ (\tid -> throwTo tid UserInterrupt) tids

    spawnWorkers :: Int -> MVar ShrinkSt -> IORef (Int, Int, Int) -> MVar () -> IO [ThreadId]
    spawnWorkers num jobs stats signal =
      sequence $ replicate num $ forkIO $ defHandler $ worker jobs stats signal
      where
        -- apparently this programming style can leak a lot of memory, but I tried to measure it during my evaluation, and
        -- had no real problems. Could someone verify, or is this OK?
        -- Edsko De Vries showed code at HIW 2023 that looked like this, and said it had major memory flaws. Title of his
        -- lightening talk was: Severing ties: the need for non-updateable thunks
        defHandler :: IO () -> IO ()
        defHandler ioa = do
          r <- try ioa
          case r of
            Right a -> pure a
            Left UserInterrupt -> defHandler ioa
            Left ThreadKilled -> myThreadId >>= killThread

shrinkPrinter :: Terminal -> IORef (Int, Int, Int) -> Int -> P.Result -> Int -> IO ()
shrinkPrinter terminal stats n res delay = do
  triple <- readIORef stats
  let output = fst $ failureSummaryAndReason2 triple n res
  withBuffering $ putTemp terminal output
  threadDelay delay
  shrinkPrinter terminal stats n res delay

failureSummaryAndReason2 :: (Int, Int, Int) -> Int -> P.Result -> (String, [String])
failureSummaryAndReason2 (ns, nt, _) numSuccTests res = (summary, full)
  where
    summary =
      header ++
      short 26 (oneLine theReason ++ " ") ++
      count True ++ "..."

    full =
      (header ++
       (if isOneLine theReason then theReason ++ " " else "") ++
       count False ++ ":"):
      if isOneLine theReason then [] else lines theReason

    theReason = P.reason res

    header =
      if expect res then
        bold "*** Failed! "
      else "+++ OK, failed as expected. "

    count full =
      "(after " ++ number (numSuccTests + 1) "test" ++
      concat [
        " and " ++
        show ns ++
        concat [ "." ++ show nt | showNumTryShrinks ] ++
        " shrink" ++
        (if ns == 1 && not showNumTryShrinks then "" else "s")
        | ns > 0 || showNumTryShrinks ] ++
      ")"
      where
        showNumTryShrinks = full && nt > 0

--------------------------------------------------------------------------
-- callbacks

callbackPostTest :: State -> P.Result -> IO P.Result
callbackPostTest st res = protect (exception "Exception running callback") $ do
  sequence_ [ f st res | PostTest _ f <- callbacks res ]
  return res

callbackPostFinalFailure :: State -> P.Result -> IO ()
callbackPostFinalFailure st res = do
  x <- tryEvaluateIO $ sequence_ [ f st res | PostFinalFailure _ f <- callbacks res ]
  case x of
    Left err -> do
      putLine (terminal st) "*** Exception running callback: "
      tryEvaluateIO $ putLine (terminal st) (show err)
      return ()
    Right () -> return ()

----------------------------------------------------------------------
-- computing coverage

sufficientlyCovered :: Confidence -> Int -> Int -> Double -> Bool
sufficientlyCovered confidence n k p =
  -- Accept the coverage if, with high confidence, the actual probability is
  -- at least 0.9 times the required one.
  wilsonLow (fromIntegral k) (fromIntegral n) (1 / fromIntegral err) >= tol * p
  where
    err = certainty confidence
    tol = tolerance confidence

insufficientlyCovered :: Maybe Integer -> Int -> Int -> Double -> Bool
insufficientlyCovered Nothing n k p =
  fromIntegral k < p * fromIntegral n
insufficientlyCovered (Just err) n k p =
  wilsonHigh (fromIntegral k) (fromIntegral n) (1 / fromIntegral err) < p

-- https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval#Wilson_score_interval
-- Note:
-- https://www.ncss.com/wp-content/themes/ncss/pdf/Procedures/PASS/Confidence_Intervals_for_One_Proportion.pdf
-- suggests we should use a instead of a/2 for a one-sided test. Look
-- into this.
wilson :: Integer -> Integer -> Double -> Double
wilson k n z =
  (p + z*z/(2*nf) + z*sqrt (p*(1-p)/nf + z*z/(4*nf*nf)))/(1 + z*z/nf)
  where
    nf = fromIntegral n
    p = fromIntegral k / fromIntegral n

wilsonLow :: Integer -> Integer -> Double -> Double
wilsonLow k n a = wilson k n (invnormcdf (a/2))

wilsonHigh :: Integer -> Integer -> Double -> Double
wilsonHigh k n a = wilson k n (invnormcdf (1-a/2))

-- Algorithm taken from
-- https://web.archive.org/web/20151110174102/http://home.online.no/~pjacklam/notes/invnorm/
-- Accurate to about one part in 10^9.
--
-- The 'erf' package uses the same algorithm, but with an extra step
-- to get a fully accurate result, which we skip because it requires
-- the 'erfc' function.
invnormcdf :: Double -> Double
invnormcdf p
  | p < 0  = 0/0
  | p > 1  = 0/0
  | p == 0 = -1/0
  | p == 1 = 1/0
  | p < p_low =
    let
      q = sqrt(-2*log(p))
    in
      (((((c1*q+c2)*q+c3)*q+c4)*q+c5)*q+c6) /
      ((((d1*q+d2)*q+d3)*q+d4)*q+1)
  | p <= p_high =
    let
      q = p - 0.5
      r = q*q
    in
      (((((a1*r+a2)*r+a3)*r+a4)*r+a5)*r+a6)*q /
      (((((b1*r+b2)*r+b3)*r+b4)*r+b5)*r+1)
  | otherwise =
    let
      q = sqrt(-2*log(1-p))
    in
      -(((((c1*q+c2)*q+c3)*q+c4)*q+c5)*q+c6) /
       ((((d1*q+d2)*q+d3)*q+d4)*q+1)
  where
    a1 = -3.969683028665376e+01
    a2 =  2.209460984245205e+02
    a3 = -2.759285104469687e+02
    a4 =  1.383577518672690e+02
    a5 = -3.066479806614716e+01
    a6 =  2.506628277459239e+00

    b1 = -5.447609879822406e+01
    b2 =  1.615858368580409e+02
    b3 = -1.556989798598866e+02
    b4 =  6.680131188771972e+01
    b5 = -1.328068155288572e+01

    c1 = -7.784894002430293e-03
    c2 = -3.223964580411365e-01
    c3 = -2.400758277161838e+00
    c4 = -2.549732539343734e+00
    c5 =  4.374664141464968e+00
    c6 =  2.938163982698783e+00

    d1 =  7.784695709041462e-03
    d2 =  3.224671290700398e-01
    d3 =  2.445134137142996e+00
    d4 =  3.754408661907416e+00

    p_low  = 0.02425
    p_high = 1 - p_low

addCoverageCheck :: Map.Map [String] Int
                  -> Map.Map String Int
                  -> Map.Map String (Map.Map String Int)
                  -> Map.Map (Maybe String, String) Double
                  -> Int
                  -> Confidence
                  -> Property
                  -> Property
addCoverageCheck labels classes tables requiredCoverage numTests coverageConfidence prop
  | and [ sufficientlyCovered coverageConfidence tot n p
        | (_, _, tot, n, p) <- allCoverage classes tables requiredCoverage numTests
        ] = once prop
  | or [ insufficientlyCovered (Just (certainty coverageConfidence)) tot n p
       | (_, _, tot, n, p) <- allCoverage classes tables requiredCoverage numTests
       ] = let (theLabels, theTables) = labelsAndTables labels classes tables requiredCoverage numTests (Just coverageConfidence) in
           foldr counterexample (property failed{P.reason = "Insufficient coverage"})
             (paragraphs [theLabels, theTables])
  | otherwise = prop

allCoverage :: Map.Map String Int -> Map.Map String (Map.Map String Int) -> Map.Map (Maybe String, String) Double -> Int -> [(Maybe String, String, Int, Int, Double)]
allCoverage classes tables requiredCoverage numTests =
  [ (key, value, tot, n, p)
  | ((key, value), p) <- Map.toList requiredCoverage,
    let tot = case key of
                Just key -> Map.findWithDefault 0 key totals
                Nothing -> numTests,
    let n = Map.findWithDefault 0 value (Map.findWithDefault Map.empty key combinedCounts)
  ]
  where
    combinedCounts :: Map.Map (Maybe String) (Map.Map String Int)
    combinedCounts = Map.insert Nothing classes (Map.mapKeys Just tables)

    totals :: Map.Map String Int
    totals = fmap (sum . Map.elems) tables

--------------------------------------------------------------------------
-- the end.
