{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Krivostr.Bridge
import Krivostr.Logging
import Krivostr.Store
import System.Environment (lookupEnv)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)

defaultUpstreams :: [Text]
defaultUpstreams =
  [ "wss://relay.damus.io"
  , "wss://nos.lol"
  , "wss://relay.primal.net"
  ]

main :: IO ()
main = do
  lvlStr <- lookupEnv "KRIVOSTR_LOG_LEVEL"
  let lvl = case lvlStr of
              Just "debug" -> Debug
              Just "warn"  -> Warn
              Just "error" -> Error
              _            -> Info
  lg <- newLogger lvl

  -- Config via env, with sensible defaults.
  portStr  <- lookupEnv "KRIVOSTR_PORT"
  staticD  <- lookupEnv "KRIVOSTR_STATIC_DIR"
  dbPath   <- lookupEnv "KRIVOSTR_DB"
  let port    = maybe 8081 read portStr
      staticD' = maybe "./ui/dist" id staticD
      dbPath'  = maybe ".krivostr/events.db" id dbPath

  createDirectoryIfMissing True (takeDirectory dbPath')
  emit lg Info ("krivostr-client starting, db=" <> T.pack dbPath'
                <> " port=" <> T.pack (show port))
  store <- openStore lg dbPath'
  runBridge lg BridgeConfig
    { bcPort = port
    , bcStaticDir = staticD'
    , bcUpstreams = defaultUpstreams
    } store
