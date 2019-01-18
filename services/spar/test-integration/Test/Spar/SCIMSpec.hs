{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE LambdaCase          #-}

module Test.Spar.SCIMSpec where

import Imports
import Bilge
import Bilge.Assert
import Brig.Types.User as Brig
import Control.Lens
import Data.ByteString.Conversion
import Spar.SCIM
import Spar.SCIM.Types
import Spar.Types (ScimTokenInfo(..))
import Util

import qualified Spar.Data                        as Data
import qualified Web.SCIM.Class.User              as SCIM.Class.User
import qualified Web.SCIM.Schema.Common           as SCIM
import qualified Web.SCIM.Schema.Meta             as SCIM


spec :: SpecWith TestEnv
spec = do
    specUsers
    specTokens

specUsers :: SpecWith TestEnv
specUsers = describe "operations with users" $ do
    describe "POST /Users" $ do
        it "creates a user in an existing team" $ do
            env <- ask
            -- Create a user via SCIM
            user <- randomSCIMUser
            (tok, _) <- registerIdPAndSCIMToken
            scimStoredUser <- createUser tok user
            let userid = scimUserId scimStoredUser
            -- Check that this user is present in Brig and that Brig's view
            -- of the user matches SCIM's view of the user
            brigUser :: User <- fmap decodeBody' . call . get $
                ( (env ^. teBrig)
                . header "Z-User" (toByteString' userid)
                . path "/self"
                . expect2xx
                )
            brigUser `userShouldMatch` scimStoredUser

        it "gives created user a valid 'SAML.UserRef' for SSO." $ do
            pending

        it "attributes of brig user, scim user, saml user are mapped as documented." $ do
            pending

        it "writes all the stuff to all the places" $ do
            pendingWith "factor this out of the PUT tests we already wrote."

    describe "GET /Users" $ do
        it "lists all users in a team" $ do
            -- Create a user via SCIM
            user <- randomSCIMUser
            (tok, (owner, _, _)) <- registerIdPAndSCIMToken
            storedUser <- createUser tok user
            -- Get all users via SCIM
            users <- listUsers tok Nothing
            -- Check that the SCIM user is present
            liftIO $ users `shouldContain` [storedUser]
            -- Check that the (non-SCIM-provisioned) team owner is NOT present
            liftIO $ (scimUserId <$> users) `shouldNotContain` [owner]
        it "finds a SCIM-provisioned user by username" $
            pending
        it "finds a non-SCIM-provisioned user by username" $
            pending
        it "doesn't list deleted users" $ do
            env <- ask
            -- Create a user via SCIM
            user <- randomSCIMUser
            (tok, _) <- registerIdPAndSCIMToken
            storedUser <- createUser tok user
            let userid = scimUserId storedUser
            -- Delete the user (TODO: do it via SCIM)
            call $ deleteUser (env ^. teBrig) userid
            -- Get all users
            users <- listUsers tok Nothing
            -- Check that the user is absent
            liftIO $ users `shouldSatisfy` all ((/= userid) . scimUserId)

    describe "GET /Users/:id" $ do
        it "finds a SCIM-provisioned user" $ do
            -- Create a user via SCIM
            user <- randomSCIMUser
            (tok, _) <- registerIdPAndSCIMToken
            storedUser <- createUser tok user
            -- Check that the SCIM-provisioned user can be fetched
            storedUser' <- getUser tok (scimUserId storedUser)
            liftIO $ storedUser' `shouldBe` storedUser
        it "does NOT find a non-SCIM-provisioned user" $ do
            pendingWith "TODO: fails because the user has no handle (UPDATE: \
                        \it *should* fail, too, just need to make sure it's \
                        \for the right reasons.)"
            {-
            env <- ask
            -- Check that the (non-SCIM-provisioned) team owner can be fetched
            -- and that the data from Brig matches
            brigUser <- fmap decodeBody' . call . get $
                ( (env ^. teBrig)
                . header "Z-User" (toByteString' (env^.teUserId))
                . path "/self"
                . expect2xx
                )
            scimStoredUser <- getUser (env^.teUserId)
            scimStoredUser `userShouldMatch` brigUser
            -}
        it "doesn't find a user that's not part of the team" $ do
            pending
            -- create another team and another user in it
            -- check that this user can not be found in the "wrong" team
        it "doesn't find a deleted user" $ do
            env <- ask
            -- Create a user via SCIM
            user <- randomSCIMUser
            (tok, _) <- registerIdPAndSCIMToken
            storedUser <- createUser tok user
            let userid = scimUserId storedUser
            -- Delete the user
            call $ deleteUser (env ^. teBrig) userid
            -- Try to find the user
            getUser_ (Just tok) userid (env ^. teSpar)
                !!! const 404 === statusCode
            pendingWith "TODO: delete via SCIM"

    describe "PUT /Users" $ do
        it "responds with 4xx (just making sure...)" $ do
            env <- ask
            user <- randomSCIMUser
            (tok, _) <- registerIdPAndSCIMToken
            putUser_ (Just tok) Nothing user (env ^. teSpar)
                !!! assertTrue_ (inRange (400, 499) . statusCode)

    describe "PUT /Users/:id" $ do
        it "updates the user attributes in scim_user" $ do
            env <- ask
            user <- randomSCIMUser
            (tok, _) <- registerIdPAndSCIMToken
            storedUser <- createUser tok user
            let userid = scimUserId storedUser
            user' <- randomSCIMUser
            putUser_ (Just tok) (Just userid) user' (env ^. teSpar)
                !!! const 200 === statusCode
            getresp <- getUser_ (Just tok) userid (env ^. teSpar)
                <!! const 200 === statusCode
            let storedUser' :: SCIM.Class.User.StoredUser = decodeBody' getresp
            liftIO $ do
                SCIM.value (SCIM.thing storedUser) `shouldBe` user
                SCIM.value (SCIM.thing storedUser') `shouldBe` user'
                SCIM.id (SCIM.thing storedUser') `shouldBe` SCIM.id (SCIM.thing storedUser)
                let meta  = SCIM.meta storedUser
                    meta' = SCIM.meta storedUser'
                SCIM.resourceType meta `shouldBe` SCIM.resourceType meta'
                SCIM.created  meta `shouldBe` SCIM.created  meta'
                SCIM.version meta `shouldBe` SCIM.version meta'
                SCIM.location meta `shouldBe` SCIM.location meta'

        it "updates 'SAML.UserRef' in spar" $ do
            env <- ask
            user <- randomSCIMUser
            (tok, (_, _, idp)) <- registerIdPAndSCIMToken
            storedUser <- createUser tok user
            user' <- randomSCIMUser
            let userid = scimUserId storedUser
            putUser_ (Just tok) (Just userid) user' (env ^. teSpar)
                !!! const 200 === statusCode
            vuser' <- either (error . show) pure $ validateSCIMUser' (Just idp) user'
            muserid' <- runSparCass $ Data.getUser (vuser' ^. vsuSAMLUserRef)
            liftIO $ do
                muserid' `shouldBe` Just userid

        it "maps ValidSCIMUser to Brig.User completely and correctly (including 'SAML.UserRef')." $ do
            env <- ask
            user <- randomSCIMUser
            (tok, (_, _, idp)) <- registerIdPAndSCIMToken
            storedUser <- createUser tok user
            user' <- randomSCIMUser
            let userid = scimUserId storedUser
            putUser_ (Just tok) (Just userid) user' (env ^. teSpar)
                !!! const 200 === statusCode
            validSCIMUser <- either (error . show) pure $ validateSCIMUser' (Just idp) user'
            brigUser      <- maybe (error "no brig user") pure =<< getSelf userid
            brigUser `userShouldMatch` validSCIMUser

        context "scim_user has no entry with this id" $ do
            it "fails" $ do
                pending

        context "brig user is updated" $ do
            it "does NOT mirror this in the scim user" $ do
                pendingWith "this is arguably not great behavior, but \
                            \i'm not sure we want to implement \
                            \synchronisation from brig to spar right now?"

            it "updates to scim user will overwrite these updates" $ do
                pendingWith "that's probably what we want?"

    describe "DELETE /Users" $ do
        it "responds with 404 (just making sure...)" $ do
            pending

    describe "DELETE /Users/:id" $ do
        it "sets the 'deleted' flag in brig, and does nothing otherwise." $ do
            pendingWith "really?  how do we destroy the data then, and when?"

    describe "GET /Meta" $ do  -- TODO: is that the end-point?  it's about the 'getMeta' method.
        it "..." $ do
            pending

    describe "CRUD operations maintain invariants in mapScimToBrig, mapBrigToScim." $ do
        it "..." $ do
            pendingWith "this is a job for quickcheck-state-machine"


specTokens :: SpecWith TestEnv
specTokens = xdescribe "operations with provisioning tokens" $ do
    describe "POST /auth-tokens" $ do
        it "creates a usable token" $ do
            env <- ask
            -- Create a token
            (owner, _, _) <- registerTestIdP
            CreateScimTokenResponse token tokenInfo <-
                createToken owner CreateScimToken
                    { createScimTokenDescr = "token creation test" }
            -- Try to execute a SCIM operation without a token and check
            -- that it fails
            listUsers_ Nothing Nothing (env ^. teSpar)
                !!! const 401 === statusCode
            -- Try to execute the same SCIM operation with the generated
            -- token; it should succeed now
            listUsers_ (Just token) Nothing (env ^. teSpar)
                !!! const 200 === statusCode
            -- Cleanup
            deleteToken owner (stiId tokenInfo)

        it "respects the token limit (2 for integration tests)" $ do
            env <- ask
            -- Try to create two more tokens (in addition to the already
            -- existing token that's created in 'mkEnv'). Creating the
            -- second token should succeed, and creating the third token
            -- should fail.
            (owner, _, _) <- registerTestIdP
            CreateScimTokenResponse _ tokenInfo1 <-
                createToken owner CreateScimToken
                    { createScimTokenDescr = "token limit test / #1" }
            createToken_ owner CreateScimToken
                { createScimTokenDescr = "token limit test / #2" }
                (env ^. teSpar)
                !!! const 403 === statusCode
            -- Cleanup
            deleteToken owner (stiId tokenInfo1)

        it "doesn't create a token for a team without IdP" $ do
            env <- ask
            -- Create a new team and don't associate an IdP with it
            (userid, _teamid) <- runHttpT (env ^. teMgr) $
                createUserWithTeam (env ^. teBrig) (env ^. teGalley)
            -- Creating a token should fail now
            createToken_
                userid
                CreateScimToken { createScimTokenDescr = "IdP-less team test" }
                (env ^. teSpar)
                !!! const 400 === statusCode

    describe "DELETE /auth-tokens/:id" $ do
        it "makes the token unusable" $ do
            env <- ask
            -- Create a token
            (owner, _, _) <- registerTestIdP
            CreateScimTokenResponse token tokenInfo <-
                createToken owner CreateScimToken
                    { createScimTokenDescr = "token deletion test" }
            -- An operation with the token should succeed
            listUsers_ (Just token) Nothing (env ^. teSpar)
                !!! const 200 === statusCode
            -- Delete the token and now the operation should fail
            deleteToken owner (stiId tokenInfo)
            listUsers_ (Just token) Nothing (env ^. teSpar)
                !!! const 401 === statusCode

    describe "GET /auth-tokens" $ do
        it "lists tokens" $ do
            -- Create a token
            (owner, _, _) <- registerTestIdP
            CreateScimTokenResponse _ tokenInfo <-
                createToken owner CreateScimToken
                    { createScimTokenDescr = "token listing test" }
            -- Both the default team token and this token should be present
            do list <- scimTokenListTokens <$> listTokens owner
               liftIO $ map stiDescr list `shouldBe`
                   ["_teScimToken test token", "token listing test"]
            -- Delete the token and now it shouldn't be on the list
            deleteToken owner (stiId tokenInfo)
            do list <- scimTokenListTokens <$> listTokens owner
               liftIO $ map stiDescr list `shouldBe`
                   ["_teScimToken test token"]

    describe "validateSCIMUser'" $ do
        it "works" $ do
            pendingWith "write a list of unit tests here that make the mapping explicit, exhaustive, and easy to read."
