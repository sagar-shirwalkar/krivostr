{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

-- | The binary is called @krivostr@; the subcommand parser lives in
-- "Krivostr.Cli" so that it can be exercised by the test suite.
--
-- @krivostr serve@ is what this program used to be when it was only a bridge.
import Krivostr.Cli (runCLI)

main :: IO ()
main = runCLI
