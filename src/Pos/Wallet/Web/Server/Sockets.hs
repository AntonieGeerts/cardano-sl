{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Module for websockets implementation of Daedalus API

module Pos.Wallet.Web.Server.Sockets
       ( WalletWebSockets
       , WebWalletSockets
       , MonadWalletWebSockets (..)
       , ConnectionsVar
       , initWSConnection
       , notify
       , runWalletWS
       ) where

import qualified Network.WebSockets         as WS
import           Pos.Wallet.Web.ClientTypes (NotifyEvent)

import           Control.Lens               (iso)
import           Control.Monad.Trans        (MonadTrans (..))
import           Control.TimeWarp.Rpc       (MonadDialog, MonadTransfer)
import           Control.TimeWarp.Timed     (MonadTimed, ThreadId)
import           Data.Aeson                 (encode)
import           Pos.Aeson.ClientTypes      ()
import           Pos.Context                (WithNodeContext)
import qualified Pos.DB                     as Modern
import           Pos.DHT.Model              (MonadDHT, MonadMessageDHT,
                                             WithDefaultMsgHeader)
import           Pos.Slotting               (MonadSlots)
import           Pos.Txp.Class              (MonadTxpLD)
import           Pos.Wallet.Context         (WithWalletContext)
import           Pos.Wallet.KeyStorage      (MonadKeys)
import           Pos.Wallet.State           (MonadWalletDB)
import           Pos.Wallet.WalletMode      (MonadBalances, MonadTxHistory)
import           Pos.Wallet.Web.State       (MonadWalletWebDB)
import           Serokell.Util.Lens         (WrappedM (..))
import           System.Wlog                (CanLog, HasLoggerName)
import           Universum

-- NODE: for now we are assuming only one client will be used. If there will be need for multiple clients we should extend and hold multiple connections here.
-- We might add multiple clients when we add user profiles but I am not sure if we are planning on supporting more at all.
type ConnectionsVar = MVar WS.Connection

initWSConnection :: IO ConnectionsVar
initWSConnection = newEmptyMVar

-- Sends notification msg to connected client. If there is no connection, notification msg will be ignored.
sendWS :: MonadIO m => ConnectionsVar -> NotifyEvent -> m ()
sendWS connVar msg = liftIO $ maybe mempty (flip WS.sendTextData msg) =<< tryReadMVar connVar

instance WS.WebSocketsData NotifyEvent where
    fromLazyByteString _ = panic "Attempt to deserialize NotifyEvent is illegal"
    toLazyByteString = encode


--------
-- API
--------

-- | Holder for web wallet data
newtype WalletWebSockets m a = WalletWebSockets
    { getWalletWS :: ReaderT ConnectionsVar m a
    } deriving (Functor, Applicative, Monad, MonadTimed, MonadThrow,
                MonadCatch, MonadMask, MonadIO, MonadFail, HasLoggerName,
                MonadWalletDB, WithWalletContext, MonadDialog s p,
                MonadDHT, MonadMessageDHT s, MonadSlots,
                WithDefaultMsgHeader, CanLog, MonadKeys, MonadBalances,
                MonadTxHistory, WithNodeContext ssc,
                Modern.MonadDB ssc, MonadTxpLD ssc, MonadWalletWebDB)

instance Monad m => WrappedM (WalletWebSockets m) where
    type UnwrappedM (WalletWebSockets m) = ReaderT ConnectionsVar m
    _WrappedM = iso getWalletWS WalletWebSockets

instance MonadTrans WalletWebSockets where
    lift = WalletWebSockets . lift

instance MonadTransfer s m => MonadTransfer s (WalletWebSockets m)

type instance ThreadId (WalletWebSockets m) = ThreadId m

-- | MonadWalletWebSockets stands for monad which is able to get web wallet sockets
class Monad m => MonadWalletWebSockets m where
    getWalletWebSockets :: m ConnectionsVar

instance Monad m => MonadWalletWebSockets (WalletWebSockets m) where
    getWalletWebSockets = WalletWebSockets ask

runWalletWS :: ConnectionsVar -> WalletWebSockets m a -> m a
runWalletWS conn = flip runReaderT conn . getWalletWS

type WebWalletSockets m = (MonadWalletWebSockets m, MonadIO m)

notify :: WebWalletSockets m => NotifyEvent -> m ()
notify msg = getWalletWebSockets >>= flip sendWS msg
