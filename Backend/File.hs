{- git-annex pseudo-backend
 -
 - This backend does not really do any independant data storage,
 - it relies on the file contents in .git/annex/ in this repo,
 - and other accessible repos.
 -
 - This is an abstract backend; name, getKey and fsckKey have to be implemented
 - to complete it.
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Backend.File (backend, checkKey) where

import Data.List
import Data.String.Utils

import Types.Backend
import LocationLog
import qualified Remote
import qualified Git
import Content
import qualified Annex
import Types
import UUID
import Messages
import Trust
import Types.Key

backend :: Backend Annex
backend = Backend {
	name = mustProvide,
	getKey = mustProvide,
	storeFileKey = dummyStore,
	retrieveKeyFile = copyKeyFile,
	removeKey = checkRemoveKey,
	hasKey = inAnnex,
	fsckKey = checkKeyOnly,
	upgradableKey = checkUpgradableKey
}

mustProvide :: a
mustProvide = error "must provide this field"

{- Storing a key is a no-op. -}
dummyStore :: FilePath -> Key -> Annex Bool
dummyStore _ _ = return True

{- Try to find a copy of the file in one of the remotes,
 - and copy it to here. -}
copyKeyFile :: Key -> FilePath -> Annex Bool
copyKeyFile key file = do
	remotes <- Remote.keyPossibilities key
	if null remotes
		then do
			showNote "not available"
			showLocations key []
			return False
		else trycopy remotes remotes
	where
		trycopy full [] = do
			showTriedRemotes full
			showLocations key []
			return False
		trycopy full (r:rs) = do
			probablythere <- probablyPresent r
			if probablythere
				then docopy r (trycopy full rs)
				else trycopy full rs
		-- This check is to avoid an ugly message if a remote is a
		-- drive that is not mounted.
		probablyPresent r =
			if Remote.hasKeyCheap r
				then do
					res <- Remote.hasKey r key
					case res of
						Right b -> return b
						Left _ -> return False
				else return True
		docopy r continue = do
			showNote $ "from " ++ Remote.name r ++ "..."
			copied <- Remote.retrieveKeyFile r key file
			if copied
				then return True
				else continue

{- Checks remotes to verify that enough copies of a key exist to allow
 - for a key to be safely removed (with no data loss), and fails with an
 - error if not. -}
checkRemoveKey :: Key -> Maybe Int -> Annex Bool
checkRemoveKey key numcopiesM = do
	force <- Annex.getState Annex.force
	if force || numcopiesM == Just 0
		then return True
		else do
			(remotes, trusteduuids) <- Remote.keyPossibilitiesTrusted key
			untrusteduuids <- trustGet UnTrusted
			let tocheck = Remote.remotesWithoutUUID remotes (trusteduuids++untrusteduuids)
			numcopies <- getNumCopies numcopiesM
			findcopies numcopies trusteduuids tocheck []
	where
		findcopies need have [] bad
			| length have >= need = return True
			| otherwise = notEnoughCopies need have bad
		findcopies need have (r:rs) bad
			| length have >= need = return True
			| otherwise = do
				let u = Remote.uuid r
				let dup = u `elem` have
				haskey <- Remote.hasKey r key
				case (dup, haskey) of
					(False, Right True)	-> findcopies need (u:have) rs bad
					(False, Left _)		-> findcopies need have rs (r:bad)
					_			-> findcopies need have rs bad
		notEnoughCopies need have bad = do
			unsafe
			showLongNote $
				"Could only verify the existence of " ++
				show (length have) ++ " out of " ++ show need ++ 
				" necessary copies"
			showTriedRemotes bad
			showLocations key have
			hint
			return False
		unsafe = showNote "unsafe"
		hint = showLongNote "(Use --force to override this check, or adjust annex.numcopies.)"

showLocations :: Key -> [UUID] -> Annex ()
showLocations key exclude = do
	g <- Annex.gitRepo
	u <- getUUID g
	uuids <- keyLocations key
	untrusteduuids <- trustGet UnTrusted
	let uuidswanted = filteruuids uuids (u:exclude++untrusteduuids) 
	let uuidsskipped = filteruuids uuids (u:exclude++uuidswanted)
	ppuuidswanted <- Remote.prettyPrintUUIDs uuidswanted
	ppuuidsskipped <- Remote.prettyPrintUUIDs uuidsskipped
	showLongNote $ message ppuuidswanted ppuuidsskipped
	where
		filteruuids list x = filter (`notElem` x) list
		message [] [] = "No other repository is known to contain the file."
		message rs [] = "Try making some of these repositories available:\n" ++ rs
		message [] us = "Also these untrusted repositories may contain the file:\n" ++ us
		message rs us = message rs [] ++ message [] us

showTriedRemotes :: [Remote.Remote Annex] -> Annex ()
showTriedRemotes [] = return ()	
showTriedRemotes remotes =
	showLongNote $ "Unable to access these remotes: " ++
		(join ", " $ map Remote.name remotes)

{- If a value is specified, it is used; otherwise the default is looked up
 - in git config. forcenumcopies overrides everything. -}
getNumCopies :: Maybe Int -> Annex Int
getNumCopies v = 
	Annex.getState Annex.forcenumcopies >>= maybe (use v) (return . id)
	where
		use (Just n) = return n
		use Nothing = do
			g <- Annex.gitRepo
			return $ read $ Git.configGet g config "1"
		config = "annex.numcopies"

{- Ideally, all keys have file size metadata. Old keys may not. -}
checkUpgradableKey :: Key -> Annex Bool
checkUpgradableKey key
	| keySize key == Nothing = return True
	| otherwise = return False

{- This is used to check that numcopies is satisfied for the key on fsck.
 - This trusts data in the the location log, and so can check all keys, even
 - those with data not present in the current annex.
 -
 - The passed action is first run to allow backends deriving this one
 - to do their own checks.
 -}
checkKey :: (Key -> Annex Bool) -> Key -> Maybe FilePath -> Maybe Int -> Annex Bool
checkKey a key file numcopies = do
	a_ok <- a key
	copies_ok <- checkKeyNumCopies key file numcopies
	return $ a_ok && copies_ok

checkKeyOnly :: Key -> Maybe FilePath -> Maybe Int -> Annex Bool
checkKeyOnly = checkKey (\_ -> return True)

checkKeyNumCopies :: Key -> Maybe FilePath -> Maybe Int -> Annex Bool
checkKeyNumCopies key file numcopies = do
	needed <- getNumCopies numcopies
	locations <- keyLocations key
	untrusted <- trustGet UnTrusted
	let untrustedlocations = intersect untrusted locations
	let safelocations = filter (`notElem` untrusted) locations
	let present = length safelocations
	if present < needed
		then do
			ppuuids <- Remote.prettyPrintUUIDs untrustedlocations
			warning $ missingNote (filename file key) present needed ppuuids
			return False
		else return True
	where
		filename Nothing k = show k
		filename (Just f) _ = f

missingNote :: String -> Int -> Int -> String -> String
missingNote file 0 _ [] = 
		"** No known copies exist of " ++ file
missingNote file 0 _ untrusted =
		"Only these untrusted locations may have copies of " ++ file ++
		"\n" ++ untrusted ++
		"Back it up to trusted locations with git-annex copy."
missingNote file present needed [] =
		"Only " ++ show present ++ " of " ++ show needed ++ 
		" trustworthy copies exist of " ++ file ++
		"\nBack it up with git-annex copy."
missingNote file present needed untrusted = 
		missingNote file present needed [] ++
		"\nThe following untrusted locations may also have copies: " ++
		"\n" ++ untrusted
