{- git-annex command
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.InitRemote where

import qualified Data.Map as M
import Control.Monad (when)
import Control.Monad.State (liftIO)

import Command
import qualified Annex
import qualified Remote
import qualified RemoteClass
import qualified GitRepo as Git
import Utility
import Types
import UUID
import Messages

command :: [Command]
command = [repoCommand "initremote"
	(paramPair paramName $
		paramOptional $ paramRepeating $ paramKeyValue) seek
	"sets up a special (non-git) remote"]

seek :: [CommandSeek]
seek = [withWords start]

start :: CommandStartWords
start ws = notBareRepo $ do
	when (null ws) $ error "Specify a name for the remote"

	(u, c) <- findByName name
	let fullconfig = M.union config c	
	t <- findType fullconfig

	showStart "initremote" name
	next $ perform t u $ M.union config c

	where
		name = head ws
		config = Remote.keyValToConfig $ tail ws

perform :: RemoteClass.RemoteType Annex -> UUID -> RemoteClass.RemoteConfig -> CommandPerform
perform t u c = do
	c' <- RemoteClass.setup t u c
	next $ cleanup u c'

cleanup :: UUID -> RemoteClass.RemoteConfig -> CommandCleanup
cleanup u c = do
	Remote.configSet u c
	g <- Annex.gitRepo
	logfile <- Remote.remoteLog
	liftIO $ Git.run g "add" [File logfile]
        liftIO $ Git.run g "commit"
                [ Params "-q --allow-empty -m"
                , Param "git annex initremote"
                , File logfile
                ]
        return True

{- Look up existing remote's UUID and config by name, or generate a new one -}
findByName :: String -> Annex (UUID, RemoteClass.RemoteConfig)
findByName name = do
	m <- Remote.readRemoteLog
	maybe generate return $ findByName' name m
	where
		generate = do
			uuid <- liftIO $ genUUID
			return (uuid, M.insert nameKey name M.empty)

findByName' :: String ->  M.Map UUID RemoteClass.RemoteConfig -> Maybe (UUID, RemoteClass.RemoteConfig)
findByName' n m = if null matches then Nothing else Just $ head matches
	where
		matches = filter (matching . snd) $ M.toList m
		matching c = case M.lookup nameKey c of
			Nothing -> False
			Just n'
				| n' == n -> True
				| otherwise -> False

{- find the specified remote type -}
findType :: RemoteClass.RemoteConfig -> Annex (RemoteClass.RemoteType Annex)
findType config = maybe unspecified specified $ M.lookup typeKey config
	where
		unspecified = error "Specify the type of remote with type="
		specified s = case filter (findtype s) Remote.remoteTypes of
			[] -> error $ "Unknown remote type " ++ s
			(t:_) -> return t
		findtype s i = RemoteClass.typename i == s

{- The name of a configured remote is stored in its config using this key. -}
nameKey :: String
nameKey = "name"

{- The type of a remote is stored in its config using this key. -}
typeKey :: String
typeKey = "type"
