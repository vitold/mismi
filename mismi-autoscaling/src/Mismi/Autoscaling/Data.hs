{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE OverloadedStrings  #-}
module Mismi.Autoscaling.Data (
    toTags
  , fromTags
  , minimumDesiredInstances
  , fromMismiBlockDeviceMapping

  , GroupResultError (..)
  , toGroupResult

  , ConfigurationError (..)
  , toConfiguration

  , InstanceProtectionError (..)
  , parseProtectionError
  ) where

import           Control.Lens ((^.), (.~), view)

import qualified Data.Text as T

import           Mismi.Amazonka (fromText)
import           Mismi.Autoscaling.Core.Data
import qualified Mismi.Autoscaling.Amazonka as A
import           Mismi.EC2.Data (toMismiInstanceType)
import           Mismi.EC2.Core.Data
import           Mismi.IAM.Core.Data (IamRole (..))

import           P

toTags :: GroupName -> [GroupTag] -> [A.Tag]
toTags (GroupName name) =
  fmap (\(GroupTag (EC2Tag k v) p) ->
    A.tag k name "auto-scaling-group" (propagateToBool p) v)

fromTags :: [A.TagDescription] -> [GroupTag]
fromTags =
  fmap (\t ->
    GroupTag (EC2Tag (t ^. A.tdKey) (t ^. A.tdValue)) (propagateFromBool $ t ^. A.tdPropagateAtLaunch))


fromMismiBlockDeviceMapping :: BlockDeviceMapping -> A.BlockDeviceMapping
fromMismiBlockDeviceMapping (BlockDeviceMapping n v) =
  A.blockDeviceMapping n
    & A.bdmVirtualName .~ Just v

minimumDesiredInstances :: DesiredInstances -> DesiredInstances
minimumDesiredInstances (DesiredInstances i) =
  DesiredInstances $ bool i 1 (i > 1)

data GroupResultError =
    LaunchConfigurationMissing GroupName
    deriving (Eq, Show)

toGroupResult :: A.AutoScalingGroup -> Either GroupResultError GroupResult
toGroupResult g = do
  let
    gn = (GroupName $ g ^. A.asgAutoScalingGroupName)
  GroupResult
    <$> pure gn
    <*> maybe (Left $ LaunchConfigurationMissing gn) (Right . ConfigurationName) (g ^. A.asgLaunchConfigurationName)
    <*> pure (Capacity
      (MinInstances $ g ^. A.asgMinSize)
      (DesiredInstances $ g ^. A.asgDesiredCapacity)
      (MaxInstances $ g ^. A.asgMaxSize))
    <*> pure (fmap AvailabilityZone (g ^. A.asgAvailabilityZones))
    <*> pure (LoadBalancer <$> g ^. A.asgLoadBalancerNames)
    <*> pure (with (g ^. A.asgInstances) $ \i ->
      ScalingInstance
        (InstanceId $ view A.iInstanceId i)
        (protectedFromScaleInFromBool $ view A.iProtectedFromScaleIn i)
        (AvailabilityZone $ view A.iAvailabilityZone i))
    <*> pure (g ^. A.asgCreatedTime)
    <*> pure (fromTags (g ^. A.asgTags))

data ConfigurationError =
    UserDataMissing ConfigurationName
  | UserDataDecodeError ConfigurationName Text
  | InvalidInstanceType ConfigurationName Text
  | IamRoleMissing ConfigurationName
    deriving (Eq, Show)

toConfiguration :: A.LaunchConfiguration -> Either ConfigurationError Configuration
toConfiguration a = do
  let
    n = ConfigurationName $ a ^. A.lcLaunchConfigurationName
  Configuration
    <$> pure n
    <*> pure (ImageId $ a ^. A.lcImageId)
    <*> (either (Left . InvalidInstanceType n . T.pack) (pure . toMismiInstanceType) . fromText $ a ^. A.lcInstanceType)
    <*> pure (fmap SecurityGroupName $ a ^. A.lcSecurityGroups)
    <*> (maybe (Left $ IamRoleMissing n) (pure . IamRole) $ a ^. A.lcIAMInstanceProfile)
    <*> (case (a ^. A.lcUserData) of
        Nothing ->
          Left $ UserDataMissing n
        Just v ->
          first (UserDataDecodeError n) $ decodeUserData v)
    <*> pure (case a ^. A.lcSpotPrice of
       Nothing ->
         OnDemand
       Just v ->
         Spot v)

data InstanceProtectionError =
    InstanceProtectionInvalidState
  | InstanceProtectionNotFound
  | InstanceProtectionUnknownError Text
  deriving (Eq, Show)

-- Differentiating between the following:
-- "The instance i-ef2f5d40 is not part of Auto Scaling group stewed.27197.animal."
-- "The instance i-ef2f5d40 is not in InService or EnteringStandby or Standby."
parseProtectionError :: Text -> InstanceProtectionError
parseProtectionError t =
  case T.isInfixOf "is not in InService or EnteringStandby or Standby" t of
    True ->
      InstanceProtectionInvalidState
    False ->
      case T.isInfixOf "is not part of Auto Scaling group" t of
        True ->
          InstanceProtectionNotFound
        False ->
          InstanceProtectionUnknownError t
