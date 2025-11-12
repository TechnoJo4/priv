module Main where

import Control.Concurrent (forkIO)
import Control.Lens ((^.), preview)
import Control.Monad (forever, void, mzero)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.Trans (lift)
import Control.Monad.IO.Class (liftIO)

import GHC.Generics (Generic)

import Network.WebSockets (Connection, receiveData)
import qualified Wuss

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Char (toLower)
import Data.Text (Text, stripPrefix, split, words, pack)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL

import qualified Database.SQLite.Simple as SQL
import Database.SQLite.Simple.FromRow
import Database.SQLite.Simple.ToField

import Network.Wai
import Network.Wai.Handler.Warp
import Servant
import Servant.Server.Experimental.Auth

import Crypto.JWT

-- configuration and other persistent values
data Env = Env
    { db :: SQL.Connection
    , plc :: Text
    , mainDid :: Text
    , feedDid :: String
    , svcUrl :: String
    }

type App = ReaderT Env IO

-- database types: see schema.sql
data DBPost = DBPost
    { feed :: Text
    , rt :: Maybe Text
    , aturi :: Text
    , ts :: Integer
    } deriving (Show)

instance FromRow DBPost where
    fromRow = DBPost <$> field <*> field <*> field <*> field

instance SQL.ToRow DBPost where
    toRow DBPost {feed, rt, aturi, ts} = [toField feed, toField aturi, toField rt, toField ts]

data DBFollow = DBFollow
    { follower :: Text
    , followee :: Text
    , posts :: Bool
    , replies :: Bool
    , replies_to :: Bool
    , reposts :: Bool
    }

instance FromRow DBFollow where
    fromRow = DBFollow <$> field <*> field <*> field <*> field <*> field <*> field

instance SQL.ToRow DBFollow where
    toRow follow =
        [ toField $ follower follow
        , toField $ followee follow
        , toField $ posts follow
        , toField $ replies follow
        , toField $ replies_to follow
        , toField $ reposts follow
        ]

-- parsing utils
lowercaseFirst :: String -> String
lowercaseFirst [] = []
lowercaseFirst (c:cs) = toLower c : cs

lexiconOptions :: String -> Options
lexiconOptions prefix = defaultOptions {
        allNullaryToStringTag = False,
        sumEncoding = TaggedObject "$type" "",
        constructorTagModifier = \s -> prefix ++ lowercaseFirst s
    }

maybeToParser :: Maybe a -> Parser a
maybeToParser v = case v of
    Just x -> return $ x
    Nothing -> mzero

-- basic atproto types
data Did = DidPlc Text | DidWeb Text
    deriving (Show)

parseDid :: Text -> Maybe Did
parseDid (stripPrefix "did:plc:" -> Just v) = Just $ DidPlc v
parseDid (stripPrefix "did:web:" -> Just v) = Just $ DidWeb v
parseDid _ = Nothing

encodeDid :: Did -> Text
encodeDid (DidPlc s) = "did:plc:" <> s
encodeDid (DidWeb s) = "did:web:" <> s

instance FromJSON Did where
    parseJSON = withText "Did" (maybeToParser . parseDid)

instance ToJSON Did where
    toJSON = toJSON . encodeDid
    toEncoding = toEncoding . encodeDid

data AtUri = AtUri Did Text Text
    deriving (Show)

parseAtUri :: Text -> Maybe AtUri
parseAtUri (stripPrefix "at://" -> Just v) = case split (=='/') v of
    [partDid, partColl, partRkey] -> parseDid partDid >>= \did -> Just $ AtUri did partColl partRkey
    _ -> Nothing
parseAtUri _ = Nothing

encodeAtUri :: AtUri -> Text
encodeAtUri (AtUri did coll rkey) = "at://" <> (encodeDid did) <> "/" <> coll <> "/" <> rkey

instance FromJSON AtUri where
    parseJSON = withText "AtUri" (maybeToParser . parseAtUri)

instance ToJSON AtUri where
    toJSON = toJSON . encodeAtUri
    toEncoding = toEncoding . encodeAtUri

data RepoRef = RepoRef
    { did :: Did
    } deriving (Generic, Show)

instance FromJSON RepoRef

instance ToJSON RepoRef where
    toEncoding = genericToEncoding defaultOptions

data StrongRef = StrongRef
    { uri :: AtUri
    , cid :: Text
    } deriving (Generic, Show)

data Ref = Ref AtUri
    deriving (Show)

data ReplyRef = ReplyRef { parent :: Ref, root :: Ref }
    deriving (Generic, Show)

data Record = PostRecord (Maybe ReplyRef) | RepostRecord Ref | UnknownRecord
    deriving (Show)

instance FromJSON StrongRef

instance ToJSON StrongRef where
    toJSON (StrongRef uri cid) = object ["$type" .= ("com.atproto.repo.strongRef" :: Value), "uri" .= uri, "cid" .= cid]
    toEncoding (StrongRef uri cid) = pairs ("$type" .= ("com.atproto.repo.strongRef" :: Value) <> "uri" .= uri <> "cid" .= cid)

instance FromJSON Ref where
    parseJSON = withObject "Ref" $ \v -> Ref <$> v .: "uri"

instance FromJSON ReplyRef

instance FromJSON Record where
    parseJSON = withObject "Record" $ \v -> do
        t <- v .: "$type"
        case (t :: Text) of
            "app.bsky.feed.post" -> PostRecord <$> v .:? "reply"
            "app.bsky.feed.repost" -> RepostRecord <$> v .: "subject"
            _ -> return UnknownRecord

-- lexicon types: feed skeleton
data FeedReason = SkeletonReasonRepost { repost :: Text } | SkeletonReasonPin
    deriving (Generic, Show)

data SkeletonFeedPost = SkeletonFeedPost
    { post :: Text
    , reason :: Maybe FeedReason
    } deriving (Generic, Show)

data FeedSkeleton = FeedSkeleton
    { feed :: [SkeletonFeedPost]
    , cursor :: Integer
    } deriving (Generic, Show)

instance ToJSON FeedReason where
    toJSON = genericToJSON (lexiconOptions "app.bsky.feed.defs#")
    toEncoding = genericToEncoding (lexiconOptions "app.bsky.feed.defs#")

instance ToJSON SkeletonFeedPost where
    toEncoding = genericToEncoding defaultOptions

instance ToJSON FeedSkeleton where
    toEncoding = genericToEncoding defaultOptions

-- lexicon types: reporting
data ReportReq = ReportReq
    { reasonType :: Text
    , reason :: Maybe Text
    , subject :: RepoRef
    } deriving (Generic, Show)

data ReportRes = ReportRes
    { reasonType :: Text
    , reason :: Maybe Text
    , subject :: RepoRef
    , reportedBy :: Text
    , createdAt :: Text
    } deriving (Generic, Show)

instance FromJSON ReportReq

instance ToJSON ReportRes where
    toEncoding = genericToEncoding defaultOptions


-- jetstream consumer
data Commit = Commit
    { operation :: Text
    , collection :: Text
    , rkey :: Text
    , record :: Maybe Record
    } deriving (Generic, Show)

data JetstreamMsg = JetstreamMsg
    { did :: Text
    , time_us :: Integer
    , commit :: Commit
    } deriving (Generic, Show)

instance FromJSON Commit
instance FromJSON JetstreamMsg

consume :: Connection -> ReaderT Env IO ()
consume conn = return () --forever $ do
    --lift $ do
    --    msg <- receiveData conn
    --    print $ (decode msg :: Maybe JetstreamMsg)

-- atproto service auth
authHandler :: AuthHandler Request Did
authHandler = mkAuthHandler handler
    where
        throw401 msg = throwError $ err401 { errBody = msg }
        or401 :: BSL.ByteString -> Maybe a -> Handler a
        or401 msg = maybe (throw401 msg) pure
        left401 :: BSL.ByteString -> Either a b -> Handler b
        left401 msg = either (const $ throw401 msg) pure
        handler :: Request -> Handler Did
        handler req = do
            authHdr <- or401 "no auth header" $ lookup "Authorization" $ requestHeaders req
            let bearer = "Bearer "
                (_, token) = BS.splitAt (BS.length bearer) authHdr

            claims <- liftIO . runJOSE $ do
                jwt <- decodeCompact (BSL.fromStrict token)
                unsafeGetJWTClaimsSet jwt
            claims' <- left401 "bad jwt" (claims :: Either JWTError ClaimsSet)

            issClaim <- or401 "no iss claim" $ claims' ^. claimIss
            iss <- or401 "no iss" $ preview Crypto.JWT.uri issClaim
            or401 "bad iss" $ parseDid . pack . show $ iss

authServerContext :: Servant.Context (AuthHandler Request Did ': '[])
authServerContext = authHandler :. EmptyContext

type instance AuthServerData (AuthProtect "service-jwt") = Did

-- api definition
type API = Get '[PlainText] Text
        :<|> "xrpc" :> AuthProtect "service-jwt" :> XRPC
        :<|> ".well-known" :> WellKnown

type XRPC = "app.bsky.feed.getFeedSkeleton"
                -- :> QueryParam "feed" Text
                :> QueryParam "cursor" Integer
                :> QueryParam "limit" Integer
                :> Get '[JSON] FeedSkeleton
        :<|> "com.atproto.moderation.createReport"
                :> ReqBody '[JSON] ReportReq
                :> Post '[JSON] ReportRes

type WellKnown = "atproto-did" :> Get '[PlainText] Text
        :<|> "did.json" :> Get '[JSON] Value

-- server
type EnvHandler = ReaderT Env Handler

xrpc :: Did -> ServerT XRPC EnvHandler
xrpc did = getFeedSkeleton :<|> createReport
    where
        getFeedSkeleton :: Maybe Integer -> Maybe Integer -> EnvHandler FeedSkeleton
        getFeedSkeleton cursor limit = return
            FeedSkeleton {
                feed = [
                    SkeletonFeedPost {post="at://did:plc:5kr7qxme46hlriffmq3k74rj/app.bsky.feed.post/3m4nuy5vdgdl2", reason=Nothing}
                ],
                cursor = 0
            }

        createReport :: ReportReq -> EnvHandler ReportRes
        createReport req = return
            ReportRes {
                reasonType = req.reasonType,
                reason = req.reason,
                subject = req.subject,
                reportedBy = "",
                createdAt = ""
            }

server :: ServerT API EnvHandler
server = hello :<|> xrpc :<|> wellKnown
    where
        hello = return "# This is https://github.com/TechnoJo4/priv"
        wellKnown = atprotoDid :<|> didJson

        atprotoDid :: EnvHandler Text
        atprotoDid = mainDid <$> ask

        -- did for the feed generator: the labeler is the main DID
        -- the labeler account should have an #atproto_labeler (AtprotoLabeler) service with the same endpoint
        didJson :: EnvHandler Value
        didJson = ask >>= \env -> return $ object [
                "@context" .= toJSON ["https://www.w3.org/ns/did/v1" :: Text],
                "id" .= feedDid env,
                "service" .= (toJSON [
                    object [
                        "id" .= ("#bsky_fg" :: Text),
                        "type" .= ("BskyFeedGenerator" :: Text),
                        "serviceEndpoint" .= (svcUrl env)
                    ]
                ])
            ]

api :: Proxy API
api = Proxy

app :: Env -> Application
app env =
    serveWithContext api authServerContext $
        hoistServerWithContext api (Proxy :: Proxy '[AuthHandler Request Did]) (flip runReaderT env) server

-- main
main :: IO ()
main = do
    db <- SQL.open "priv.db"
    let env = Env {
            db = db,
            plc = "https://plc.directory/",
            mainDid = "did:plc:hrxxvz6q4u67z4puuyek4qpt",
            feedDid = "did:web:priv.merkletr.ee",
            svcUrl = "https://priv.merkletr.ee"
        }

    -- consume new posts
    void . forkIO $ Wuss.runSecureClient "jetstream2.us-east.bsky.network" 443 "/subscribe" ((flip runReaderT) env . consume)

    -- run the server
    run 8080 (app env)
