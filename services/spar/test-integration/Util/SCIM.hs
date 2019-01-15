{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns        #-}

module Util.SCIM where

import Imports
import Bilge
import Bilge.Assert
import Brig.Types.User
import Cassandra
import Control.Lens
import Control.Monad.Random
import Data.ByteString.Conversion
import Data.Id
import Data.String.Conversions (cs)
import Data.Time
import Data.UUID as UUID
import Data.UUID.V4 as UUID
import SAML2.WebSSO.Types (IdPId, idpId)
import Spar.Data as Data
import Spar.SCIM (CreateScimToken(..), CreateScimTokenResponse(..), ScimTokenList(..))
import Spar.SCIM.Types
import Spar.Types (ScimToken(..), ScimTokenInfo(..), IdP)
import Util.Core
import Util.Types
import Web.HttpApiData (toHeader)

import qualified Data.Aeson                       as Aeson
import qualified SAML2.WebSSO                     as SAML
import qualified Spar.Intra.Brig                  as Intra
import qualified Text.Email.Parser                as Email
import qualified Web.SCIM.Class.User              as SCIM
import qualified Web.SCIM.Filter                  as SCIM
import qualified Web.SCIM.Schema.Common           as SCIM
import qualified Web.SCIM.Schema.ListResponse     as SCIM
import qualified Web.SCIM.Schema.Meta             as SCIM
import qualified Web.SCIM.Schema.User             as SCIM.User
import qualified Web.SCIM.Schema.User.Email       as Email


-- | Call 'registerTestIdP', then 'registerSCIMToken'.  The user returned is the owner of the team;
-- the IdP is registered with the team; the SCIM token can be used to manipulate the team.
registerIdPAndSCIMToken :: HasCallStack => TestSpar (ScimToken, (UserId, TeamId, IdP))
registerIdPAndSCIMToken = do
  team@(_owner, teamid, idp) <- registerTestIdP
  (, team) <$> registerSCIMToken teamid (Just (idp ^. idpId))

-- | Create a fresh SCIM token and register it for the team.
registerSCIMToken :: HasCallStack => TeamId -> Maybe IdPId -> TestSpar ScimToken
registerSCIMToken teamid midpid = do
  env <- ask
  tok <- ScimToken <$> do
    code <- liftIO UUID.nextRandom
    pure $ "scim-test-token/" <> "team=" <> idToText teamid <> "/code=" <> UUID.toText code
  scimTokenId <- randomId
  now <- liftIO getCurrentTime
  runClient (env ^. teCql) $ Data.insertScimToken
      tok
      ScimTokenInfo
          { stiTeam      = teamid
          , stiId        = scimTokenId
          , stiCreatedAt = now
          , stiIdP       = midpid
          , stiDescr     = "test token"
          }
  pure tok

-- | Generate a SCIM user with a random name and handle.  At the very least, everything considered
-- in @instance UserShouldMatch SCIM.User.User User@ and @validateSCIMUser@ must be random here.
-- FUTUREWORK: make this more exhaustive.  change everything that can be changed!  move this to the
-- hspec package when done.
randomSCIMUser :: MonadRandom m => m SCIM.User.User
randomSCIMUser = do
    suffix <- cs <$> replicateM 5 (getRandomR ('0', '9'))
    emails <- replicateM 3 randomSCIMEmail
    pure $ SCIM.User.empty
        { SCIM.User.userName    = "scimuser_" <> suffix
        , SCIM.User.displayName = Just ("Scim User #" <> suffix)
        , SCIM.User.externalId  = Just ("scimuser_extid_" <> suffix)
        , SCIM.User.emails      = Just emails
        }

randomSCIMEmail :: MonadRandom m => m Email.Email
randomSCIMEmail = do
    let typ     :: Maybe Text = Nothing
        primary :: Maybe Bool = Nothing  -- TODO: where should we catch users with more than one
                                         -- primary email?
    value :: Email.EmailAddress2 <- do
      localpart  <- cs <$> replicateM 15 (getRandomR ('a', 'z'))
      domainpart <- (<> ".com") . cs <$> replicateM 15 (getRandomR ('a', 'z'))
      pure . Email.EmailAddress2 $ Email.unsafeEmailAddress localpart domainpart
    pure Email.Email{..}


----------------------------------------------------------------------------
-- API wrappers

-- | Create a user.
createUser
    :: HasCallStack
    => ScimToken
    -> SCIM.User.User
    -> TestSpar SCIM.StoredUser
createUser tok user = do
    env <- ask
    r <- createUser_
             (Just tok)
             user
             (env ^. teSpar)
         <!! const 201 === statusCode
    pure (decodeBody' r)

-- | List all users.
listUsers
    :: HasCallStack
    => ScimToken
    -> Maybe SCIM.Filter
    -> TestSpar [SCIM.StoredUser]
listUsers tok mbFilter = do
    env <- ask
    r <- listUsers_
             (Just tok)
             mbFilter
             (env ^. teSpar)
         <!! const 200 === statusCode
    let r' = decodeBody' r
    when (SCIM.totalResults r' /= length (SCIM.resources r')) $
        error "listUsers: got a paginated result, but pagination \
              \is not supported yet"
    pure (SCIM.resources r')

-- | Get a user.
getUser
    :: HasCallStack
    => ScimToken
    -> UserId
    -> TestSpar SCIM.StoredUser
getUser tok userid = do
    env <- ask
    r <- getUser_
             (Just tok)
             userid
             (env ^. teSpar)
         <!! const 200 === statusCode
    pure (decodeBody' r)

-- | Create a SCIM token.
createToken
    :: HasCallStack
    => UserId
    -> CreateScimToken
    -> TestSpar CreateScimTokenResponse
createToken zusr payload = do
    env <- ask
    r <- createToken_
             zusr
             payload
             (env ^. teSpar)
         <!! const 200 === statusCode
    pure (decodeBody' r)

-- | Delete a SCIM token.
deleteToken
    :: HasCallStack
    => UserId
    -> ScimTokenId                -- ^ Token to delete
    -> TestSpar ()
deleteToken zusr tokenid = do
    env <- ask
    deleteToken_
        zusr
        tokenid
        (env ^. teSpar)
        !!! const 204 === statusCode

-- | List SCIM tokens.
listTokens
    :: HasCallStack
    => UserId
    -> TestSpar ScimTokenList
listTokens zusr = do
    env <- ask
    r <- listTokens_
             zusr
             (env ^. teSpar)
         <!! const 200 === statusCode
    pure (decodeBody' r)

----------------------------------------------------------------------------
-- "Raw" API requests

-- | Create a user.
createUser_
    :: Maybe ScimToken          -- ^ Authentication
    -> SCIM.User.User           -- ^ User data
    -> SparReq                  -- ^ Spar endpoint
    -> TestSpar ResponseLBS
createUser_ auth user spar_ = do
    -- NB: we don't use 'mkEmailRandomLocalSuffix' here, because emails
    -- shouldn't be submitted via SCIM anyway.
    -- TODO: what's the consequence of this?  why not update emails via
    -- SCIM?  how else should they be submitted?  i think this there is
    -- still some confusion here about the distinction between *validated*
    -- emails and *scim-provided* emails, which are two entirely
    -- different things.
    call . post $
        ( spar_
        . paths ["scim", "v2", "Users"]
        . scimAuth auth
        . contentScim
        . body (RequestBodyLBS . Aeson.encode $ user)
        . acceptScim
        )

-- | Create a user.
putUser_
    :: Maybe ScimToken          -- ^ Authentication
    -> Maybe UserId             -- ^ if no Id is provided, this will return 4xx.
    -> SCIM.User.User           -- ^ User data
    -> SparReq                  -- ^ Spar endpoint
    -> TestSpar ResponseLBS
putUser_ auth muid user spar_ = do
    call . put $
        ( spar_
        . paths (["scim", "v2", "Users"] <> maybeToList (toByteString' <$> muid))
        . scimAuth auth
        . contentScim
        . body (RequestBodyLBS . Aeson.encode $ user)
        . acceptScim
        )

-- | List all users.
listUsers_
    :: Maybe ScimToken          -- ^ Authentication
    -> Maybe SCIM.Filter        -- ^ Predicate to filter the results
    -> SparReq                  -- ^ Spar endpoint
    -> TestSpar ResponseLBS
listUsers_ auth mbFilter spar_ = do
    call . get $
        ( spar_
        . paths ["scim", "v2", "Users"]
        . queryItem' "filter" (toByteString' . SCIM.renderFilter <$> mbFilter)
        . scimAuth auth
        . acceptScim
        )

-- | Get one user.
getUser_
    :: Maybe ScimToken          -- ^ Authentication
    -> UserId                   -- ^ User
    -> SparReq                  -- ^ Spar endpoint
    -> TestSpar ResponseLBS
getUser_ auth userid spar_ = do
    call . get $
        ( spar_
        . paths ["scim", "v2", "Users", toByteString' userid]
        . scimAuth auth
        . acceptScim
        )

-- | Create a SCIM token.
createToken_
    :: UserId                   -- ^ User
    -> CreateScimToken
    -> SparReq                  -- ^ Spar endpoint
    -> TestSpar ResponseLBS
createToken_ userid payload spar_ = do
    call . post $
        ( spar_
        . paths ["scim", "auth-tokens"]
        . zUser userid
        . contentJson
        . body (RequestBodyLBS . Aeson.encode $ payload)
        . acceptJson
        )

-- | Delete a SCIM token.
deleteToken_
    :: UserId                   -- ^ User
    -> ScimTokenId              -- ^ Token to delete
    -> SparReq                  -- ^ Spar endpoint
    -> TestSpar ResponseLBS
deleteToken_ userid tokenid spar_ = do
    call . delete $
        ( spar_
        . paths ["scim", "auth-tokens"]
        . queryItem "id" (toByteString' tokenid)
        . zUser userid
        )

-- | List SCIM tokens.
listTokens_
    :: UserId                   -- ^ User
    -> SparReq                  -- ^ Spar endpoint
    -> TestSpar ResponseLBS
listTokens_ userid spar_ = do
    call . get $
        ( spar_
        . paths ["scim", "auth-tokens"]
        . zUser userid
        )

----------------------------------------------------------------------------
-- Utilities

-- | Add SCIM authentication to a request.
scimAuth :: Maybe ScimToken -> Request -> Request
scimAuth Nothing = id
scimAuth (Just auth) = header "Authorization" (toHeader auth)

-- | Signal that the body is an SCIM payload.
contentScim :: Request -> Request
contentScim = content "application/scim+json"

-- | Signal that the response type is expected to be an SCIM payload.
acceptScim :: Request -> Request
acceptScim = accept "application/scim+json"

-- | Get ID of a user returned from SCIM.
scimUserId :: SCIM.StoredUser -> UserId
scimUserId storedUser = either err id (readEither id_)
  where
    id_ = cs (SCIM.id (SCIM.thing storedUser))
    err e = error $ "scimUserId: couldn't parse ID " ++ id_ ++ ": " ++ e

-- | There are a number of user types that all partially map on each other.  This class provides a
-- uniform interface to data stored in those types.
class IsUser u where
  maybeUserId :: u -> Maybe UserId
  maybeHandle :: u -> Maybe (Maybe Handle)
  maybeName :: u -> Maybe (Maybe Name)
  maybeTenant :: u -> Maybe (Maybe SAML.Issuer)
  maybeSubject :: u -> Maybe (Maybe SAML.NameID)

-- | 'ValidSCIMUser' is tested in SCIMSpec.hs exhaustively with literal inputs, so here we assume it
-- is correct and don't aim to verify that name, handle, etc correspond to ones in 'vsuUser'.
instance IsUser ValidSCIMUser where
    maybeUserId = const Nothing
    maybeHandle = Just . Just . view vsuHandle
    maybeName = Just . view vsuName
    maybeTenant = Just . Just . view (vsuSAMLUserRef . SAML.uidTenant)
    maybeSubject = Just . Just . view (vsuSAMLUserRef . SAML.uidSubject)

instance IsUser SCIM.StoredUser where
    maybeUserId = Just . scimUserId
    maybeHandle = maybeHandle . SCIM.value . SCIM.thing
    maybeName = maybeName . SCIM.value . SCIM.thing
    maybeTenant = maybeTenant . SCIM.value . SCIM.thing
    maybeSubject = maybeSubject . SCIM.value . SCIM.thing

instance IsUser SCIM.User.User where
    maybeUserId = const Nothing
    maybeHandle = Just . Just . Handle . SCIM.User.userName
    maybeName = Just . fmap Name . SCIM.User.displayName
    maybeTenant = const Nothing
    maybeSubject = Just . fmap SAML.opaqueNameID . SCIM.User.externalId

instance IsUser User where
    maybeUserId = Just . userId
    maybeHandle = Just . userHandle
    maybeName = Just . Just . userName
    maybeTenant = Just . fmap (view SAML.uidTenant) . urefFromBrig
    maybeSubject = Just . fmap (view SAML.uidSubject) . urefFromBrig

-- | For all properties that are present in both @u1@ and @u2@, check that they match.
userShouldMatch
    :: (HasCallStack, MonadIO m, IsUser u1, IsUser u2)
    => u1 -> u2 -> m ()
userShouldMatch u1 u2 = liftIO $ do
    check "userId" (maybeUserId u1) (maybeUserId u2)
    check "handle" (maybeHandle u1) (maybeHandle u2)
    check "name" (maybeName u1) (maybeName u2)
    check "tenant" (maybeTenant u1) (maybeTenant u2)
    check "subject" (maybeSubject u1) (maybeSubject u2)
  where
    check field (Just a) (Just b) = (field :: String, a) `shouldBe` (field, b)
    check _ _ _ = pure ()

urefFromBrig :: User -> Maybe SAML.UserRef
urefFromBrig brigUser = case userIdentity brigUser of
    Just (SSOIdentity ssoid _ _) -> case Intra.fromUserSSOId ssoid of
        Right uref -> Just uref
        Left e     -> error $
            "urefFromBrig: bad SSO id: " <>
            "UserSSOId = " <> show ssoid <> ", error = " <> e
    _ -> Nothing
