{-# LANGUAGE CPP #-}

module Servant.Subscriber (
    notify,
    makeSubscriber,
    serveSubscriber,
    Subscriber,
    Event (..),
    IsElem,
    HasLink,
    IsValidEndpoint,
    IsSubscribable,
    Proxy,
    MkLink,
    URI,
    STM,
) where

import Control.Concurrent.STM
import Control.Monad
import Data.IORef (IORef, newIORef, readIORef)
import qualified Data.Map as Map
import Data.Proxy
import Network.URI (URI (..), pathSegments)
import Network.Wai
import Network.Wai.Handler.WebSockets
import Network.WebSockets.Connection as WS
import Servant.Links (
    HasLink,
    IsElem,
    MkLink,
    safeLink,
 )
import Servant.Server
import Servant.Subscriber.Subscribable

import Servant.Subscriber.Backend.Wai ()
import qualified Servant.Subscriber.Client as Client
import Servant.Subscriber.Types

makeSubscriber :: Path -> LogRunner -> STM (Subscriber api)
makeSubscriber entryPoint' logRunner = do
    state <- newTVar Map.empty
    return $ Subscriber state entryPoint' logRunner

serveSubscriber :: forall api. (HasServer api '[]) => Subscriber api -> Server api -> Application
serveSubscriber subscriber server req sendResponse = do
    let app = serve (Proxy :: Proxy api) server
    (pongHandler, myRef) <- makePongAction
    let opts =
            defaultConnectionOptions
                { connectionOnPong = pongHandler
                }
    let runLog = runLogging subscriber
    let handleWSConnection pending = do
            connection <- acceptRequest pending
#if MIN_VERSION_websockets(0,12,6)
            withPingThread connection 28 (pure ()) $
                runLog . Client.run app <=< atomically . Client.fromWebSocket subscriber myRef $
                    connection
#else
            forkPingThread connection 28
#endif
            runLog . Client.run app <=< atomically . Client.fromWebSocket subscriber myRef $ connection
    if Path (pathInfo req) == entryPoint subscriber
        then websocketsOr opts handleWSConnection app req sendResponse
        else app req sendResponse

makePongAction :: IO (IO (), IORef (IO ()))
makePongAction = do
    myRef <- newIORef $ return ()
    let action = join $ readIORef myRef
    return (action, myRef)
