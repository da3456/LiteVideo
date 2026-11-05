export class SubscriptionUser {
  channelId: string;
  displayName: string;
  avatarUrl: string;
  subscriberText: string;
  videoCountText: string;
  description: string;
  thumbnailColor: string;
  /** 已被服务端确认过（云端名单快照 / 本地订阅写回成功）；核对只删这类条目。 */
  fromCloud: boolean;

  constructor(
    channelId: string,
    displayName: string,
    avatarUrl: string = '',
    subscriberText: string = '',
    videoCountText: string = '',
    description: string = '',
    thumbnailColor: string = '',
    fromCloud: boolean = false
  ) {
    this.channelId = channelId;
    this.displayName = displayName;
    this.avatarUrl = avatarUrl;
    this.subscriberText = subscriberText;
    this.videoCountText = videoCountText;
    this.description = description;
    this.thumbnailColor = thumbnailColor;
    this.fromCloud = fromCloud;
  }
}
