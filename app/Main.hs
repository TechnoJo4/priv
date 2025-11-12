module Main where

import Control.Concurrent (forkIO)
import Control.Lens ((^.), preview)
import Control.Monad (forever, void, mzero)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.Trans (lift)
import Control.Monad.IO.Class (liftIO)

import Data.Maybe (fromMaybe)
import Data.List (unsnoc)

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
import Database.SQLite.Simple.QQ (sql)

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

liftH :: App a -> EnvHandler a
liftH a = ask >>= liftIO . runReaderT a

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

-- db queries
getPosts :: Did -> Integer -> Integer -> App [DBPost]
getPosts user cursor limit = do
    conn <- db <$> ask
    liftIO $ SQL.query conn [sql|
        SELECT feed, rt, aturi, ts
        FROM posts
        WHERE feed = ? AND ts < ?
        ORDER BY ts DESC
        LIMIT ?
        |] (encodeDid user, cursor, limit)

ingestRecord :: Integer -> AtUri -> Record -> App ()
ingestRecord _ _ UnknownRecord = return ()

ingestRecord ts aturi@(AtUri rter _ _) (RepostRecord (Ref post)) = do
    conn <- db <$> ask
    liftIO $ SQL.execute conn [sql|
        INSERT OR IGNORE INTO posts(feed, rt, aturi, ts)
        SELECT follower, ?, ?, ?
        FROM follows
        WHERE followee = ? AND reposts = 1
        |] (encodeAtUri aturi, encodeAtUri post, ts, encodeDid rter)

ingestRecord ts aturi@(AtUri poster _ _) (PostRecord Nothing) = do
    conn <- db <$> ask
    liftIO $ SQL.execute conn [sql|
        INSERT OR IGNORE INTO posts(feed, aturi, ts)
        SELECT follower, ?, ?
        FROM follows
        WHERE followee = ? AND posts = 1
        |] (encodeAtUri aturi, ts, encodeDid poster)

ingestRecord ts aturi@(AtUri replier _ _) (PostRecord (Just (ReplyRef parent _))) = do
    conn <- db <$> ask
    let (Ref (AtUri repliee _ _)) = parent

    liftIO $ do
        SQL.execute conn [sql|
            INSERT OR IGNORE INTO posts(feed, aturi, ts)
            SELECT follower, ?, ?
            FROM follows
            WHERE followee = ? AND replies = 1
            |] (encodeAtUri aturi, ts, encodeDid replier)
        SQL.execute conn [sql|
            INSERT OR IGNORE INTO posts(feed, aturi, ts)
            SELECT follower, ?, ?
            FROM follows
            WHERE followee = ? AND replies_to = 1
            |] (encodeAtUri aturi, ts, encodeDid repliee)

getFollowRelation :: Did -> Did -> App DBFollow
getFollowRelation follower followee = do
    conn <- db <$> ask
    rels <- liftIO $ SQL.query conn [sql|
        SELECT follower, followee, posts, replies, replies_to, reposts
        FROM follows
        WHERE follower = ? AND followee = ?
        |] (encodeDid follower, encodeDid followee) :: App [DBFollow]
    return $ case rels of
        (x:_) -> x
        _ -> DBFollow (encodeDid follower) (encodeDid followee) False False False False

setFollowRelation :: DBFollow -> App ()
setFollowRelation rel = do
    conn <- db <$> ask
    liftIO $ SQL.execute conn [sql|
        INSERT OR REPLACE INTO follows
        VALUES (?,?,?,?,?,?)
        |] rel

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
    deriving (Show, Eq)

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
    toJSON (StrongRef aturi cid) = object ["$type" .= ("com.atproto.repo.strongRef" :: Value), "uri" .= aturi, "cid" .= cid]
    toEncoding (StrongRef aturi cid) = pairs ("$type" .= ("com.atproto.repo.strongRef" :: Value) <> "uri" .= aturi <> "cid" .= cid)

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
    , cursor :: Text
    } deriving (Generic, Show)

instance ToJSON FeedReason where
    toJSON = genericToJSON (lexiconOptions "app.bsky.feed.defs#")
    toEncoding = genericToEncoding (lexiconOptions "app.bsky.feed.defs#")

instance ToJSON SkeletonFeedPost where
    toEncoding = genericToEncoding defaultOptions

instance ToJSON FeedSkeleton where
    toEncoding = genericToEncoding defaultOptions

postDBToSkeleton :: DBPost -> SkeletonFeedPost
postDBToSkeleton p = SkeletonFeedPost {
        post = p.aturi,
        reason = SkeletonReasonRepost <$> p.rt
    }

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
    { did :: Did
    , time_us :: Integer
    , commit :: Commit
    } deriving (Generic, Show)

instance FromJSON Commit
instance FromJSON JetstreamMsg

consume :: Connection -> App ()
consume conn = forever $ do
    msg <- liftIO $ receiveData conn
    case (decode msg :: Maybe JetstreamMsg) of
        Nothing -> return ()
        Just j -> case j.commit of
            (Commit "create" coll rkey (Just record)) -> do
                if j.did == DidPlc "nw7wouh4kxrozfmvlzcf36kl" then liftIO $ print j else return ()
                ingestRecord j.time_us (AtUri j.did coll rkey) record
            _ -> return ()


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
        getFeedSkeleton cursor limit = do
            dbPosts <- liftH $ getPosts did (fromMaybe 99999999999999999 cursor) (fromMaybe 50 limit)
            return $ FeedSkeleton {
                feed = postDBToSkeleton <$> dbPosts,
                cursor = case unsnoc dbPosts of
                    Just (_,p) -> pack . show $ p.ts
                    Nothing -> "0"
            }

        createReport :: ReportReq -> EnvHandler ReportRes
        createReport req = do
            let cmds = Data.Text.words (fromMaybe "+ +rt" req.reason)
            liftH $ do
                rel <- getFollowRelation did req.subject.did
                setFollowRelation $ foldl applyCmd rel cmds
            return $ ReportRes {
                reasonType = req.reasonType,
                reason = req.reason,
                subject = req.subject,
                reportedBy = "",
                createdAt = ""
            }

        applyCmd :: DBFollow -> Text -> DBFollow
        applyCmd rel cmd = case cmd of
            "+" -> rel { posts = True }
            "+posts" -> rel { posts = True }
            "+rt" -> rel { reposts = True }
            "+r" -> rel { replies = True }
            "+to" -> rel { replies_to = True }
            "+all" -> rel { posts = True, replies = True, reposts = True }

            "-" -> rel { posts = False, replies = False, replies_to = False, reposts = False }
            "-all" -> rel { posts = False, replies = False, replies_to = False, reposts = False }
            "-posts" -> rel { posts = False }
            "-rt" -> rel { reposts = False }
            "-r" -> rel { replies = False }
            "-to" -> rel { replies_to = False }
            _ -> rel

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
