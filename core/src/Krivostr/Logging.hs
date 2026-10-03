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
  ) where

import Control.Monad.Writer.Strict (Writer, runWriter, tell, MonadWriter)
import Control.Concurrent.STM
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import qualified Data.Text.IO as TIO
import System.IO (stderr)

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
