{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Unannex where

import Control.Monad.State (liftIO)
import Control.Monad (unless)
import System.Directory

import Command
import qualified Annex
import qualified AnnexQueue
import Utility
import qualified Backend
import LocationLog
import Types
import Content
import qualified Git
import qualified Git.LsFiles as LsFiles
import Messages

command :: [Command]
command = [repoCommand "unannex" paramPath seek "undo accidential add command"]

seek :: [CommandSeek]
seek = [withFilesInGit start]

{- The unannex subcommand undoes an add. -}
start :: CommandStartString
start file = isAnnexed file $ \(key, backend) -> do
	ishere <- inAnnex key
	if ishere
		then do
			force <- Annex.getState Annex.force
			unless force $ do
				g <- Annex.gitRepo
				staged <- liftIO $ LsFiles.staged g [Git.workTree g]
				unless (null staged) $
					error "This command cannot be run when there are already files staged for commit."
				Annex.changeState $ \s -> s { Annex.force = True }

			showStart "unannex" file
			next $ perform file key backend
		else stop

perform :: FilePath -> Key -> Backend Annex -> CommandPerform
perform file key backend = do
	-- force backend to always remove
	ok <- Backend.removeKey backend key (Just 0)
	if ok
		then next $ cleanup file key
		else stop

cleanup :: FilePath -> Key -> CommandCleanup
cleanup file key = do
	g <- Annex.gitRepo

	liftIO $ removeFile file
	liftIO $ Git.run g "rm" [Params "--quiet --", File file]
	-- git rm deletes empty directories; put them back
	liftIO $ createDirectoryIfMissing True (parentDir file)

	fromAnnex key file
	logStatus key InfoMissing
	
	-- Commit staged changes at end to avoid confusing the
	-- pre-commit hook if this file is later added back to
	-- git as a normal, non-annexed file.
	AnnexQueue.add "commit" [Params "-a -m", Param "content removed from git annex"] "-a"
	
	return True
