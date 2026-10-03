{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Krivostr.Logging
  ( LogLevel(..)
  , LogEntry(..)
  , PureLog
  , runPureLog
  , tellLog
  , debug
  , info
  , warn
  , errorL
  , Logger
  , newLogger
  , emit
  , withLevel
  , drainQueue
  ) where

import Control.Monad (when)
import Control.Monad.Writer.Strict (Writer, runWriter, tell, MonadWriter)
import Control.Concurrent.STM
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)

data LogLevel = Debug | Info | Warn | Error
  deriving (Show, Eq, Ord)

data LogEntry = LogEntry
  { leLevel :: !LogLevel
  , leMsg   :: !Text
  } deriving (Show, Eq)

-- | Pure logging: accumulate a list of entries alongside a value.
type PureLog = Writer [LogEntry]

tellLog :: LogLevel -> Text -> PureLog ()
tellLog lvl msg = tell [LogEntry lvl msg]

runPureLog :: PureLog a -> (a, [LogEntry])
runPureLog = runWriter

debug, info, warn, errorL :: Text -> PureLog ()
debug = tellLog Debug
info  = tellLog Info
warn  = tellLog Warn
errorL = tellLog Error

-- | Effectful logging: a queue of entries drained by a background thread.
data Logger = Logger
  { lgQueue :: TQueue LogEntry
  , lgMin   :: LogLevel
  }

newLogger :: LogLevel -> IO Logger
newLogger minLvl = Logger <$> newTQueueIO <*> pure minLvl

emit :: MonadIO m => Logger -> LogLevel -> Text -> m ()
emit lg lvl msg = liftIO $
  when (lvl >= lgMin lg) $ atomically $ writeTQueue (lgQueue lg) (LogEntry lvl msg)

withLevel :: Logger -> LogLevel -> Logger
withLevel lg lvl = lg { lgMin = lvl }

-- | Remove and return every queued entry, oldest first. Non-blocking: returns
-- whatever is queued at the moment of the call.
--
-- This used to live as a private helper duplicated in both test suites, which
-- meant it could only be written against the unexported 'lgQueue'.
drainQueue :: MonadIO m => Logger -> m [LogEntry]
drainQueue lg = liftIO $ go []
  where
    go acc = do
      next <- atomically $ tryReadTQueue (lgQueue lg)
      case next of
        Nothing -> pure (reverse acc)
        Just e -> go (e : acc)
